"""Electricity cost estimate (feature `energy`): price per kWh, a daily energy ledger, session cost.

Price per kWh, in this order:
1. The user's own price, set from the phone (`PUT /api/energy/price`), saved in settings
   `energy.override`.
2. Eurostat's household price for the PC's country (`nrg_pc_204`, all taxes included, the
   all-bands average `TOT_KWH`, else the 2,500-4,999 kWh band, in the national currency). The
   agent downloads the whole public table, at most every 30 days, with a verified TLS connection
   and keeps it in `%LOCALAPPDATA%\\Orbit\\energy-prices.json`. The request carries nothing about
   the user: every country comes back, and a failure is silent.
3. The table built into this file (`BUILTIN_PRICES`): Eurostat 2026-S1 for the EU, EEA and
   candidate countries, plus the US (EIA), Great Britain (Ofgem cap) and Switzerland (ElCom).
   When a downloaded row and a built-in row exist, the newer period wins.
4. Nothing: the phone asks the user for a price.

The country comes from Windows' "Country or region" setting (no location permission):
`GetUserDefaultGeoName`, else `GetUserGeoID(GEOCLASS_NATION)` + `GetGeoInfoW(GEO_ISO2)`. The last
good answer is saved in settings `energy.detectedCountry` for the boot-time instance, which runs
before anyone signs in and may not see the user's region.

Energy ledger (`%LOCALAPPDATA%\\Orbit\\ledger.sqlite3`, WAL, 400 days): every telemetry tick
adds `dt` seconds (from `time.monotonic`, at most 5 s per tick, so sleep and stalls are not
counted) to today's row for the running game ('' outside games):
    wall W = (CPU W + GPU W + baseWatts) / psuEfficiency
CPU and GPU watts count only while the agent's own freshness rules report them; missing readings
count as 0 W and the time is left out of `measured_seconds`. The cost of each tick uses the
price in force at that moment. Totals stay in memory and are written every 60 s and at shutdown.
A day/game row holds one currency: when the currency changes, that row's cost is restated in the
new currency at the new price (nothing is ever summed across currencies).

Routes (main token, HTTPS only):
- `GET /api/energy/price` → `{"country": "RO", "pricePerKWh": 1.4573, "currency": "RON",
  "source": "Eurostat nrg_pc_204 (2026-S1)", "period": "2026-S1", "isOverride": false,
  "defaultPrice": {...} | null}`
- `PUT /api/energy/price` `{"pricePerKWh": 1.07, "currency": "RON"}` or `{"reset": true}`
- `GET/PUT /api/energy/settings` `{"baseWatts": 60, "psuEfficiency": 0.88}`
- `GET /api/energy/summary?month=YYYY-MM`
"""
import calendar
import contextlib
import ctypes
from datetime import datetime, timezone
import json
import logging
import math
import os
from pathlib import Path
import re
import sqlite3
import ssl
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from fastapi import APIRouter, Body, Depends, HTTPException, Query

import orbit_settings

LOGGER = logging.getLogger("orbit.energy")

SETTINGS_SECTION = "energy"
DEFAULT_BASE_WATTS = 60.0
DEFAULT_PSU_EFFICIENCY = 0.88
BASE_WATTS_RANGE = (0.0, 500.0)
PSU_EFFICIENCY_RANGE = (0.5, 1.0)
MAX_PRICE_PER_KWH = 100000.0  # Covers currencies such as IDR or VND; the floor is 0 (free power).
MAX_TICK_SECONDS = 5.0
FLUSH_SECONDS = 60.0
LEDGER_RETRY_SECONDS = 60.0
RETENTION_DAYS = 400
MAX_COMPONENT_WATTS = 3000.0
SESSION_GAP_SECONDS = 15.0  # orbit_history.GAP_SECONDS: longer pauses start a new segment.
PRICE_CACHE_SECONDS = 30.0
COUNTRY_RECHECK_SECONDS = 600.0

LEDGER_FILE_NAME = "ledger.sqlite3"
PRICE_TABLE_FILE_NAME = "energy-prices.json"
PRICE_TABLE_MAX_AGE_SECONDS = 30 * 24 * 60 * 60
PRICE_TABLE_RETRY_SECONDS = 24 * 60 * 60
PRICE_TABLE_FIRST_CHECK_SECONDS = 60.0
PRICE_TABLE_MAX_BYTES = 2 * 1024 * 1024
PRICE_TABLE_MIN_ROWS = 10
EUROSTAT_HOST = "ec.europa.eu"
EUROSTAT_DATASET_URL = "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data/nrg_pc_204"

# Windows (winnls.h): GEOCLASS_NATION, GEOID_NOT_AVAILABLE, SYSGEOTYPE values.
GEOCLASS_NATION = 16
GEOID_NOT_AVAILABLE = -1
GEO_ISO2 = 0x4
GEO_CURRENCYCODE = 0xF
GEO_BUFFER_CHARS = 16

# Eurostat geo codes that differ from ISO 3166-1 alpha-2.
ISO_TO_EUROSTAT = {"GR": "EL", "GB": "UK"}
EUROSTAT_TO_ISO = {code: iso for iso, code in ISO_TO_EUROSTAT.items()}
# The currency Eurostat calls "NAC" (national currency) for each geo. A country that adopted the
# euro used its old currency before `EURO_SINCE`; Eurostat reports NAC in the currency of the period.
EUROSTAT_NATIONAL_CURRENCIES = {
    "AT": "EUR", "BE": "EUR", "BG": "EUR", "CY": "EUR", "DE": "EUR", "EE": "EUR", "EL": "EUR", "ES": "EUR",
    "FI": "EUR", "FR": "EUR", "HR": "EUR", "IE": "EUR", "IT": "EUR", "LT": "EUR", "LU": "EUR", "LV": "EUR",
    "ME": "EUR", "MT": "EUR", "NL": "EUR", "PT": "EUR", "SI": "EUR", "SK": "EUR", "XK": "EUR",
    "AL": "ALL", "BA": "BAM", "CZ": "CZK", "DK": "DKK", "GE": "GEL", "HU": "HUF", "IS": "ISK", "LI": "CHF",
    "MD": "MDL", "MK": "MKD", "NO": "NOK", "PL": "PLN", "RO": "RON", "RS": "RSD", "SE": "SEK", "TR": "TRY",
    "UA": "UAH", "UK": "GBP",
}
EURO_SINCE = {"BG": ("2026-S1", "BGN"), "HR": ("2023-S1", "HRK")}

BUILTIN_RETRIEVED = "2026-10-24"


def _eurostat(price, currency, period, name, band="TOT_KWH"):
    label = f"Eurostat nrg_pc_204 ({period})" if band == "TOT_KWH" else f"Eurostat nrg_pc_204 ({period}, 2,500-4,999 kWh band)"
    return {"price": price, "currency": currency, "period": period, "name": name, "band": band, "source": label,
            "retrieved": BUILTIN_RETRIEVED}


# Household electricity price per kWh, all taxes and levies included. Eurostat rows come from the
# live API (dataset updated 2026-10-19; I_TAX, TOT_KWH, national currency, 2026-S1), retrieved
# 2026-10-24. Source: Eurostat (CC BY 4.0). Kept as Python so the self-updater ships it.
BUILTIN_PRICES = {
    "AL": _eurostat(11.4, "ALL", "2026-S1", "Albania"),
    "AT": _eurostat(0.3255, "EUR", "2026-S1", "Austria"),
    "BA": _eurostat(0.202, "BAM", "2026-S1", "Bosnia and Herzegovina"),
    "BE": _eurostat(0.3602, "EUR", "2026-S1", "Belgium"),
    "BG": _eurostat(0.1338, "EUR", "2026-S1", "Bulgaria"),
    "CY": _eurostat(0.2782, "EUR", "2026-S1", "Cyprus"),
    "CZ": _eurostat(6.7234, "CZK", "2026-S1", "Czechia"),
    "DE": _eurostat(0.3807, "EUR", "2026-S1", "Germany"),
    "DK": _eurostat(1.749, "DKK", "2026-S1", "Denmark"),
    "EE": _eurostat(0.2067, "EUR", "2026-S1", "Estonia"),
    "ES": _eurostat(0.2739, "EUR", "2026-S1", "Spain"),
    "FI": _eurostat(0.2274, "EUR", "2026-S1", "Finland"),
    "FR": _eurostat(0.2391, "EUR", "2026-S1", "France"),
    "GE": _eurostat(0.2206, "GEL", "2026-S1", "Georgia"),
    "GR": _eurostat(0.2584, "EUR", "2026-S1", "Greece"),
    "HR": _eurostat(0.1877, "EUR", "2026-S1", "Croatia"),
    "HU": _eurostat(44.3379, "HUF", "2026-S1", "Hungary"),
    "IE": _eurostat(0.3921, "EUR", "2026-S1", "Ireland"),
    "IS": _eurostat(27.0288, "ISK", "2026-S1", "Iceland"),
    "IT": _eurostat(0.3579, "EUR", "2026-S1", "Italy"),
    "LI": _eurostat(0.2715, "CHF", "2026-S1", "Liechtenstein"),
    "LT": _eurostat(0.2233, "EUR", "2026-S1", "Lithuania"),
    "LU": _eurostat(0.1996, "EUR", "2026-S1", "Luxembourg"),
    "LV": _eurostat(0.2625, "EUR", "2026-S1", "Latvia"),
    "MD": _eurostat(3.6826, "MDL", "2026-S1", "Moldova"),
    "ME": _eurostat(0.1105, "EUR", "2026-S1", "Montenegro"),
    "MK": _eurostat(7.4792, "MKD", "2026-S1", "North Macedonia"),
    "MT": _eurostat(0.1471, "EUR", "2026-S1", "Malta"),
    "NL": _eurostat(0.237, "EUR", "2026-S1", "Netherlands"),
    "NO": _eurostat(1.3582, "NOK", "2026-S1", "Norway"),
    "PL": _eurostat(1.3281, "PLN", "2026-S1", "Poland"),
    "PT": _eurostat(0.2541, "EUR", "2026-S1", "Portugal"),
    "RO": _eurostat(1.4573, "RON", "2026-S1", "Romania"),
    "RS": _eurostat(15.6195, "RSD", "2026-S1", "Serbia"),
    "SE": _eurostat(2.6849, "SEK", "2026-S1", "Sweden"),
    "SI": _eurostat(0.2111, "EUR", "2026-S1", "Slovenia"),
    "SK": _eurostat(0.2021, "EUR", "2026-S1", "Slovakia"),
    "TR": _eurostat(3.5289, "TRY", "2026-S1", "Türkiye"),
    "XK": _eurostat(0.0943, "EUR", "2026-S1", "Kosovo"),
    # U.S. Energy Information Administration, Electric Power Monthly: 2025 annual residential
    # average, 17.23 cents/kWh (public domain).
    "US": {"price": 0.1723, "currency": "USD", "period": "2025", "name": "United States",
           "source": "U.S. EIA residential average (2025)", "retrieved": "2026-10-23"},
    # Ofgem price cap, Great Britain average unit rate for Direct Debit, 1 Oct - 31 Dec 2026,
    # 26.32 p/kWh with no VAT (Open Government Licence). Northern Ireland is not covered by the cap.
    "GB": {"price": 0.2632, "currency": "GBP", "period": "2026-Q4", "name": "United Kingdom",
           "source": "Ofgem price cap, Great Britain average (Oct-Dec 2026)", "retrieved": "2026-10-23"},
    # ElCom: 2026 median household tariff (profile H4), 27.7 Rp/kWh.
    "CH": {"price": 0.277, "currency": "CHF", "period": "2026", "name": "Switzerland",
           "source": "ElCom median household tariff (2026)", "retrieved": "2026-10-23"},
}

_ISO2 = re.compile(r"^[A-Za-z]{2}$")
_CURRENCY = re.compile(r"^[A-Za-z]{3}$")
# Active ISO 4217 currency codes (2026), so a typo such as "LEI" is refused instead of saved.
ISO_4217 = frozenset("""
AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BOV BRL BSD BTN BWP BYN BZD
CAD CDF CHE CHF CHW CLF CLP CNY COP COU CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL
GHS GIP GMD GNF GTQ GYD HKD HNL HRK HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW
KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD NGN
NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL
SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD USN UYI UYU UYW UZS VED VES
VND VUV WST XAF XCD XCG XOF XPF YER ZAR ZMW ZWG ZWL
""".split())
_MONTH = re.compile(r"^(\d{4})-(\d{2})$")
_PERIOD = re.compile(r"^(\d{4})(?:-([SQ])(\d))?$")


# Small helpers shared with orbit_summary --------------------------------------------------------

def default_ledger_path():
    from orbit_tls import data_directory
    return data_directory() / LEDGER_FILE_NAME


def default_price_table_path():
    from orbit_tls import data_directory
    return data_directory() / PRICE_TABLE_FILE_NAME


def local_day(timestamp):
    """The PC's local calendar date (`YYYY-MM-DD`) for a Unix time; follows DST like the clock."""
    return time.strftime("%Y-%m-%d", time.localtime(timestamp))


def game_key(process):
    """`eldenring` for `eldenring.exe` or `C:\\...\\eldenring.exe`; '' when no game runs."""
    if not isinstance(process, str):
        return ""
    name = process.replace("\\", "/").rsplit("/", 1)[-1].strip().lower()
    if name.endswith(".exe"):
        name = name[:-4]
    return " ".join(name.split())[:120]


def _number(value, low, high):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    if not math.isfinite(value) or value < low or value > high:
        return None
    return value


def _watts(value):
    return _number(value, 0.0, MAX_COMPONENT_WATTS)


def parse_month(value):
    """`(2026, 10)` for "2026-10"; ValueError with a plain sentence otherwise."""
    match = _MONTH.match(value or "") if isinstance(value, str) else None
    if not match or not 1 <= int(match.group(2)) <= 12 or not 2000 <= int(match.group(1)) <= 2100:
        raise ValueError("Ask for a month as YYYY-MM, for example 2026-10.")
    return int(match.group(1)), int(match.group(2))


def month_text(year, month):
    return f"{year:04d}-{month:02d}"


def shift_month(year, month, delta):
    index = year * 12 + (month - 1) + delta
    return index // 12, index % 12 + 1


def month_day_range(year, month):
    """First day of the month and first day of the next month, as `YYYY-MM-DD` text."""
    next_year, next_month = shift_month(year, month, 1)
    return f"{year:04d}-{month:02d}-01", f"{next_year:04d}-{next_month:02d}-01"


def iso_utc(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _period_key(period):
    match = _PERIOD.match(period or "") if isinstance(period, str) else None
    if not match:
        return (0, 0)
    year = int(match.group(1))
    if match.group(2) == "S":
        return (year, int(match.group(3)) * 6)
    if match.group(2) == "Q":
        return (year, int(match.group(3)) * 3)
    return (year, 0)


def _atomic_write_bytes(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            with contextlib.suppress(OSError):
                os.unlink(temporary)


# Country from Windows ---------------------------------------------------------------------------

_KERNEL32 = []


def _kernel32():
    """kernel32 as a private WinDLL (argtypes set here never leak into ctypes.windll); None off Windows."""
    if not _KERNEL32:
        try:
            _KERNEL32.append(ctypes.WinDLL("kernel32", use_last_error=True))
        except (AttributeError, OSError):
            return None
    return _KERNEL32[0]


def _function(library, name, argtypes, restype):
    try:
        function = getattr(library, name)
    except AttributeError:
        return None  # Older Windows without this export.
    function.argtypes = argtypes
    function.restype = restype
    return function


def _iso2(text):
    text = (text or "").strip()
    return text.upper() if _ISO2.match(text) else None


def detect_country(kernel32=None):
    """ISO 3166-1 alpha-2 code of Windows' home location ("RO"), or None. Never raises.

    `GetUserDefaultGeoName` (Windows 10 1709+) may answer a UN M.49 number such as "419" when the
    region has no ISO code; then the older GeoID pair is asked instead.
    """
    library = kernel32 if kernel32 is not None else _kernel32()
    if library is None:
        return None
    buffer = ctypes.create_unicode_buffer(GEO_BUFFER_CHARS)
    try:
        get_name = _function(library, "GetUserDefaultGeoName", [ctypes.c_wchar_p, ctypes.c_int], ctypes.c_int)
        if get_name is not None and get_name(buffer, GEO_BUFFER_CHARS) > 0:
            code = _iso2(buffer.value)
            if code:
                return code
    except (OSError, ValueError, TypeError, ctypes.ArgumentError):
        LOGGER.debug("GetUserDefaultGeoName failed", exc_info=True)
    try:
        get_geo_id = _function(library, "GetUserGeoID", [ctypes.c_uint32], ctypes.c_long)
        get_info = _function(library, "GetGeoInfoW",
                             [ctypes.c_long, ctypes.c_uint32, ctypes.c_wchar_p, ctypes.c_int, ctypes.c_ushort],
                             ctypes.c_int)
        if get_geo_id is None or get_info is None:
            return None
        geo_id = get_geo_id(GEOCLASS_NATION)
        if geo_id == GEOID_NOT_AVAILABLE:
            return None
        buffer = ctypes.create_unicode_buffer(GEO_BUFFER_CHARS)
        if get_info(geo_id, GEO_ISO2, buffer, GEO_BUFFER_CHARS, 0) <= 0:
            return None
        return _iso2(buffer.value)
    except (OSError, ValueError, TypeError, ctypes.ArgumentError):
        LOGGER.debug("GetUserGeoID/GetGeoInfoW failed", exc_info=True)
        return None


def windows_currency(country, kernel32=None):
    """Windows' ISO 4217 code for a country ("RON"), only shown when Orbit has no price row."""
    if not _iso2(country):
        return None
    library = kernel32 if kernel32 is not None else _kernel32()
    if library is None:
        return None
    try:
        get_info = _function(library, "GetGeoInfoEx", [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_wchar_p, ctypes.c_int],
                             ctypes.c_int)
        if get_info is None:
            return None
        buffer = ctypes.create_unicode_buffer(GEO_BUFFER_CHARS)
        if get_info(country.upper(), GEO_CURRENCYCODE, buffer, GEO_BUFFER_CHARS) <= 0:
            return None
        text = (buffer.value or "").strip()
        return text.upper() if is_currency_code(text) else None
    except (OSError, ValueError, TypeError, ctypes.ArgumentError):
        return None


class CountryResolver:
    """Detects the country at most every 10 minutes and remembers the last good answer.

    In boot mode (before sign-in) Windows may answer with the default profile's region, so a
    saved answer wins there and nothing is saved.
    """

    def __init__(self, detector=detect_country, currency_detector=windows_currency, clock=time.monotonic):
        self._detector = detector
        self._currency_detector = currency_detector
        self._clock = clock
        self._lock = threading.Lock()
        self._checked = None
        self._value = None
        self._currencies = {}
        self.boot_mode = False

    def reset(self):
        with self._lock:
            self._checked = None
            self._currencies.clear()

    def country(self, store):
        with self._lock:
            now = self._clock()
            if self._checked is not None and now - self._checked < COUNTRY_RECHECK_SECONDS:
                return self._value
            self._checked = now
            section = store.get(SETTINGS_SECTION, {})
            saved = _iso2(section.get("detectedCountry")) if isinstance(section, dict) else None
            detected = None if (self.boot_mode and saved) else _iso2(self._detector())
            if detected and detected != saved and not self.boot_mode:
                try:
                    store.update(SETTINGS_SECTION, {"detectedCountry": detected})
                except (OSError, ValueError):
                    LOGGER.warning("Could not save the detected country", exc_info=True)
            self._value = detected or saved
            return self._value

    def currency(self, country):
        with self._lock:
            if country not in self._currencies:
                try:
                    self._currencies[country] = self._currency_detector(country)
                except Exception:
                    self._currencies[country] = None
            return self._currencies[country]


# Eurostat JSON-stat -----------------------------------------------------------------------------

def eurostat_url(now=None):
    """The unfiltered nrg_pc_204 query (every country, so the request reveals nothing)."""
    year = time.gmtime(now if now is not None else time.time()).tm_year
    return (f"{EUROSTAT_DATASET_URL}?format=JSON&lang=EN&unit=KWH&tax=I_TAX&currency=NAC&currency=EUR"
            f"&nrg_cons=TOT_KWH&nrg_cons=KWH2500-4999&sinceTimePeriod={year - 1}-S1")


def national_currency(geo, period):
    currency = EUROSTAT_NATIONAL_CURRENCIES.get(geo)
    change = EURO_SINCE.get(geo)
    if change and _period_key(period) < _period_key(change[0]):
        return change[1]
    return currency


def _category_index(dimension):
    index = dimension["category"]["index"]
    if isinstance(index, list):
        return {code: position for position, code in enumerate(index)}
    if isinstance(index, dict):
        return {str(code): int(position) for code, position in index.items()}
    raise ValueError("Unexpected JSON-stat category index")


def parse_eurostat_prices(payload):
    """Rows keyed by ISO country code from an nrg_pc_204 JSON-stat 2.0 response.

    Per country: the newest period with an all-taxes price in national currency, the all-bands
    average first, else the 2,500-4,999 kWh band. Aggregates (EU27_2020, EA) and geos whose
    national currency Orbit does not know are skipped, and so is a row whose national-currency
    value contradicts its euro value (a currency change Orbit does not know about yet).
    """
    if not isinstance(payload, dict):
        raise ValueError("Not a JSON-stat dataset")
    ids, sizes, dimensions = payload.get("id"), payload.get("size"), payload.get("dimension")
    if not isinstance(ids, list) or not isinstance(sizes, list) or len(ids) != len(sizes) or not isinstance(dimensions, dict):
        raise ValueError("Not a JSON-stat dataset")
    indexes = {name: _category_index(dimensions[name]) for name in ids}
    for required in ("nrg_cons", "tax", "currency", "geo", "time"):
        if required not in indexes:
            raise ValueError(f"The dataset has no {required} dimension")
    fixed = {"freq": "S", "siec": "E7000", "unit": "KWH", "tax": "I_TAX"}
    values = payload.get("value")
    statuses = payload.get("status") or {}

    def lookup(container, flat):
        if isinstance(container, dict):
            return container.get(str(flat))
        if isinstance(container, list) and 0 <= flat < len(container):
            return container[flat]
        return None

    def cell(**coordinate):
        flat = 0
        for name, size in zip(ids, sizes):
            code = coordinate.get(name, fixed.get(name))
            if code is None:
                if size != 1:
                    raise ValueError(f"Unexpected dimension {name}")
                position = 0
            else:
                position = indexes[name].get(code)
                if position is None:
                    return None, None
            flat = flat * size + position
        value = lookup(values, flat)
        number = _number(value, 0.0, MAX_PRICE_PER_KWH)
        return (number if number and number > 0 else None), lookup(statuses, flat)

    labels = dimensions["geo"]["category"].get("label") or {}
    periods = sorted(indexes["time"], key=_period_key, reverse=True)
    rows = {}
    for geo in indexes["geo"]:
        if geo not in EUROSTAT_NATIONAL_CURRENCIES:
            continue
        for period in periods:
            found = None
            for band, short in (("TOT_KWH", "TOT_KWH"), ("KWH2500-4999", "DC")):
                value, status = cell(nrg_cons=band, currency="NAC", geo=geo, time=period)
                if value is not None:
                    found = (band, short, value, status)
                    break
            if found is None:
                continue
            band, short, value, status = found
            currency = national_currency(geo, period)
            euro, _ = cell(nrg_cons=band, currency="EUR", geo=geo, time=period)
            if euro is not None:
                same = abs(euro - value) < 1e-9
                if (currency == "EUR") != same and not (currency == "CHF" and same):
                    LOGGER.info("Eurostat %s %s: national currency does not match %s; skipped", geo, period, currency)
                    break
            row = _eurostat(round(value, 6), currency, period, str(labels.get(geo) or geo).rstrip("*").strip(), band=short)
            row["retrieved"] = time.strftime("%Y-%m-%d", time.gmtime())
            if isinstance(status, str) and status:
                row["status"] = status
            rows[EUROSTAT_TO_ISO.get(geo, geo)] = row
            break
    return rows


def _is_eurostat_url(url):
    if not isinstance(url, str):
        return False
    try:
        parts = urllib.parse.urlsplit(url)
        return parts.scheme == "https" and (parts.hostname or "").lower() == EUROSTAT_HOST
    except ValueError:
        return False


class _EurostatRedirects(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only to another HTTPS address on ec.europa.eu (urllib's own handler
    would follow one to any host, and to plain HTTP)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not _is_eurostat_url(newurl):
            raise urllib.error.HTTPError(req.full_url, code, "Eurostat redirected outside https://ec.europa.eu",
                                         headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _eurostat_opener(context):
    """An opener that verifies TLS with `context` and refuses redirects away from Eurostat."""
    return urllib.request.build_opener(urllib.request.HTTPSHandler(context=context), _EurostatRedirects())


def fetch_eurostat_table(url=None, *, opener=None, timeout=20.0, now=None):
    """Downloads and parses the public table; raises on any problem (the caller stays silent).

    `opener(request, timeout=, context=)` replaces the network in tests."""
    url = url or eurostat_url(now)
    if not url.startswith(f"https://{EUROSTAT_HOST}/") or not _is_eurostat_url(url):
        raise ValueError("Electricity prices are only downloaded from Eurostat over HTTPS")
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "OrbitPCCompanion"})
    context = ssl.create_default_context()  # Verified certificates and host name.
    if opener is None:
        def open_url(request, timeout, context):
            return _eurostat_opener(context).open(request, timeout=timeout)
    else:
        open_url = opener
    with open_url(request, timeout=timeout, context=context) as response:
        if not _is_eurostat_url(getattr(response, "url", None) or url):
            raise ValueError("The Eurostat answer came from another address")
        status = getattr(response, "status", 200)
        if status != 200:
            raise ValueError(f"Eurostat answered HTTP {status}")
        raw = response.read(PRICE_TABLE_MAX_BYTES + 1)
    if len(raw) > PRICE_TABLE_MAX_BYTES:
        raise ValueError("The Eurostat answer is unexpectedly large")
    payload = json.loads(raw.decode("utf-8"))
    rows = parse_eurostat_prices(payload)
    if len(rows) < PRICE_TABLE_MIN_ROWS:
        raise ValueError("The Eurostat answer has too few countries")
    return {"version": 1, "fetchedAt": now if now is not None else time.time(),
            "datasetUpdated": payload.get("updated") if isinstance(payload.get("updated"), str) else None,
            "rows": rows}


def _valid_row(row):
    return (isinstance(row, dict) and _number(row.get("price"), 0.0, MAX_PRICE_PER_KWH) is not None
            and is_currency_code(row.get("currency"))
            and isinstance(row.get("period"), str) and isinstance(row.get("source"), str))


class PriceTable:
    """The downloaded Eurostat table: loaded lazily from disk, replaced atomically on refresh."""

    def __init__(self, path=None, clock=time.time):
        self._path = Path(path) if path is not None else None
        self._clock = clock
        self._lock = threading.Lock()
        self._loaded = False
        self._rows = {}
        self._fetched_at = None

    @property
    def path(self):
        return self._path if self._path is not None else default_price_table_path()

    def _load_locked(self):
        if self._loaded:
            return
        self._loaded = True
        try:
            if self.path.stat().st_size > PRICE_TABLE_MAX_BYTES:
                return
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        except (OSError, ValueError):
            LOGGER.info("The saved electricity price table is unreadable; using the built-in prices")
            return
        rows = data.get("rows") if isinstance(data, dict) else None
        if isinstance(rows, dict):
            self._rows = {code.upper(): row for code, row in rows.items() if _iso2(code) and _valid_row(row)}
            fetched = _number(data.get("fetchedAt"), 0.0, 1e11)
            self._fetched_at = fetched

    def rows(self):
        with self._lock:
            self._load_locked()
            return dict(self._rows)

    def age_seconds(self):
        """Seconds since the last successful download; None when there is none (or the clock moved back)."""
        with self._lock:
            self._load_locked()
            if self._fetched_at is None or not self._rows:
                return None
            age = self._clock() - self._fetched_at
            return age if age >= -86400 else None

    def needs_refresh(self):
        age = self.age_seconds()
        return age is None or age >= PRICE_TABLE_MAX_AGE_SECONDS

    def refresh(self, fetch=fetch_eurostat_table):
        table = fetch()
        rows = {code: row for code, row in table["rows"].items() if _iso2(code) and _valid_row(row)}
        if len(rows) < PRICE_TABLE_MIN_ROWS:
            raise ValueError("The downloaded table has too few countries")
        table["rows"] = rows
        encoded = json.dumps(table, ensure_ascii=False, indent=1, sort_keys=True, allow_nan=False).encode("utf-8")
        _atomic_write_bytes(self.path, encoded)
        with self._lock:
            self._loaded = True
            self._rows = rows
            self._fetched_at = table.get("fetchedAt")
        return len(rows)


class PriceRefresher:
    """Refreshes the table on a daemon thread: first check a minute after start, then daily;
    downloads only when the saved table is missing or 30 days old. Failures are logged quietly."""

    def __init__(self, table, *, fetch=fetch_eurostat_table, first_check=PRICE_TABLE_FIRST_CHECK_SECONDS,
                 interval=PRICE_TABLE_RETRY_SECONDS, on_refresh=None):
        self.table = table
        self.fetch = fetch
        self.first_check = first_check
        self.interval = interval
        self.on_refresh = on_refresh
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, name="orbit-energy-prices", daemon=True)

    def check_once(self):
        try:
            if not self.table.needs_refresh():
                return False
            count = self.table.refresh(self.fetch)
            LOGGER.info("Updated electricity prices for %s countries from Eurostat", count)
            if self.on_refresh is not None:
                self.on_refresh()
            return True
        except Exception as error:  # Silent by design: the built-in table keeps working.
            LOGGER.info("Could not update electricity prices from Eurostat (%s); using saved prices", type(error).__name__)
            return False

    def _run(self):
        delay = self.first_check
        while not self.stop_event.wait(delay):
            delay = self.interval
            self.check_once()

    def start(self):
        self.thread.start()

    def stop(self, timeout=2.0):
        self.stop_event.set()
        if self.thread.is_alive():
            self.thread.join(timeout)


# Price resolution -------------------------------------------------------------------------------

def _public_row(row):
    if not row:
        return None
    return {"pricePerKWh": row["price"], "currency": row["currency"], "source": row["source"], "period": row["period"]}


def default_price_row(country, table_rows, builtin=BUILTIN_PRICES):
    """The table row for a country: the newer of the downloaded and the built-in row."""
    code = _iso2(country)
    if not code:
        return None
    downloaded = table_rows.get(code) if table_rows else None
    built_in = builtin.get(code)
    if downloaded and built_in:
        return downloaded if _period_key(downloaded["period"]) >= _period_key(built_in["period"]) else built_in
    return downloaded or built_in


def valid_override(value):
    if not isinstance(value, dict):
        return None
    price = _number(value.get("pricePerKWh"), 0.0, MAX_PRICE_PER_KWH)
    currency = value.get("currency")
    if price is None or not is_currency_code(currency):
        return None
    return {"pricePerKWh": price, "currency": currency.upper()}


def is_currency_code(value):
    return isinstance(value, str) and bool(_CURRENCY.match(value)) and value.upper() in ISO_4217


def resolve_price(country, override, table_rows, builtin=BUILTIN_PRICES, currency_hint=None):
    """The `GET /api/energy/price` object."""
    default = default_price_row(country, table_rows, builtin)
    result = {"country": _iso2(country), "pricePerKWh": None, "currency": None, "source": None, "period": None,
              "isOverride": False, "defaultPrice": _public_row(default)}
    own = valid_override(override)
    if own:
        result.update(pricePerKWh=own["pricePerKWh"], currency=own["currency"], source="Your own price", isOverride=True)
    elif default:
        result.update(pricePerKWh=default["price"], currency=default["currency"], source=default["source"],
                      period=default["period"])
    elif result["country"] and currency_hint is not None:
        result["currency"] = currency_hint(result["country"])
    return result


def country_name(code, table_rows=None):
    code = _iso2(code)
    if not code:
        return None
    row = (table_rows or {}).get(code) or BUILTIN_PRICES.get(code)
    return row.get("name") if row and row.get("name") else code


# Settings ---------------------------------------------------------------------------------------

def _store(store=None):
    return store if store is not None else orbit_settings.shared_store()


def _section(store):
    section = store.get(SETTINGS_SECTION, {})
    return section if isinstance(section, dict) else {}


def energy_settings(store=None):
    """`{"baseWatts": 60.0, "psuEfficiency": 0.88}`; invalid saved values fall back to the defaults."""
    section = _section(_store(store))
    base = _number(section.get("baseWatts"), *BASE_WATTS_RANGE)
    efficiency = _number(section.get("psuEfficiency"), *PSU_EFFICIENCY_RANGE)
    return {"baseWatts": DEFAULT_BASE_WATTS if base is None else base,
            "psuEfficiency": DEFAULT_PSU_EFFICIENCY if efficiency is None else efficiency}


def validate_settings_update(payload):
    """The values to save from a `PUT /api/energy/settings` body; ValueError in plain words."""
    if not isinstance(payload, dict):
        raise ValueError("Send the settings as a JSON object.")
    changes = {}
    if "baseWatts" in payload:
        value = _number(payload["baseWatts"], *BASE_WATTS_RANGE)
        if value is None:
            raise ValueError("The rest-of-system power must be a number of watts from 0 to 500.")
        changes["baseWatts"] = value
    if "psuEfficiency" in payload:
        value = _number(payload["psuEfficiency"], *PSU_EFFICIENCY_RANGE)
        if value is None:
            raise ValueError("The power supply efficiency must be a number from 0.5 to 1.")
        changes["psuEfficiency"] = value
    if not changes:
        raise ValueError("Send baseWatts, psuEfficiency or both.")
    return changes


def validate_price_update(payload):
    """`("reset", None)` or `("set", {"pricePerKWh", "currency"})`; ValueError in plain words."""
    if not isinstance(payload, dict):
        raise ValueError("Send the price as a JSON object.")
    if payload.get("reset") is True:
        if "pricePerKWh" in payload:
            raise ValueError("Send either a new price or reset, not both.")
        return "reset", None
    if "reset" in payload and payload.get("reset") is not False:
        raise ValueError("reset must be true or false.")
    price = _number(payload.get("pricePerKWh"), 0.0, MAX_PRICE_PER_KWH)
    if price is None:
        raise ValueError("Enter the price per kWh as a number, for example 1.07.")
    currency = payload.get("currency")
    if not isinstance(currency, str) or not is_currency_code(currency.strip()):
        raise ValueError("Choose the currency of your price as a three-letter code, for example RON or EUR.")
    return "set", {"pricePerKWh": price, "currency": currency.strip().upper()}


# Ledger -----------------------------------------------------------------------------------------

LEDGER_SCHEMA = """
CREATE TABLE IF NOT EXISTS energy_daily (
    day TEXT NOT NULL, game TEXT NOT NULL DEFAULT '',
    cpu_wh REAL NOT NULL DEFAULT 0, gpu_wh REAL NOT NULL DEFAULT 0, base_wh REAL NOT NULL DEFAULT 0,
    wall_wh REAL NOT NULL DEFAULT 0, seconds REAL NOT NULL DEFAULT 0, measured_seconds REAL NOT NULL DEFAULT 0,
    cost REAL, currency TEXT,
    PRIMARY KEY (day, game)
);
CREATE TABLE IF NOT EXISTS game_daily (
    day TEXT NOT NULL, game TEXT NOT NULL, display_name TEXT,
    play_seconds REAL NOT NULL DEFAULT 0, fps_sum REAL NOT NULL DEFAULT 0, fps_count INTEGER NOT NULL DEFAULT 0,
    cpu_temp_sum REAL NOT NULL DEFAULT 0, cpu_temp_count INTEGER NOT NULL DEFAULT 0, cpu_temp_peak REAL,
    gpu_temp_sum REAL NOT NULL DEFAULT 0, gpu_temp_count INTEGER NOT NULL DEFAULT 0, gpu_temp_peak REAL,
    PRIMARY KEY (day, game)
);
CREATE TABLE IF NOT EXISTS game_spans (
    id INTEGER PRIMARY KEY, game TEXT NOT NULL, display_name TEXT,
    started_at REAL NOT NULL, ended_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS game_spans_started ON game_spans(started_at);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"""


class Ledger:
    """`ledger.sqlite3`: energy_daily (this module), game_daily and game_spans (orbit_summary), meta.

    One connection guarded by `lock`. Writes go through `transaction()` (BEGIN IMMEDIATE), so the
    boot-time and the signed-in instance can share the file during a hand-over.
    """

    def __init__(self, path=None):
        self.path = Path(path) if path is not None else default_ledger_path()
        self.lock = threading.RLock()
        self._closed = False
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.db = self._open()
        except sqlite3.OperationalError:
            raise  # Locked or unreachable, not damaged: never set a good ledger aside.
        except sqlite3.DatabaseError:
            damaged = self.path.with_name(self.path.name + ".corrupt")
            LOGGER.warning("The energy ledger was unreadable and was moved to %s", damaged)
            for suffix in ("-wal", "-shm"):
                Path(str(self.path) + suffix).unlink(missing_ok=True)
            os.replace(self.path, damaged)
            self.db = self._open()

    def _open(self):
        db = sqlite3.connect(self.path, check_same_thread=False, timeout=5.0, isolation_level=None)
        try:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA journal_mode = WAL")
            db.executescript(LEDGER_SCHEMA)
            db.execute("SELECT COUNT(*) FROM energy_daily").fetchone()
            return db
        except BaseException:
            db.close()
            raise

    @contextlib.contextmanager
    def transaction(self):
        with self.lock:
            if self._closed:
                raise RuntimeError("The energy ledger is closed.")
            self.db.execute("BEGIN IMMEDIATE")
            try:
                yield self.db
                self.db.execute("COMMIT")
            except BaseException:
                # Also after a failed COMMIT (busy disk, I/O error): never leave a transaction open.
                with contextlib.suppress(sqlite3.Error):
                    self.db.execute("ROLLBACK")
                raise

    def query(self, sql, parameters=()):
        with self.lock:
            if self._closed:
                raise RuntimeError("The energy ledger is closed.")
            return self.db.execute(sql, parameters).fetchall()

    def meta(self, key):
        rows = self.query("SELECT value FROM meta WHERE key = ?", (key,))
        return rows[0]["value"] if rows else None

    def set_meta(self, key, value):
        with self.transaction() as db:
            db.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       (key, value))

    def prune(self, now, retention_days=RETENTION_DAYS):
        cutoff = now - retention_days * 86400
        cutoff_day = time.strftime("%Y-%m-%d", time.gmtime(cutoff))
        with self.transaction() as db:
            db.execute("DELETE FROM energy_daily WHERE day < ?", (cutoff_day,))
            db.execute("DELETE FROM game_daily WHERE day < ?", (cutoff_day,))
            db.execute("DELETE FROM game_spans WHERE ended_at < ?", (cutoff,))

    def available_months(self):
        rows = self.query("""SELECT substr(day, 1, 7) AS month FROM energy_daily WHERE seconds > 0
                             UNION SELECT substr(day, 1, 7) FROM game_daily WHERE play_seconds > 0 ORDER BY month""")
        return [row["month"] for row in rows]

    def close(self):
        with self.lock:
            if not self._closed:
                self._closed = True
                self.db.close()

    @property
    def closed(self):
        return self._closed


class _EnergyBucket:
    __slots__ = ("cpu_wh", "gpu_wh", "base_wh", "wall_wh", "seconds", "measured_seconds", "cost", "currency", "last_price")

    def __init__(self):
        self.cpu_wh = self.gpu_wh = self.base_wh = self.wall_wh = 0.0
        self.seconds = self.measured_seconds = 0.0
        self.cost = 0.0
        self.currency = None
        self.last_price = None


class EnergyTracker:
    """In-memory energy per (day, game) since the last flush."""

    def __init__(self, ledger):
        self.ledger = ledger
        self._pending = {}
        self._last_game = ""

    def add(self, snapshot, dt, now, day, context):
        available = snapshot.get("telemetryAvailable") is not False
        if available:
            self._last_game = game_key(snapshot.get("activeGameProcess") or snapshot.get("activeGame"))
        if dt <= 0:
            return
        cpu = _watts(snapshot.get("cpuPowerWatts")) if available else None
        gpu = _watts(snapshot.get("gpuPowerWatts")) if available else None
        base, efficiency = context["baseWatts"], context["psuEfficiency"]
        hours = dt / 3600.0
        cpu_wh = (cpu or 0.0) * hours
        gpu_wh = (gpu or 0.0) * hours
        base_wh = base * hours
        wall_wh = (cpu_wh + gpu_wh + base_wh) / efficiency
        bucket = self._pending.get((day, self._last_game))
        if bucket is None:
            bucket = self._pending[(day, self._last_game)] = _EnergyBucket()
        price, currency = context.get("price"), context.get("currency")
        if price is not None and currency is not None:
            if bucket.currency != currency:
                # A different currency (or the first priced tick): restate what this bucket holds.
                bucket.cost = bucket.wall_wh / 1000.0 * price
                bucket.currency = currency
            bucket.cost += wall_wh / 1000.0 * price
            bucket.last_price = price
        bucket.cpu_wh += cpu_wh
        bucket.gpu_wh += gpu_wh
        bucket.base_wh += base_wh
        bucket.wall_wh += wall_wh
        bucket.seconds += dt
        if cpu is not None or gpu is not None:
            bucket.measured_seconds += dt

    def flush(self, db):
        for (day, game), bucket in self._pending.items():
            row = db.execute("SELECT wall_wh, cost, currency FROM energy_daily WHERE day = ? AND game = ?", (day, game)).fetchone()
            if row is None:
                db.execute("""INSERT INTO energy_daily (day, game, cpu_wh, gpu_wh, base_wh, wall_wh, seconds,
                              measured_seconds, cost, currency) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                           (day, game, bucket.cpu_wh, bucket.gpu_wh, bucket.base_wh, bucket.wall_wh, bucket.seconds,
                            bucket.measured_seconds, bucket.cost if bucket.currency else None, bucket.currency))
                continue
            cost, currency = row["cost"], row["currency"]
            if bucket.currency is not None:
                if currency != bucket.currency:
                    cost = row["wall_wh"] / 1000.0 * bucket.last_price
                    currency = bucket.currency
                cost = (cost or 0.0) + bucket.cost
            db.execute("""UPDATE energy_daily SET cpu_wh = cpu_wh + ?, gpu_wh = gpu_wh + ?, base_wh = base_wh + ?,
                          wall_wh = wall_wh + ?, seconds = seconds + ?, measured_seconds = measured_seconds + ?,
                          cost = ?, currency = ? WHERE day = ? AND game = ?""",
                       (bucket.cpu_wh, bucket.gpu_wh, bucket.base_wh, bucket.wall_wh, bucket.seconds,
                        bucket.measured_seconds, cost, currency, day, game))

    def flushed(self):
        self._pending.clear()

    def periodic(self, now):
        pass


class LedgerRuntime:
    """Feeds the trackers from telemetry ticks and writes them every `flush_interval` seconds."""

    def __init__(self, ledger, trackers, *, price_provider, settings_provider, clock=time.time,
                 monotonic=time.monotonic, day_of=local_day, flush_interval=FLUSH_SECONDS):
        self.ledger = ledger
        self.trackers = list(trackers)
        self._price_provider = price_provider
        self._settings_provider = settings_provider
        self._clock = clock
        self._monotonic = monotonic
        self.day_of = day_of
        self.flush_interval = flush_interval
        self._last_tick = None
        self._last_flush = None
        self._context = None
        self._context_at = None
        self._pruned_day = None
        self._flush_failed = False

    # Price and settings, cached for 30 s (a PUT invalidates them at once).
    def invalidate(self):
        with self.ledger.lock:
            self._context = None

    def _current_context(self, mono):
        if self._context is None or mono - self._context_at >= PRICE_CACHE_SECONDS:
            context = {"price": None, "currency": None, "baseWatts": DEFAULT_BASE_WATTS,
                       "psuEfficiency": DEFAULT_PSU_EFFICIENCY}
            try:
                context.update(self._settings_provider())
            except Exception:
                LOGGER.warning("Could not read the energy settings; using defaults", exc_info=True)
            try:
                price = self._price_provider()
                if price.get("pricePerKWh") is not None and price.get("currency"):
                    context.update(price=float(price["pricePerKWh"]), currency=price["currency"])
            except Exception:
                LOGGER.warning("Could not work out the electricity price", exc_info=True)
            self._context, self._context_at = context, mono
        return self._context

    def record(self, snapshot):
        if not isinstance(snapshot, dict):
            return
        run_periodic = False
        with self.ledger.lock:
            if self.ledger.closed:
                return
            mono = self._monotonic()
            now = self._clock()
            dt = 0.0 if self._last_tick is None else min(max(mono - self._last_tick, 0.0), MAX_TICK_SECONDS)
            self._last_tick = mono
            day = self.day_of(now)
            context = self._current_context(mono)
            for tracker in self.trackers:
                try:
                    tracker.add(snapshot, dt, now, day, context)
                except Exception:
                    LOGGER.exception("The %s could not record this tick", type(tracker).__name__)
            if self._last_flush is None:
                self._last_flush = mono
            elif mono - self._last_flush >= self.flush_interval:
                self._last_flush = mono
                self.flush()
                run_periodic = True
        if run_periodic:
            self._periodic(now)

    def flush(self):
        """Writes every tracker's totals in one transaction. Returns False (and keeps them) on failure."""
        with self.ledger.lock:
            if self.ledger.closed:
                return False
            try:
                with self.ledger.transaction() as db:
                    for tracker in self.trackers:
                        tracker.flush(db)
            except Exception:
                if not self._flush_failed:
                    LOGGER.exception("Could not save the energy ledger; will retry")
                self._flush_failed = True
                return False
            self._flush_failed = False
            for tracker in self.trackers:
                tracker.flushed()
            return True

    def _periodic(self, now):
        day = self.day_of(now)
        if day != self._pruned_day:
            try:
                self.ledger.prune(now)
                self._pruned_day = day
            except (sqlite3.Error, RuntimeError):
                LOGGER.warning("Could not remove old energy ledger rows", exc_info=True)
        for tracker in self.trackers:
            try:
                tracker.periodic(now)
            except Exception:
                LOGGER.exception("Periodic work of the %s failed", type(tracker).__name__)

    def today(self):
        return self.day_of(self._clock())

    def now(self):
        return self._clock()

    def close(self):
        with self.ledger.lock:
            if self.ledger.closed:
                return
            self.flush()
            self.ledger.close()


# Reports ----------------------------------------------------------------------------------------

def _round(value, digits):
    return None if value is None else round(value, digits)


def _month_costing(rows, price):
    """The currency for a report and the unit price for rows without a cost in it."""
    if price and price.get("pricePerKWh") is not None and price.get("currency"):
        return price["currency"], float(price["pricePerKWh"])
    priced = [row for row in rows if row["currency"] and row["cost"] is not None]
    if priced:
        return max(priced, key=lambda row: row["day"])["currency"], None
    return None, None


def row_cost(row, currency, unit_price):
    """A ledger row's cost in `currency`: its own cost when it has that currency, else its energy
    at `unit_price` (the current price); None when neither is possible."""
    if currency is None:
        return None
    if row["currency"] == currency and row["cost"] is not None:
        return row["cost"]
    if unit_price is not None:
        return row["wall_wh"] / 1000.0 * unit_price
    return None


def latest_display_names(ledger, first_day=None, after_day=None):
    if first_day is None:
        rows = ledger.query("SELECT game, display_name, day FROM game_daily WHERE display_name IS NOT NULL ORDER BY day")
    else:
        rows = ledger.query("""SELECT game, display_name, day FROM game_daily WHERE display_name IS NOT NULL
                               AND day >= ? AND day < ? ORDER BY day""", (first_day, after_day))
    return {row["game"]: row["display_name"] for row in rows}


def prettify_game_name(stem):
    """"Cyberpunk 2077" for "Cyberpunk2077", "CS2" for "cs2", "Fortnite Client" for
    "FortniteClient-Win64-Shipping": the best guess when no store knows the game."""
    text = re.split(r"[\\/]", stem or "")[-1].strip()
    if text.lower().endswith(".exe"):
        text = text[:-4]
    tokens = [token for token in re.split(r"[-_.\s]+", text.strip()) if token]
    noise = {"shipping", "win64", "win32", "wingdk", "x64", "x86", "dx11", "dx12", "vulkan", "vk", "be", "eac",
             "retail", "final", "release", "steam", "egs", "gog"}
    while len(tokens) > 1 and tokens[-1].lower() in noise:
        tokens.pop()
    words = []
    for token in tokens:
        if any(char.isdigit() for char in token) and len(token) <= 4:
            words.append(token.upper())
            continue
        for part in re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+|[^\W\d_]+", token):
            words.append(part[:1].upper() + part[1:] if part.islower() else part)
    return " ".join(words)[:100] or "Game"


def energy_month(ledger, year, month, price, *, today):
    """The `GET /api/energy/summary` object (the ledger must be flushed first)."""
    first, after = month_day_range(year, month)
    rows = ledger.query("SELECT * FROM energy_daily WHERE day >= ? AND day < ?", (first, after))
    today_rows = ledger.query("SELECT * FROM energy_daily WHERE day = ?", (today,))
    currency, unit = _month_costing(list(rows) + list(today_rows), price)
    names = latest_display_names(ledger, first, after)
    total_wh = cpu_wh = gpu_wh = base_wh = seconds = measured = 0.0
    total_cost, costed = 0.0, False
    days, games = {}, {}
    for row in rows:
        cost = row_cost(row, currency, unit)
        total_wh += row["wall_wh"]
        cpu_wh += row["cpu_wh"]
        gpu_wh += row["gpu_wh"]
        base_wh += row["base_wh"]
        seconds += row["seconds"]
        measured += row["measured_seconds"]
        if cost is not None:
            total_cost += cost
            costed = True
        day = days.setdefault(row["day"], [0.0, None])
        day[0] += row["wall_wh"]
        if cost is not None:
            day[1] = (day[1] or 0.0) + cost
        if row["game"]:
            game = games.setdefault(row["game"], [0.0, None, 0.0])
            game[0] += row["wall_wh"]
            game[2] += row["seconds"]
            if cost is not None:
                game[1] = (game[1] or 0.0) + cost
    # Every day of the month up to today (zero when the agent was not running), for the chart.
    last_day = min(after, _next_day(today)) if first <= today else first
    day_list = []
    cursor = first
    while cursor < last_day:
        wh, cost = days.get(cursor, (0.0, None))
        day_list.append({"day": cursor, "kWh": round(wh / 1000.0, 3),
                         "cost": _round(cost if cost is not None else (0.0 if currency else None), 2)})
        cursor = _next_day(cursor)
    game_list = [{"game": key, "name": names.get(key) or prettify_game_name(key), "kWh": round(wh / 1000.0, 3),
                  "cost": _round(cost, 2), "hours": round(spent / 3600.0, 2)}
                 for key, (wh, cost, spent) in games.items()]
    game_list.sort(key=lambda item: (-item["kWh"], item["name"]))
    today_wh = sum(row["wall_wh"] for row in today_rows)
    today_costs = [row_cost(row, currency, unit) for row in today_rows]
    today_cost = sum(cost for cost in today_costs if cost is not None) if any(c is not None for c in today_costs) else None
    loss_wh = max(0.0, total_wh - cpu_wh - gpu_wh - base_wh)
    return {
        "month": month_text(year, month),
        "kWh": round(total_wh / 1000.0, 3),
        "cost": _round(total_cost if costed else (0.0 if currency else None), 2),
        "currency": currency,
        "isEstimate": True,
        "coverage": round(measured / seconds, 3) if seconds > 0 else None,
        "days": day_list,
        "games": game_list,
        "today": {"kWh": round(today_wh / 1000.0, 3),
                  "cost": _round(today_cost if today_cost is not None else (0.0 if currency else None), 2)},
        "price": price,
        "breakdown": {"cpuKWh": round(cpu_wh / 1000.0, 3), "gpuKWh": round(gpu_wh / 1000.0, 3),
                      "baseKWh": round(base_wh / 1000.0, 3), "lossKWh": round(loss_wh / 1000.0, 3)},
        "trackedHours": round(seconds / 3600.0, 2),
        "available": ledger.available_months(),
    }


def _next_day(day):
    year, month, number = (int(part) for part in day.split("-"))
    days_in_month = calendar.monthrange(year, month)[1]
    if number < days_in_month:
        return f"{year:04d}-{month:02d}-{number + 1:02d}"
    year, month = shift_month(year, month, 1)
    return f"{year:04d}-{month:02d}-01"


def day_unit_prices(ledger, days, currency):
    """The average price per kWh the ledger used on each day, in `currency`."""
    if not days or not currency:
        return {}
    days = sorted(set(days))
    result = {}
    for start in range(0, len(days), 400):
        chunk = days[start:start + 400]
        placeholders = ",".join("?" for _ in chunk)
        rows = ledger.query(f"""SELECT day, SUM(cost) AS cost, SUM(wall_wh) AS wall FROM energy_daily
                                WHERE currency = ? AND cost IS NOT NULL AND day IN ({placeholders}) GROUP BY day""",
                            (currency, *chunk))
        for row in rows:
            if row["wall"] and row["wall"] > 0:
                result[row["day"]] = row["cost"] / (row["wall"] / 1000.0)
    return result


def session_energy(samples, settings, price, *, day_of=local_day, unit_prices=None):
    """`{"kWh", "cost", "currency", "coverage"}` for a history session.

    Consecutive samples of one segment are joined (each reading holds until the next sample, at
    most 15 s); the base load counts for all of that time. Each stretch is priced with the
    average price the ledger used that day, else the current price.
    """
    base = settings["baseWatts"]
    efficiency = settings["psuEfficiency"]
    currency = price.get("currency") if price and price.get("pricePerKWh") is not None else None
    current_unit = float(price["pricePerKWh"]) if currency else None
    unit_prices = unit_prices or {}
    total_wh = cost = seconds = measured = 0.0
    previous = None
    for sample in samples:
        if previous is not None and sample["segment"] == previous["segment"]:
            dt = min(sample["timestamp"] - previous["timestamp"], SESSION_GAP_SECONDS)
            if dt > 0:
                available = previous.get("telemetryAvailable") is not False
                cpu = _watts(previous.get("cpuPowerWatts")) if available else None
                gpu = _watts(previous.get("gpuPowerWatts")) if available else None
                wall_wh = ((cpu or 0.0) + (gpu or 0.0) + base) / efficiency * dt / 3600.0
                total_wh += wall_wh
                seconds += dt
                if cpu is not None or gpu is not None:
                    measured += dt
                if currency:
                    cost += wall_wh / 1000.0 * unit_prices.get(day_of(previous["timestamp"]), current_unit)
        previous = sample
    return {"kWh": round(total_wh / 1000.0, 4), "cost": round(cost, 2) if currency else None, "currency": currency,
            "coverage": round(measured / seconds, 3) if seconds > 0 else None}


# The running agent's state ----------------------------------------------------------------------

_RUNTIME_LOCK = threading.Lock()
_RUNTIME = None
_REFRESHER = None
_RETRY = None
COUNTRY = CountryResolver()
PRICE_TABLE = PriceTable()


def current_price(store=None):
    """The `GET /api/energy/price` object for this PC right now."""
    store = _store(store)
    country = COUNTRY.country(store)
    override = _section(store).get("override")
    return resolve_price(country, override, PRICE_TABLE.rows(), BUILTIN_PRICES, currency_hint=COUNTRY.currency)


def current_runtime():
    with _RUNTIME_LOCK:
        return _RUNTIME


def price_changed():
    """Call after the price, the settings or the price table changed, so ticks use the new values."""
    runtime = current_runtime()
    if runtime is not None:
        runtime.invalidate()


def _open_runtime(extra_trackers=(), path=None):
    """Opens the ledger and builds the runtime; raises when the ledger cannot be opened."""
    ledger = Ledger(path)
    try:
        trackers = [EnergyTracker(ledger)]
        for factory in extra_trackers:
            trackers.append(factory(ledger))
        runtime = LedgerRuntime(ledger, trackers, price_provider=current_price, settings_provider=energy_settings)
    except BaseException:
        ledger.close()
        raise
    try:
        ledger.prune(time.time())
    except (sqlite3.Error, RuntimeError):
        LOGGER.warning("Could not remove old energy ledger rows", exc_info=True)
    return runtime


class LedgerRetry:
    """Tries to open the ledger again every `LEDGER_RETRY_SECONDS` after it failed at start (a
    backup or antivirus holding the file, the boot-time instance still handing over), so one bad
    moment does not pause electricity cost and summaries until the agent restarts."""

    def __init__(self, extra_trackers=(), path=None, *, interval=None):
        self.extra_trackers = tuple(extra_trackers)
        self.path = path
        self.interval = LEDGER_RETRY_SECONDS if interval is None else interval
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, name="orbit-energy-ledger", daemon=True)
        self._failures = 0

    def attempt(self):
        """One try. True once the ledger is open and installed (or retrying is no longer wanted)."""
        global _RUNTIME, _RETRY
        if self.stop_event.is_set():
            return True
        try:
            runtime = _open_runtime(self.extra_trackers, self.path)
        except Exception as error:
            self._failures += 1
            if self._failures == 1:
                LOGGER.warning("The energy ledger still cannot be opened (%s); trying again every minute", error)
            return False
        with _RUNTIME_LOCK:
            installed = _RETRY is self and _RUNTIME is None and not self.stop_event.is_set()
            if installed:
                _RUNTIME, _RETRY = runtime, None
        if not installed:  # stop() ran meanwhile: leave nothing open.
            runtime.close()
            return True
        LOGGER.info("The energy ledger is open again; electricity cost and monthly summaries resumed")
        return True

    def _run(self):
        while not self.stop_event.wait(self.interval):
            if self.attempt():
                return

    def start(self):
        self.thread.start()

    def stop(self, timeout=7.0):
        self.stop_event.set()
        if self.thread.is_alive() and self.thread is not threading.current_thread():
            self.thread.join(timeout)


def start(extra_trackers=(), *, boot_mode=False, path=None, refresh=True):
    """Opens the ledger and starts recording (call from the agent's lifespan). Never raises:
    without a ledger the price routes still work, the summaries answer 503 and the ledger is
    tried again every minute."""
    global _RUNTIME, _REFRESHER, _RETRY
    COUNTRY.boot_mode = bool(boot_mode)
    COUNTRY.reset()
    runtime = retry = None
    try:
        runtime = _open_runtime(extra_trackers, path)
    except Exception:
        LOGGER.exception("The energy ledger could not be opened; electricity cost and monthly summaries are paused "
                         "until it can be (trying again every minute)")
        retry = LedgerRetry(extra_trackers, path)
    refresher = None
    if refresh and os.getenv("ORBIT_ENERGY_PRICE_REFRESH", "1") != "0":
        refresher = PriceRefresher(PRICE_TABLE, on_refresh=price_changed)
        refresher.start()
    with _RUNTIME_LOCK:
        _RUNTIME, _REFRESHER, _RETRY = runtime, refresher, retry
    if retry is not None:
        retry.start()
    return runtime


def stop():
    """Writes what is still in memory and closes the ledger (call at shutdown)."""
    global _RUNTIME, _REFRESHER, _RETRY
    with _RUNTIME_LOCK:
        runtime, refresher, retry = _RUNTIME, _REFRESHER, _RETRY
        _RUNTIME = _REFRESHER = _RETRY = None
    if retry is not None:
        retry.stop()
    if refresher is not None:
        refresher.stop()
    if runtime is not None:
        try:
            runtime.close()
        except Exception:
            LOGGER.exception("Could not close the energy ledger cleanly")


def record_tick(snapshot):
    """Telemetry hook: one call per tick with the agent's status snapshot. Never raises."""
    runtime = current_runtime()
    if runtime is None:
        return
    try:
        runtime.record(snapshot)
    except Exception:
        LOGGER.exception("Could not add this tick to the energy ledger")


def session_energy_extras(recorder, session_id):
    """`{"energy": {...}}` for `GET /api/history/sessions/{id}`."""
    samples = recorder.power_samples(session_id)
    settings = energy_settings()
    price = current_price()
    runtime = current_runtime()
    unit_prices = {}
    if runtime is not None and price.get("currency") and samples:
        runtime.flush()
        unit_prices = day_unit_prices(runtime.ledger, {runtime.day_of(sample["timestamp"]) for sample in samples},
                                      price["currency"])
    day_of = runtime.day_of if runtime is not None else local_day
    return {"energy": session_energy(samples, settings, price, day_of=day_of, unit_prices=unit_prices)}


def tray_price_message(store=None):
    """Title and text of the tray's "Electricity price..." dialog."""
    price = current_price(store)
    rows = PRICE_TABLE.rows()
    code = price.get("country")
    name = country_name(code, rows)
    country_line = f"Country: {name} ({code}), from the Windows region setting" if code and name != code else (
        f"Country: {code}, from the Windows region setting" if code else
        "Country: not set in Windows (Settings > Time & language > Language & region)")
    how = ("To change it, open Orbit on your iPhone, go to Tools > Electricity Cost and edit the price. "
           "The rest-of-system power and power supply efficiency are set there too.")
    if price.get("pricePerKWh") is None:
        lines = [country_line, "", "Orbit has no electricity price for this country yet.",
                 "Set your price per kWh in Orbit on your iPhone: Tools > Electricity Cost."]
    else:
        amount = f"{price['pricePerKWh']:.4f}".rstrip("0").rstrip(".")
        price_line = f"Price: {amount} {price['currency']} per kWh"
        if price.get("isOverride"):
            source_line = "Source: your own price, set from your phone"
        else:
            source_line = f"Source: {price['source']}, the national average household price with taxes"
        lines = [country_line, price_line, source_line, "",
                 "Orbit multiplies this price by your PC's estimated energy use (CPU, GPU and the rest of the system).",
                 how]
    return "Orbit · Electricity price", "\n".join(lines)


# HTTP routes ------------------------------------------------------------------------------------

def create_energy_router(verify_control, require_encrypted, store_provider=None):
    """`/api/energy/*` behind the main token and the encrypted connection."""
    router = APIRouter(prefix="/api/energy", tags=["Electricity cost"],
                       dependencies=[Depends(verify_control), Depends(require_encrypted)])

    def store():
        return store_provider() if store_provider is not None else orbit_settings.shared_store()

    @router.get("/price")
    def get_price():
        return current_price(store())

    @router.put("/price")
    def put_price(payload: dict = Body(...)):
        try:
            action, value = validate_price_update(payload)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        settings = store()

        def change(section):
            section = section if isinstance(section, dict) else {}
            if action == "reset":
                section.pop("override", None)
            else:
                section["override"] = {**value, "setAt": iso_utc(time.time())}
            return section
        try:
            settings.modify(SETTINGS_SECTION, change, default={})
        except (OSError, ValueError) as error:
            raise HTTPException(503, "The PC could not save the electricity price. Try again in a moment.") from error
        price_changed()
        return current_price(settings)

    @router.get("/settings")
    def get_settings():
        return energy_settings(store())

    @router.put("/settings")
    def put_settings(payload: dict = Body(...)):
        try:
            changes = validate_settings_update(payload)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        settings = store()
        try:
            settings.update(SETTINGS_SECTION, changes)
        except (OSError, ValueError) as error:
            raise HTTPException(503, "The PC could not save the energy settings. Try again in a moment.") from error
        price_changed()
        return energy_settings(settings)

    @router.get("/summary")
    def get_summary(month: str | None = Query(default=None, max_length=16)):
        runtime = current_runtime()
        if runtime is None:
            raise HTTPException(503, ("Electricity tracking is not running on the PC yet. Try again in a minute; "
                                     "if this keeps happening, restart Orbit PC Companion."))
        today = runtime.today()
        try:
            year, number = parse_month(month) if month else parse_month(today[:7])
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        price = current_price(store())
        try:
            runtime.flush()
            return energy_month(runtime.ledger, year, number, price, today=today)
        except (sqlite3.Error, RuntimeError) as error:
            raise HTTPException(503, "The PC could not read its energy history. Try again in a moment.") from error

    return router
