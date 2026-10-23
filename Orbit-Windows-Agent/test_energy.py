"""Electricity cost: country detection, Eurostat parsing, price precedence, the ledger maths, routes.

Windows APIs are fakes, the network is never used (the Eurostat answer is a saved, trimmed real
response in test_fixtures/), and every file lives in a temporary folder.
"""
import contextlib
import email.message
import io
import json
import math
import os
from pathlib import Path
import sqlite3
import ssl
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch
import urllib.error
import urllib.request
import urllib.response

from fastapi.testclient import TestClient

import orbit_energy as energy
import orbit_history
import orbit_settings

FIXTURE = Path(__file__).resolve().parent / "test_fixtures" / "eurostat_nrg_pc_204_trimmed.json"
TOKEN = "test-control-token-at-least-24-chars"


def load_fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def utc_day(timestamp):
    return time.strftime("%Y-%m-%d", time.gmtime(timestamp))


def utc(text):
    """Unix time of `YYYY-MM-DD HH:MM:SS` in UTC."""
    import calendar
    return calendar.timegm(time.strptime(text, "%Y-%m-%d %H:%M:%S"))


class FakeFunction:
    def __init__(self, behaviour):
        self.behaviour = behaviour
        self.argtypes = None
        self.restype = None
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        return self.behaviour(*args)


class FakeKernel32:
    """Only the functions given exist, like an older Windows without GetUserDefaultGeoName."""

    def __init__(self, **functions):
        for name, behaviour in functions.items():
            setattr(self, name, FakeFunction(behaviour))


def writes(text, result=None):
    def behaviour(*args):
        buffer = next(arg for arg in args if hasattr(arg, "value") and not isinstance(arg, (int, str)))
        buffer.value = text
        return len(text) + 1 if result is None else result
    return behaviour


class Clock:
    def __init__(self, start):
        self.now = float(start)

    def __call__(self):
        return self.now


class CountryDetectionTests(unittest.TestCase):
    def test_home_location_from_get_user_default_geo_name_with_declared_signatures(self):
        import ctypes
        kernel = FakeKernel32(GetUserDefaultGeoName=writes("ro"))
        self.assertEqual(energy.detect_country(kernel), "RO")
        function = kernel.GetUserDefaultGeoName
        self.assertEqual(function.argtypes, [ctypes.c_wchar_p, ctypes.c_int])
        self.assertIs(function.restype, ctypes.c_int)
        self.assertEqual(function.calls[0][1], energy.GEO_BUFFER_CHARS)

    def test_un_m49_answer_falls_back_to_geo_id_and_iso2(self):
        import ctypes
        kernel = FakeKernel32(GetUserDefaultGeoName=writes("419"), GetUserGeoID=lambda geo_class: 166,
                              GetGeoInfoW=writes("MX"))
        self.assertEqual(energy.detect_country(kernel), "MX")
        self.assertEqual(kernel.GetUserGeoID.calls, [(energy.GEOCLASS_NATION,)])
        self.assertEqual(kernel.GetUserGeoID.argtypes, [ctypes.c_uint32])
        self.assertIs(kernel.GetUserGeoID.restype, ctypes.c_long)
        self.assertEqual(kernel.GetGeoInfoW.argtypes,
                         [ctypes.c_long, ctypes.c_uint32, ctypes.c_wchar_p, ctypes.c_int, ctypes.c_ushort])
        geo_id, geo_type, _, size, language = kernel.GetGeoInfoW.calls[0]
        self.assertEqual((geo_id, geo_type, size, language), (166, energy.GEO_ISO2, energy.GEO_BUFFER_CHARS, 0))

    def test_windows_before_1709_without_geo_name_uses_geo_id(self):
        kernel = FakeKernel32(GetUserGeoID=lambda geo_class: 98, GetGeoInfoW=writes("GR"))
        self.assertEqual(energy.detect_country(kernel), "GR")

    def test_failed_geo_name_call_falls_back(self):
        kernel = FakeKernel32(GetUserDefaultGeoName=writes("", result=0), GetUserGeoID=lambda geo_class: 200,
                              GetGeoInfoW=writes("RO"))
        self.assertEqual(energy.detect_country(kernel), "RO")

    def test_unset_location_and_failures_give_none(self):
        cases = {
            "not available": FakeKernel32(GetUserGeoID=lambda geo_class: energy.GEOID_NOT_AVAILABLE,
                                          GetGeoInfoW=writes("RO")),
            "info fails": FakeKernel32(GetUserGeoID=lambda geo_class: 200, GetGeoInfoW=writes("", result=0)),
            "numeric everywhere": FakeKernel32(GetUserDefaultGeoName=writes("001"), GetUserGeoID=lambda c: 39070,
                                               GetGeoInfoW=writes("001")),
            "no functions": FakeKernel32(),
        }

        def raises(*args):
            raise OSError("access violation")
        cases["raises"] = FakeKernel32(GetUserDefaultGeoName=raises, GetUserGeoID=raises, GetGeoInfoW=raises)
        for label, kernel in cases.items():
            with self.subTest(label):
                self.assertIsNone(energy.detect_country(kernel))

    def test_off_windows_there_is_no_kernel32(self):
        with patch.object(energy, "_kernel32", return_value=None):
            self.assertIsNone(energy.detect_country())
            self.assertIsNone(energy.windows_currency("RO"))

    def test_windows_currency_code_for_display(self):
        import ctypes
        kernel = FakeKernel32(GetGeoInfoEx=writes("RON"))
        self.assertEqual(energy.windows_currency("ro", kernel), "RON")
        self.assertEqual(kernel.GetGeoInfoEx.calls[0][0], "RO")
        self.assertEqual(kernel.GetGeoInfoEx.calls[0][1], energy.GEO_CURRENCYCODE)
        self.assertEqual(kernel.GetGeoInfoEx.argtypes, [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_wchar_p, ctypes.c_int])
        self.assertIsNone(energy.windows_currency("RO", FakeKernel32()))
        self.assertIsNone(energy.windows_currency("RO", FakeKernel32(GetGeoInfoEx=writes("", result=0))))
        self.assertIsNone(energy.windows_currency("419", kernel))


class CountryResolverTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.store = orbit_settings.SettingsStore(Path(folder.name) / "settings.json")
        self.clock = Clock(1000)
        self.detected = "RO"
        self.resolver = energy.CountryResolver(detector=lambda: self.detected, currency_detector=lambda c: "RON",
                                               clock=self.clock)

    def test_detection_is_saved_and_rechecked_every_ten_minutes(self):
        self.assertEqual(self.resolver.country(self.store), "RO")
        self.assertEqual(self.store.get("energy")["detectedCountry"], "RO")
        self.detected = "DE"
        self.clock.now += 60
        self.assertEqual(self.resolver.country(self.store), "RO")
        self.clock.now += energy.COUNTRY_RECHECK_SECONDS
        self.assertEqual(self.resolver.country(self.store), "DE")
        self.assertEqual(self.store.get("energy")["detectedCountry"], "DE")

    def test_saved_country_is_used_when_windows_does_not_answer(self):
        self.store.update("energy", {"detectedCountry": "PL"})
        self.detected = None
        self.assertEqual(self.resolver.country(self.store), "PL")

    def test_boot_instance_prefers_the_saved_country_and_saves_nothing(self):
        self.store.update("energy", {"detectedCountry": "PL"})
        self.resolver.boot_mode = True
        self.detected = "US"  # what the default profile might report before sign-in
        self.assertEqual(self.resolver.country(self.store), "PL")
        self.resolver.reset()
        self.store.remove("energy")
        self.assertEqual(self.resolver.country(self.store), "US")
        self.assertIsNone(self.store.get("energy"))

    def test_currency_is_cached_per_country(self):
        calls = []
        resolver = energy.CountryResolver(detector=lambda: "RO", currency_detector=lambda c: calls.append(c) or "RON")
        self.assertEqual(resolver.currency("RO"), "RON")
        self.assertEqual(resolver.currency("RO"), "RON")
        self.assertEqual(calls, ["RO"])


class EurostatParsingTests(unittest.TestCase):
    def test_saved_real_response_gives_national_currency_rows_per_iso_country(self):
        rows = energy.parse_eurostat_prices(load_fixture())
        self.assertEqual(rows["RO"]["price"], 1.4573)
        self.assertEqual(rows["RO"]["currency"], "RON")
        self.assertEqual(rows["RO"]["period"], "2026-S1")
        self.assertEqual(rows["RO"]["source"], "Eurostat nrg_pc_204 (2026-S1)")
        self.assertEqual(rows["RO"]["name"], "Romania")
        self.assertEqual((rows["GR"]["price"], rows["GR"]["currency"]), (0.2584, "EUR"))  # Eurostat EL
        self.assertEqual((rows["BG"]["price"], rows["BG"]["currency"]), (0.1338, "EUR"))  # euro since 2026
        self.assertEqual((rows["LI"]["price"], rows["LI"]["currency"]), (0.2715, "CHF"))
        self.assertEqual((rows["NO"]["price"], rows["NO"]["currency"]), (1.3582, "NOK"))
        self.assertEqual(rows["XK"]["name"], "Kosovo")
        for skipped in ("EU27_2020", "EL", "UK", "GB", "UA"):
            self.assertNotIn(skipped, rows)

    def test_built_in_table_matches_the_live_response(self):
        rows = energy.parse_eurostat_prices(load_fixture())
        for code, row in rows.items():
            with self.subTest(code=code):
                built_in = energy.BUILTIN_PRICES[code]
                self.assertEqual((built_in["price"], built_in["currency"], built_in["period"]),
                                 (row["price"], row["currency"], row["period"]))

    def test_household_band_when_the_all_bands_average_is_missing(self):
        payload = load_fixture()
        sizes, ids = payload["size"], payload["id"]
        index = {name: payload["dimension"][name]["category"]["index"] for name in ids}

        def flat(**coordinate):
            number = 0
            for name, size in zip(ids, sizes):
                number = number * size + index[name][coordinate.get(name, {"freq": "S", "siec": "E7000", "unit": "KWH", "tax": "I_TAX"}.get(name))]
            return str(number)
        for currency in ("NAC", "EUR"):
            payload["value"].pop(flat(nrg_cons="TOT_KWH", currency=currency, geo="PL", time="2026-S1"), None)
        rows = energy.parse_eurostat_prices(payload)
        self.assertEqual((rows["PL"]["price"], rows["PL"]["band"], rows["PL"]["period"]), (1.2724, "DC", "2026-S1"))
        self.assertIn("2,500-4,999 kWh band", rows["PL"]["source"])
        self.assertEqual(rows["PL"]["status"], "p")

        # A country late to report keeps its newest earlier period.
        for band in ("TOT_KWH", "KWH2500-4999"):
            for currency in ("NAC", "EUR"):
                payload["value"].pop(flat(nrg_cons=band, currency=currency, geo="DE", time="2026-S1"), None)
        rows = energy.parse_eurostat_prices(payload)
        self.assertEqual((rows["DE"]["price"], rows["DE"]["period"]), (0.4042, "2025-S2"))

        # Bulgaria's 2025 values were in leva; Ireland had no average in 2025-S1 but a band value.
        payload = load_fixture()
        payload["dimension"]["time"]["category"]["index"] = {"2025-S1": 0, "2025-S2": 1, "2026-S1": 2}
        for name in ("BG", "IE"):
            for band in ("TOT_KWH", "KWH2500-4999"):
                for currency in ("NAC", "EUR"):
                    for period in ("2025-S2", "2026-S1"):
                        payload["value"].pop(flat(nrg_cons=band, currency=currency, geo=name, time=period), None)
        rows = energy.parse_eurostat_prices(payload)
        self.assertEqual((rows["BG"]["price"], rows["BG"]["currency"], rows["BG"]["period"]), (0.2533, "BGN", "2025-S1"))
        self.assertEqual((rows["IE"]["price"], rows["IE"]["band"]), (0.3231, "DC"))

    def test_a_currency_change_orbit_does_not_know_is_skipped_not_mislabelled(self):
        payload = load_fixture()
        with patch.dict(energy.EUROSTAT_NATIONAL_CURRENCIES, {"RO": "EUR", "DE": "DEM"}):
            rows = energy.parse_eurostat_prices(payload)
        self.assertNotIn("RO", rows)  # NAC 1.4573 is not the euro value 0.2834
        self.assertNotIn("DE", rows)  # NAC equals the euro value, so it is not marks any more

    def test_dense_value_lists_and_list_indexes_are_read_too(self):
        payload = load_fixture()
        total = math.prod(payload["size"])
        dense = [None] * total
        for key, value in payload["value"].items():
            dense[int(key)] = value
        payload["value"] = dense
        geo = payload["dimension"]["geo"]["category"]
        geo["index"] = sorted(geo["index"], key=geo["index"].get)
        rows = energy.parse_eurostat_prices(payload)
        self.assertEqual(rows["RO"]["price"], 1.4573)

    def test_malformed_payloads_raise(self):
        for payload in (None, [], {"id": ["geo"]}, {"id": ["geo"], "size": [1], "dimension": {"geo": {"category": {"index": {"RO": 0}}}}}):
            with self.subTest(payload=payload), self.assertRaises((ValueError, KeyError)):
                energy.parse_eurostat_prices(payload)

    def test_refresh_url_asks_for_every_country(self):
        url = energy.eurostat_url(now=utc("2026-10-24 12:00:00"))
        self.assertTrue(url.startswith("https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data/nrg_pc_204?"))
        self.assertNotIn("geo=", url)
        for part in ("tax=I_TAX", "currency=NAC", "nrg_cons=TOT_KWH", "nrg_cons=KWH2500-4999", "sinceTimePeriod=2025-S1"):
            self.assertIn(part, url)


class FakeResponse:
    def __init__(self, body, status=200):
        self.body = body
        self.status = status

    def read(self, limit=-1):
        return self.body if limit < 0 else self.body[:limit]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class PriceTableTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.path = Path(folder.name) / "energy-prices.json"
        self.clock = Clock(utc("2026-10-24 12:00:00"))

    def fetch_with(self, body, status=200):
        seen = {}

        def opener(request, timeout, context):
            seen.update(url=request.full_url, timeout=timeout, context=context)
            return FakeResponse(body, status)
        return opener, seen

    def test_download_uses_a_verified_tls_context_and_parses_the_table(self):
        opener, seen = self.fetch_with(FIXTURE.read_bytes())
        with patch.object(energy, "PRICE_TABLE_MIN_ROWS", 5):
            table = energy.fetch_eurostat_table(opener=opener, now=self.clock.now)
        self.assertEqual(seen["context"].verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(seen["context"].check_hostname)
        self.assertTrue(seen["url"].startswith("https://ec.europa.eu/"))
        self.assertEqual(table["rows"]["RO"]["price"], 1.4573)
        self.assertEqual(table["fetchedAt"], self.clock.now)
        self.assertEqual(table["datasetUpdated"], "2026-10-19T23:00:00+0200")

    def test_bad_answers_raise(self):
        cases = {"status": self.fetch_with(FIXTURE.read_bytes(), 503)[0],
                 "not json": self.fetch_with(b"<html>")[0],
                 "too large": self.fetch_with(b" " * (energy.PRICE_TABLE_MAX_BYTES + 10))[0],
                 "too few countries": self.fetch_with(FIXTURE.read_bytes())[0]}
        for label, opener in cases.items():
            with self.subTest(label), self.assertRaises(Exception), patch.object(energy, "PRICE_TABLE_MIN_ROWS", 11):
                energy.fetch_eurostat_table(opener=opener)
        with self.assertRaises(ValueError):
            energy.fetch_eurostat_table("http://ec.europa.eu/eurostat", opener=cases["status"])
        with self.assertRaises(ValueError):
            energy.fetch_eurostat_table("https://example.com/prices.json", opener=cases["status"])

    def test_redirects_are_followed_only_to_eurostat_over_https(self):
        handler = energy._EurostatRedirects()
        request = urllib.request.Request(energy.EUROSTAT_DATASET_URL)
        for target in ("http://ec.europa.eu/eurostat/api/data", "https://evil.example/ec.europa.eu/data",
                       "https://ec.europa.eu.evil.example/data", "ftp://ec.europa.eu/data"):
            with self.subTest(target=target), self.assertRaises(urllib.error.HTTPError):
                handler.redirect_request(request, io.BytesIO(), 302, "Found", email.message.Message(), target)
        allowed = handler.redirect_request(request, io.BytesIO(), 301, "Moved", email.message.Message(),
                                           "https://EC.europa.eu/eurostat/api/v2/data")
        self.assertEqual(allowed.full_url, "https://EC.europa.eu/eurostat/api/v2/data")

    def test_the_real_opener_chain_refuses_a_redirect_to_plain_http(self):
        class FakeHTTPS(urllib.request.HTTPSHandler):
            def __init__(self, routes):
                super().__init__()
                self.routes, self.seen = routes, []

            def https_open(self, req):
                self.seen.append(req.full_url)
                status, location, body = self.routes[req.full_url.split("?")[0]]
                headers = email.message.Message()
                if location:
                    headers["Location"] = location
                response = urllib.response.addinfourl(io.BytesIO(body), headers, req.full_url, status)
                response.msg = "OK" if status == 200 else "Found"
                return response

        base = energy.EUROSTAT_DATASET_URL
        moved = "https://ec.europa.eu/eurostat/api/moved"
        fake = FakeHTTPS({base: (302, moved, b""), moved: (200, None, FIXTURE.read_bytes())})
        with patch.object(energy, "_eurostat_opener", lambda context: urllib.request.build_opener(fake, energy._EurostatRedirects())), \
             patch.object(energy, "PRICE_TABLE_MIN_ROWS", 5):
            table = energy.fetch_eurostat_table(now=self.clock.now)
        self.assertEqual(table["rows"]["RO"]["price"], 1.4573)
        self.assertEqual(fake.seen[-1], moved)
        for location in ("http://ec.europa.eu/eurostat/api/moved", "https://prices.example.com/nrg_pc_204"):
            fake = FakeHTTPS({base: (302, location, b"")})
            with self.subTest(location=location), \
                 patch.object(energy, "_eurostat_opener", lambda context: urllib.request.build_opener(fake, energy._EurostatRedirects())), \
                 self.assertRaises(urllib.error.HTTPError):
                energy.fetch_eurostat_table(now=self.clock.now)
            self.assertEqual(len(fake.seen), 1)  # the other address was never opened

    def test_the_default_opener_verifies_tls_and_uses_the_strict_redirects(self):
        context = ssl.create_default_context()
        opener = energy._eurostat_opener(context)
        redirects = [handler for handler in opener.handlers if isinstance(handler, urllib.request.HTTPRedirectHandler)]
        self.assertEqual([type(handler) for handler in redirects], [energy._EurostatRedirects])
        https = [handler for handler in opener.handlers if isinstance(handler, urllib.request.HTTPSHandler)]
        self.assertEqual(len(https), 1)
        self.assertIs(https[0]._context, context)
        seen = {}

        class Opener:
            def open(self, request, timeout):
                seen.update(url=request.full_url, timeout=timeout)
                return FakeResponse(FIXTURE.read_bytes())
        with patch.object(energy, "_eurostat_opener", lambda ctx: seen.update(context=ctx) or Opener()), \
             patch.object(energy, "PRICE_TABLE_MIN_ROWS", 5):
            energy.fetch_eurostat_table(now=self.clock.now)
        self.assertEqual(seen["context"].verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(seen["context"].check_hostname)
        self.assertEqual(seen["timeout"], 20.0)

    def test_refresh_saves_atomically_and_a_new_table_loads_it(self):
        table = energy.PriceTable(self.path, clock=self.clock)
        self.assertTrue(table.needs_refresh())
        rows = {code: dict(row) for code, row in energy.BUILTIN_PRICES.items()}
        count = table.refresh(lambda: {"version": 1, "fetchedAt": self.clock.now, "rows": rows})
        self.assertEqual(count, len(rows))
        self.assertFalse(table.needs_refresh())
        self.assertEqual([p.name for p in self.path.parent.iterdir()], [self.path.name])  # no temp files left
        again = energy.PriceTable(self.path, clock=self.clock)
        self.assertEqual(again.rows()["RO"]["price"], 1.4573)
        self.clock.now += energy.PRICE_TABLE_MAX_AGE_SECONDS
        self.assertTrue(again.needs_refresh())

    def test_failed_or_thin_refresh_keeps_the_saved_table(self):
        table = energy.PriceTable(self.path, clock=self.clock)
        rows = {code: dict(row) for code, row in energy.BUILTIN_PRICES.items()}
        table.refresh(lambda: {"version": 1, "fetchedAt": self.clock.now, "rows": rows})
        before = self.path.read_bytes()
        with self.assertRaises(ValueError):
            table.refresh(lambda: {"version": 1, "fetchedAt": self.clock.now, "rows": {"RO": rows["RO"]}})
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(len(table.rows()), len(rows))

    def test_unreadable_saved_table_is_ignored(self):
        self.path.write_text("{not json", encoding="utf-8")
        table = energy.PriceTable(self.path, clock=self.clock)
        self.assertEqual(table.rows(), {})
        self.assertTrue(table.needs_refresh())
        self.path.write_text(json.dumps({"rows": {"RO": {"price": "cheap"}, "XX1": {}}, "fetchedAt": 1}), encoding="utf-8")
        self.assertEqual(energy.PriceTable(self.path).rows(), {})

    def test_refresher_is_silent_on_failure_and_reports_success(self):
        table = energy.PriceTable(self.path, clock=self.clock)
        refreshed = []

        def failing():
            raise OSError("offline")
        refresher = energy.PriceRefresher(table, fetch=failing, on_refresh=lambda: refreshed.append(True))
        with self.assertLogs("orbit.energy", level="INFO") as logs:
            self.assertFalse(refresher.check_once())
        self.assertNotIn("Traceback", "\n".join(logs.output))
        rows = {code: dict(row) for code, row in energy.BUILTIN_PRICES.items()}
        refresher.fetch = lambda: {"version": 1, "fetchedAt": self.clock.now, "rows": rows}
        self.assertTrue(refresher.check_once())
        self.assertEqual(refreshed, [True])
        self.assertFalse(refresher.check_once())  # fresh: no second download

    def test_refresher_thread_stops_promptly(self):
        refresher = energy.PriceRefresher(energy.PriceTable(self.path), fetch=MagicMock(), first_check=3600)
        refresher.start()
        refresher.stop()
        self.assertFalse(refresher.thread.is_alive())
        refresher.fetch.assert_not_called()


class PricePrecedenceTests(unittest.TestCase):
    def test_override_then_newer_table_row_then_built_in_then_nothing(self):
        downloaded = {"RO": dict(energy.BUILTIN_PRICES["RO"], price=1.5, period="2026-S2", source="Eurostat nrg_pc_204 (2026-S2)")}
        own = {"pricePerKWh": 1.07, "currency": "ron"}
        price = energy.resolve_price("RO", own, downloaded)
        self.assertEqual((price["pricePerKWh"], price["currency"], price["isOverride"], price["source"]),
                         (1.07, "RON", True, "Your own price"))
        self.assertEqual(price["defaultPrice"]["pricePerKWh"], 1.5)
        price = energy.resolve_price("RO", None, downloaded)
        self.assertEqual((price["pricePerKWh"], price["period"], price["isOverride"]), (1.5, "2026-S2", False))
        price = energy.resolve_price("RO", None, {})
        self.assertEqual(price, {"country": "RO", "pricePerKWh": 1.4573, "currency": "RON",
                                 "source": "Eurostat nrg_pc_204 (2026-S1)", "period": "2026-S1", "isOverride": False,
                                 "defaultPrice": {"pricePerKWh": 1.4573, "currency": "RON",
                                                  "source": "Eurostat nrg_pc_204 (2026-S1)", "period": "2026-S1"}})
        price = energy.resolve_price("JP", None, {}, currency_hint=lambda code: "JPY")
        self.assertEqual((price["pricePerKWh"], price["currency"], price["source"], price["defaultPrice"]),
                         (None, "JPY", None, None))
        self.assertEqual(energy.resolve_price(None, None, {})["country"], None)

    def test_an_older_download_does_not_replace_a_newer_built_in_row(self):
        downloaded = {"RO": dict(energy.BUILTIN_PRICES["RO"], price=1.4696, period="2025-S2")}
        self.assertEqual(energy.resolve_price("RO", None, downloaded)["pricePerKWh"], 1.4573)

    def test_curated_rows_outside_eurostat(self):
        self.assertEqual(energy.resolve_price("US", None, {})["pricePerKWh"], 0.1723)
        self.assertEqual(energy.resolve_price("GB", None, {})["currency"], "GBP")
        self.assertEqual(energy.resolve_price("GB", None, {})["pricePerKWh"], 0.2632)
        self.assertEqual(energy.resolve_price("CH", None, {})["pricePerKWh"], 0.277)
        self.assertEqual(energy.resolve_price("gr", None, {})["country"], "GR")

    def test_invalid_saved_override_is_ignored(self):
        for override in ({"pricePerKWh": -1, "currency": "RON"}, {"pricePerKWh": 1.0}, {"pricePerKWh": float("nan"), "currency": "RON"},
                         {"pricePerKWh": True, "currency": "RON"}, "1.07", {"pricePerKWh": 1, "currency": "lei"}):
            with self.subTest(override=override):
                self.assertFalse(energy.resolve_price("RO", override, {})["isOverride"])
        self.assertEqual(energy.resolve_price("RO", {"pricePerKWh": 0, "currency": "RON"}, {})["pricePerKWh"], 0.0)
        self.assertTrue(energy.is_currency_code("ron"))
        self.assertFalse(energy.is_currency_code("LEI"))


class ValidationTests(unittest.TestCase):
    def test_settings_ranges_and_partial_updates(self):
        self.assertEqual(energy.validate_settings_update({"baseWatts": 80}), {"baseWatts": 80.0})
        self.assertEqual(energy.validate_settings_update({"psuEfficiency": 1, "baseWatts": 0}),
                         {"psuEfficiency": 1.0, "baseWatts": 0.0})
        for payload in ({}, {"baseWatts": 501}, {"baseWatts": -1}, {"psuEfficiency": 0.49}, {"psuEfficiency": "0.9"},
                        {"baseWatts": True}, {"baseWatts": float("inf")}, [], {"other": 1}):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                energy.validate_settings_update(payload)

    def test_price_update_messages(self):
        self.assertEqual(energy.validate_price_update({"pricePerKWh": 1.07, "currency": "ron"}),
                         ("set", {"pricePerKWh": 1.07, "currency": "RON"}))
        self.assertEqual(energy.validate_price_update({"reset": True}), ("reset", None))
        for payload in ({}, {"pricePerKWh": 1.07}, {"pricePerKWh": "1,07", "currency": "RON"},
                        {"pricePerKWh": -0.1, "currency": "RON"}, {"pricePerKWh": 1e9, "currency": "RON"},
                        {"pricePerKWh": 1.07, "currency": "lei"}, {"reset": True, "pricePerKWh": 1.0},
                        {"reset": "yes"}, None):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                energy.validate_price_update(payload)

    def test_saved_settings_fall_back_to_defaults(self):
        with tempfile.TemporaryDirectory() as folder:
            store = orbit_settings.SettingsStore(Path(folder) / "settings.json")
            self.assertEqual(energy.energy_settings(store), {"baseWatts": 60.0, "psuEfficiency": 0.88})
            store.update("energy", {"baseWatts": 9999, "psuEfficiency": 0.9})
            self.assertEqual(energy.energy_settings(store), {"baseWatts": 60.0, "psuEfficiency": 0.9})


class LedgerCase(unittest.TestCase):
    """A ledger runtime with controllable clocks, price and settings."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.wall = Clock(utc("2026-10-10 12:00:00"))
        self.mono = Clock(5000)
        self.price = {"pricePerKWh": 1.5, "currency": "RON"}
        self.settings = {"baseWatts": 60.0, "psuEfficiency": 0.9}
        self.day_of = utc_day
        self.runtime = self.make_runtime()

    def make_runtime(self, extra=()):
        ledger = energy.Ledger(self.folder / "ledger.sqlite3")
        trackers = [energy.EnergyTracker(ledger)] + [factory(ledger) for factory in extra]
        runtime = energy.LedgerRuntime(ledger, trackers, price_provider=lambda: dict(self.price),
                                       settings_provider=lambda: dict(self.settings), clock=self.wall,
                                       monotonic=self.mono, day_of=lambda ts: self.day_of(ts))
        self.addCleanup(runtime.close)
        return runtime

    def tick(self, seconds=1.0, runtime=None, wall_seconds=None, **snapshot):
        self.mono.now += seconds
        self.wall.now += seconds if wall_seconds is None else wall_seconds
        (runtime or self.runtime).record({"telemetryAvailable": True, **snapshot})

    def rows(self, runtime=None):
        runtime = runtime or self.runtime
        runtime.flush()
        return {(row["day"], row["game"]): dict(row) for row in runtime.ledger.query("SELECT * FROM energy_daily")}


class LedgerMathsTests(LedgerCase):
    def test_wall_energy_and_cost_from_components_base_and_efficiency(self):
        self.tick(0, cpuPowerWatts=100, gpuPowerWatts=200)  # first tick: no interval yet
        for _ in range(3600):
            self.tick(1, cpuPowerWatts=100, gpuPowerWatts=200)
        row = self.rows()[("2026-10-10", "")]
        self.assertAlmostEqual(row["seconds"], 3600)
        self.assertAlmostEqual(row["measured_seconds"], 3600)
        self.assertAlmostEqual(row["cpu_wh"], 100)
        self.assertAlmostEqual(row["gpu_wh"], 200)
        self.assertAlmostEqual(row["base_wh"], 60)
        self.assertAlmostEqual(row["wall_wh"], 400)  # (100 + 200 + 60) / 0.9
        self.assertAlmostEqual(row["cost"], 0.6)  # 0.4 kWh × 1.5
        self.assertEqual(row["currency"], "RON")

    def test_long_gaps_count_at_most_five_seconds(self):
        self.tick(0, cpuPowerWatts=90, gpuPowerWatts=0)
        self.tick(1, cpuPowerWatts=90, gpuPowerWatts=0)
        self.tick(3600, cpuPowerWatts=90, gpuPowerWatts=0)  # asleep for an hour
        self.tick(6, cpuPowerWatts=90, gpuPowerWatts=0)  # a slow tick
        self.mono.now -= 10  # a monotonic clock never goes back; if it seemed to, count nothing
        self.tick(0, cpuPowerWatts=90, gpuPowerWatts=0)
        row = self.rows()[("2026-10-10", "")]
        self.assertAlmostEqual(row["seconds"], 1 + 5 + 5)

    def test_stale_sensors_count_base_load_only_and_leave_coverage(self):
        self.tick(0)
        for _ in range(60):
            self.tick(1, cpuPowerWatts=None, gpuPowerWatts=None)
        for _ in range(60):
            self.tick(1, cpuPowerWatts=float("nan"), gpuPowerWatts=150)
        for _ in range(60):
            self.tick(1, cpuPowerWatts=-5, gpuPowerWatts=99999, telemetryAvailable=True)
        row = self.rows()[("2026-10-10", "")]
        self.assertAlmostEqual(row["seconds"], 180)
        self.assertAlmostEqual(row["measured_seconds"], 60)
        self.assertAlmostEqual(row["cpu_wh"], 0)
        self.assertAlmostEqual(row["gpu_wh"], 150 / 60)
        self.assertAlmostEqual(row["wall_wh"], (60 * 3 + 150) / 60 / 0.9)

    def test_unavailable_telemetry_keeps_the_last_game_and_base_load(self):
        self.tick(0, activeGameProcess="eldenring.exe", cpuPowerWatts=100, gpuPowerWatts=200)
        self.tick(1, activeGameProcess="eldenring.exe", cpuPowerWatts=100, gpuPowerWatts=200)
        self.tick(1, telemetryAvailable=False, cpuPowerWatts=500)
        row = self.rows()[("2026-10-10", "eldenring")]
        self.assertAlmostEqual(row["seconds"], 2)
        self.assertAlmostEqual(row["measured_seconds"], 1)
        self.assertAlmostEqual(row["wall_wh"], (360 + 60) / 3600 / 0.9)

    def test_games_get_their_own_rows(self):
        self.tick(0)
        self.tick(10, cpuPowerWatts=50, gpuPowerWatts=10)
        self.tick(1, activeGameProcess="C:\\Games\\Cyberpunk2077.exe", cpuPowerWatts=120, gpuPowerWatts=300)
        self.tick(2, activeGameProcess="Cyberpunk2077.exe", cpuPowerWatts=120, gpuPowerWatts=300)
        rows = self.rows()
        self.assertAlmostEqual(rows[("2026-10-10", "")]["seconds"], 5)
        self.assertAlmostEqual(rows[("2026-10-10", "cyberpunk2077")]["seconds"], 3)

    def test_price_change_mid_day_prices_each_part_at_its_own_price(self):
        self.tick(0, cpuPowerWatts=300, gpuPowerWatts=0)
        for _ in range(1800):
            self.tick(1, cpuPowerWatts=300, gpuPowerWatts=0)  # 0.2 kWh at 1.5
        self.price = {"pricePerKWh": 1.0, "currency": "RON"}
        self.runtime.invalidate()  # what PUT /api/energy/price does
        for _ in range(1800):
            self.tick(1, cpuPowerWatts=300, gpuPowerWatts=0)  # 0.2 kWh at 1.0
        row = self.rows()[("2026-10-10", "")]
        self.assertAlmostEqual(row["wall_wh"], 400)  # (300 + 60) / 0.9 W for one hour
        self.assertAlmostEqual(row["cost"], 0.2 * 1.5 + 0.2 * 1.0)

    def test_cached_price_is_refreshed_after_thirty_seconds(self):
        self.tick(0, cpuPowerWatts=300, gpuPowerWatts=0)
        self.price = {"pricePerKWh": 3.0, "currency": "RON"}
        for _ in range(60):
            self.tick(1, cpuPowerWatts=300, gpuPowerWatts=0)
        row = self.rows()[("2026-10-10", "")]
        wh_per_second = 360 / 0.9 / 3600
        # The price read with the first tick is kept for 30 s: ticks 1-29 at 1.5, ticks 30-60 at 3.0.
        expected = wh_per_second / 1000 * (29 * 1.5 + 31 * 3.0)
        self.assertAlmostEqual(row["cost"], expected)

    def test_currency_change_restates_the_row_in_the_new_currency(self):
        self.tick(0, cpuPowerWatts=300, gpuPowerWatts=0)
        for _ in range(100):
            self.tick(1, cpuPowerWatts=300, gpuPowerWatts=0)
        self.runtime.flush()
        self.price = {"pricePerKWh": 0.3, "currency": "EUR"}
        self.runtime.invalidate()
        for _ in range(100):
            self.tick(1, cpuPowerWatts=300, gpuPowerWatts=0)
        row = self.rows()[("2026-10-10", "")]
        self.assertEqual(row["currency"], "EUR")
        self.assertAlmostEqual(row["cost"], row["wall_wh"] / 1000 * 0.3)

    def test_time_without_a_price_is_costed_once_a_price_exists(self):
        self.price = {"pricePerKWh": None, "currency": None}
        self.tick(0, cpuPowerWatts=300, gpuPowerWatts=0)
        for _ in range(10):
            self.tick(1, cpuPowerWatts=300, gpuPowerWatts=0)
        row = self.rows()[("2026-10-10", "")]
        self.assertIsNone(row["cost"])
        self.assertIsNone(row["currency"])
        self.price = {"pricePerKWh": 2.0, "currency": "PLN"}
        self.runtime.invalidate()
        self.tick(1, cpuPowerWatts=300, gpuPowerWatts=0)
        row = self.rows()[("2026-10-10", "")]
        self.assertEqual(row["currency"], "PLN")
        self.assertAlmostEqual(row["cost"], row["wall_wh"] / 1000 * 2.0)

    def test_midnight_splits_ticks_between_days(self):
        self.wall.now = utc("2026-10-10 23:59:57")
        self.tick(0, cpuPowerWatts=100, gpuPowerWatts=0)
        for _ in range(6):
            self.tick(1, cpuPowerWatts=100, gpuPowerWatts=0)
        rows = self.rows()
        self.assertAlmostEqual(rows[("2026-10-10", "")]["seconds"], 2)  # :58, :59
        self.assertAlmostEqual(rows[("2026-10-11", "")]["seconds"], 4)  # 00:00 .. 00:03

    def test_daylight_saving_change_uses_local_days_and_real_durations(self):
        # Bucharest: EEST (UTC+3) until 2026-10-25 01:00 UTC, then EET (UTC+2); local 04:00 becomes 03:00.
        switch = utc("2026-10-25 01:00:00")
        self.day_of = lambda ts: time.strftime("%Y-%m-%d", time.gmtime(ts + (3 if ts < switch else 2) * 3600))
        self.wall.now = utc("2026-10-24 20:00:00")  # 23:00 local
        self.tick(0, cpuPowerWatts=100, gpuPowerWatts=0)
        for _ in range(4 * 3600):  # until 00:00 UTC = 03:00 EEST, all on the 25th after 21:00 UTC
            self.tick(1, cpuPowerWatts=100, gpuPowerWatts=0)
        for _ in range(2 * 3600):  # through the switch: the wall clock repeats an hour, durations do not
            self.tick(1, cpuPowerWatts=100, gpuPowerWatts=0)
        rows = self.rows()
        # A tick belongs to the day it ends in: 23:00:01-23:59:59 local on the 24th, the rest on the 25th.
        self.assertAlmostEqual(rows[("2026-10-24", "")]["seconds"], 3599)
        self.assertAlmostEqual(rows[("2026-10-25", "")]["seconds"], 6 * 3600 - 3599)

    @unittest.skipUnless(hasattr(time, "tzset"), "time.tzset is not available on Windows")
    def test_local_day_follows_the_system_time_zone_across_dst(self):
        previous = os.environ.get("TZ")
        os.environ["TZ"] = "Europe/Bucharest"
        time.tzset()
        try:
            self.assertEqual(energy.local_day(utc("2026-10-24 21:30:00")), "2026-10-25")  # 00:30 EEST
            self.assertEqual(energy.local_day(utc("2026-10-25 21:30:00")), "2026-10-25")  # 23:30 EET
            self.assertEqual(energy.local_day(utc("2026-10-25 22:00:00")), "2026-10-26")
        finally:
            if previous is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = previous
            time.tzset()

    def test_flush_every_minute_and_at_close_then_a_restart_continues_the_rows(self):
        path = self.folder / "ledger.sqlite3"
        self.tick(0, cpuPowerWatts=100, gpuPowerWatts=0)
        for _ in range(59):
            self.tick(1, cpuPowerWatts=100, gpuPowerWatts=0)
        reader = sqlite3.connect(path)
        self.addCleanup(reader.close)
        self.assertEqual(reader.execute("SELECT COUNT(*) FROM energy_daily").fetchone()[0], 0)
        self.tick(1, cpuPowerWatts=100, gpuPowerWatts=0)  # 60 s after the first tick
        self.assertAlmostEqual(reader.execute("SELECT seconds FROM energy_daily").fetchone()[0], 60)
        for _ in range(10):
            self.tick(1, cpuPowerWatts=100, gpuPowerWatts=0)
        self.runtime.close()  # shutdown writes the last 10 s
        self.assertAlmostEqual(reader.execute("SELECT seconds FROM energy_daily").fetchone()[0], 70)
        self.runtime.record({"telemetryAvailable": True, "cpuPowerWatts": 100})  # ignored after close

        restarted = self.make_runtime()
        self.tick(30, runtime=restarted, cpuPowerWatts=100, gpuPowerWatts=0)  # first tick after a restart: 0 s
        self.tick(1, runtime=restarted, cpuPowerWatts=100, gpuPowerWatts=0)
        self.assertAlmostEqual(self.rows(restarted)[("2026-10-10", "")]["seconds"], 71)

    def test_failed_flush_keeps_the_totals_for_the_next_try(self):
        self.tick(0, cpuPowerWatts=100, gpuPowerWatts=0)
        self.tick(1, cpuPowerWatts=100, gpuPowerWatts=0)
        original = self.runtime.ledger.transaction

        def locked():
            raise sqlite3.OperationalError("database is locked")
        with patch.object(self.runtime.ledger, "transaction", side_effect=locked), self.assertLogs("orbit.energy", "ERROR"):
            self.assertFalse(self.runtime.flush())
        self.assertIs(self.runtime.ledger.transaction.__func__, original.__func__)
        self.assertTrue(self.runtime.flush())
        self.assertAlmostEqual(self.rows()[("2026-10-10", "")]["seconds"], 1)

    def test_a_failed_commit_rolls_back_and_the_next_transaction_works(self):
        ledger = self.runtime.ledger
        real = ledger.db

        class FailingCommit:
            def execute(self, sql, *args):
                if sql == "COMMIT":
                    raise sqlite3.OperationalError("disk I/O error")
                return real.execute(sql, *args)
        ledger.db = FailingCommit()
        try:
            with self.assertRaises(sqlite3.OperationalError):
                with ledger.transaction() as db:
                    db.execute("INSERT INTO meta (key, value) VALUES ('probe', 'lost')")
        finally:
            ledger.db = real
        self.assertIsNone(ledger.meta("probe"))
        ledger.set_meta("probe", "kept")
        self.assertEqual(ledger.meta("probe"), "kept")

    def test_a_tracker_error_during_flush_keeps_everything_for_later(self):
        self.tick(0, cpuPowerWatts=100, gpuPowerWatts=0)
        self.tick(1, cpuPowerWatts=100, gpuPowerWatts=0)
        tracker = self.runtime.trackers[0]
        with patch.object(tracker, "flush", side_effect=ValueError("bad row")), self.assertLogs("orbit.energy", "ERROR"):
            self.assertFalse(self.runtime.flush())
        self.assertEqual(self.runtime.ledger.query("SELECT * FROM energy_daily"), [])
        self.assertAlmostEqual(self.rows()[("2026-10-10", "")]["seconds"], 1)

    def test_rows_older_than_400_days_are_pruned(self):
        ledger = self.runtime.ledger
        with ledger.transaction() as db:
            for day in ("2025-09-01", "2025-09-15", "2026-10-01"):
                db.execute("INSERT INTO energy_daily (day, game, seconds) VALUES (?, '', 10)", (day,))
                db.execute("INSERT INTO game_daily (day, game, play_seconds) VALUES (?, 'x', 10)", (day,))
            db.execute("INSERT INTO game_spans (game, started_at, ended_at) VALUES ('x', ?, ?)", (utc("2025-09-01 10:00:00"), utc("2025-09-01 11:00:00")))
        ledger.prune(utc("2026-10-10 12:00:00"))
        self.assertEqual([row["day"] for row in ledger.query("SELECT day FROM energy_daily ORDER BY day")], ["2025-09-15", "2026-10-01"])
        self.assertEqual(len(ledger.query("SELECT * FROM game_daily")), 2)
        self.assertEqual(ledger.query("SELECT * FROM game_spans"), [])
        self.assertEqual(ledger.available_months(), ["2025-09", "2026-10"])

    def test_wal_mode_and_damaged_file_is_set_aside(self):
        self.assertEqual(self.runtime.ledger.query("PRAGMA journal_mode")[0][0], "wal")
        damaged = self.folder / "broken.sqlite3"
        damaged.write_bytes(b"this is not a database" * 100)
        with self.assertLogs("orbit.energy", "WARNING"):
            ledger = energy.Ledger(damaged)
        self.addCleanup(ledger.close)
        self.assertTrue((self.folder / "broken.sqlite3.corrupt").exists())
        self.assertEqual(ledger.query("SELECT COUNT(*) AS n FROM energy_daily")[0]["n"], 0)


class EnergyReportTests(LedgerCase):
    def insert(self, day, game="", wall_wh=0.0, seconds=3600.0, measured=None, cost=None, currency=None, cpu=0.0, gpu=0.0, base=0.0):
        with self.runtime.ledger.transaction() as db:
            db.execute("""INSERT INTO energy_daily (day, game, cpu_wh, gpu_wh, base_wh, wall_wh, seconds, measured_seconds, cost, currency)
                          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                       (day, game, cpu, gpu, base, wall_wh, seconds, seconds if measured is None else measured, cost, currency))

    def test_month_report_days_games_today_and_costs(self):
        self.insert("2026-10-01", wall_wh=400, cost=0.6, currency="RON", cpu=100, gpu=200, base=60)
        self.insert("2026-10-01", "eldenring", wall_wh=1000, seconds=7200, measured=3600, cost=1.5, currency="RON")
        self.insert("2026-10-03", wall_wh=200, cost=0.06, currency="EUR")  # restated at today's RON price
        self.insert("2026-10-10", "eldenring", wall_wh=100, cost=0.15, currency="RON")
        self.insert("2026-09-30", wall_wh=999, cost=9, currency="RON")
        with self.runtime.ledger.transaction() as db:
            db.execute("INSERT INTO game_daily (day, game, display_name, play_seconds) VALUES ('2026-10-01', 'eldenring', 'ELDEN RING', 7200)")
        price = {"pricePerKWh": 1.5, "currency": "RON", "country": "RO"}
        report = energy.energy_month(self.runtime.ledger, 2026, 10, price, today="2026-10-10")
        self.assertEqual(report["month"], "2026-10")
        self.assertEqual(report["kWh"], 1.7)
        self.assertEqual(report["cost"], round(0.6 + 1.5 + 0.2 * 1.5 + 0.15, 2))
        self.assertEqual(report["currency"], "RON")
        self.assertTrue(report["isEstimate"])
        self.assertEqual(report["coverage"], round((3600 + 3600 + 3600 + 3600) / (3600 + 7200 + 3600 + 3600), 3))
        self.assertEqual(len(report["days"]), 10)  # Oct 1 .. today, zero days included
        self.assertEqual(report["days"][0], {"day": "2026-10-01", "kWh": 1.4, "cost": 2.1})
        self.assertEqual(report["days"][1], {"day": "2026-10-02", "kWh": 0.0, "cost": 0.0})
        self.assertEqual(report["games"], [{"game": "eldenring", "name": "ELDEN RING", "kWh": 1.1, "cost": 1.65, "hours": 3.0}])
        self.assertEqual(report["today"], {"kWh": 0.1, "cost": 0.15})
        self.assertEqual(report["price"], price)
        self.assertEqual(report["breakdown"]["cpuKWh"], 0.1)
        self.assertEqual(report["available"], ["2026-09", "2026-10"])

    def test_past_and_future_months_and_no_price(self):
        self.insert("2026-09-02", wall_wh=500, cost=0.5, currency="EUR")
        past = energy.energy_month(self.runtime.ledger, 2026, 9, {"pricePerKWh": None, "currency": None}, today="2026-10-10")
        self.assertEqual(len(past["days"]), 30)
        self.assertEqual((past["cost"], past["currency"]), (0.5, "EUR"))  # the ledger's own currency
        future = energy.energy_month(self.runtime.ledger, 2026, 12, {"pricePerKWh": 1.0, "currency": "EUR"}, today="2026-10-10")
        self.assertEqual((future["days"], future["kWh"], future["coverage"]), ([], 0.0, None))
        empty = energy.energy_month(self.runtime.ledger, 2026, 11, {"pricePerKWh": None, "currency": None}, today="2026-11-02")
        self.assertEqual((empty["cost"], empty["currency"], empty["today"]["cost"]), (None, None, None))
        self.assertEqual(empty["days"], [{"day": "2026-11-01", "kWh": 0.0, "cost": None}, {"day": "2026-11-02", "kWh": 0.0, "cost": None}])

    def test_unknown_game_names_are_tidied(self):
        self.insert("2026-10-02", "cyberpunk2077", wall_wh=10, cost=0.01, currency="RON")
        report = energy.energy_month(self.runtime.ledger, 2026, 10, {"pricePerKWh": 1.0, "currency": "RON"}, today="2026-10-02")
        self.assertEqual(report["games"][0]["name"], "Cyberpunk 2077")

    def test_prettify_game_names(self):
        cases = {"cyberpunk2077": "Cyberpunk 2077", "cs2": "CS2", "eldenring": "Eldenring", "bg3": "BG3",
                 "FortniteClient-Win64-Shipping": "Fortnite Client", "witcher3": "Witcher 3", "TslGame": "Tsl Game",
                 "re4": "RE4", "Hades": "Hades", "rdr2_x64": "RDR2", "": "Game", "C:\\Games\\HogwartsLegacy.exe": "Hogwarts Legacy"}
        for stem, name in cases.items():
            with self.subTest(stem=stem):
                self.assertEqual(energy.prettify_game_name(stem), name)


class SessionEnergyTests(LedgerCase):
    def samples(self, entries):
        start = utc("2026-10-10 20:00:00")
        return [{"timestamp": start + offset, "segment": segment, "telemetryAvailable": available,
                 "cpuPowerWatts": cpu, "gpuPowerWatts": gpu} for offset, segment, cpu, gpu, available in entries]

    def test_samples_within_segments_plus_base_load(self):
        samples = self.samples([(0, 0, 100, 200, True), (5, 0, 100, 200, True), (10, 0, None, None, True),
                                (40, 0, 100, 200, True),  # 30 s later: counted as 15 s
                                (100, 1, 100, 200, True), (105, 1, 900, 900, False), (110, 1, 0, 0, True)])
        result = energy.session_energy(samples, {"baseWatts": 60, "psuEfficiency": 0.9},
                                       {"pricePerKWh": 2.0, "currency": "RON"}, day_of=utc_day)
        # 0-5, 5-10 and 100-105 measured (360 W); 10-40 capped at 15 s and 105-110 unavailable: base only.
        wall_wh = (360 * 5 * 3 + 60 * 15 + 60 * 5) / 0.9 / 3600
        self.assertAlmostEqual(result["kWh"], round(wall_wh / 1000, 4))
        self.assertEqual(result["cost"], round(wall_wh / 1000 * 2.0, 2))
        self.assertEqual(result["currency"], "RON")
        self.assertEqual(result["coverage"], round(15 / 35, 3))

    def test_day_prices_from_the_ledger_and_no_price(self):
        samples = self.samples([(0, 0, 1000, 800, True), (3600 * 0 + 10, 0, 1000, 800, True)])
        with_ledger = energy.session_energy(samples, {"baseWatts": 0, "psuEfficiency": 1.0},
                                            {"pricePerKWh": 1.0, "currency": "RON"}, day_of=utc_day,
                                            unit_prices={"2026-10-10": 3.0})
        self.assertEqual(with_ledger["cost"], round(1800 * 10 / 3600 / 1000 * 3.0, 2))
        none = energy.session_energy(samples, {"baseWatts": 0, "psuEfficiency": 1.0}, {"pricePerKWh": None, "currency": None})
        self.assertEqual((none["cost"], none["currency"]), (None, None))
        self.assertEqual(energy.session_energy([], {"baseWatts": 60, "psuEfficiency": 0.9}, {})["coverage"], None)

    def test_ledger_day_prices_average_the_costs_in_one_currency(self):
        with self.runtime.ledger.transaction() as db:
            db.execute("INSERT INTO energy_daily (day, game, wall_wh, cost, currency) VALUES ('2026-10-10', '', 1000, 1.5, 'RON')")
            db.execute("INSERT INTO energy_daily (day, game, wall_wh, cost, currency) VALUES ('2026-10-10', 'x', 1000, 2.5, 'RON')")
            db.execute("INSERT INTO energy_daily (day, game, wall_wh, cost, currency) VALUES ('2026-10-11', '', 1000, 0.3, 'EUR')")
        self.assertEqual(energy.day_unit_prices(self.runtime.ledger, ["2026-10-10", "2026-10-11"], "RON"), {"2026-10-10": 2.0})

    def test_history_detail_gains_an_energy_object(self):
        from fastapi import FastAPI
        clock = Clock(utc("2026-10-10 20:00:00"))
        recorder = orbit_history.SessionRecorder(self.folder / "history.sqlite3", clock=clock)
        self.addCleanup(recorder.close)
        session = recorder.start("Work")
        for _ in range(4):
            clock.now += 5
            recorder.record_sample({"telemetryAvailable": True, "cpuPowerWatts": 100, "gpuPowerWatts": 200})
        recorder.stop()
        app = FastAPI()
        app.include_router(orbit_history.create_history_router(lambda authorization=None: None, lambda: recorder,
                                                               detail_extras=energy.session_energy_extras))
        client = TestClient(app, base_url="https://testserver")
        self.addCleanup(client.close)
        store = orbit_settings.SettingsStore(self.folder / "settings.json")
        store.update("energy", {"baseWatts": 60, "psuEfficiency": 0.9, "override": {"pricePerKWh": 2.0, "currency": "RON"}})
        orbit_settings.set_shared_store(store)
        self.addCleanup(orbit_settings.set_shared_store, None)
        for name, value in (("PRICE_TABLE", energy.PriceTable(self.folder / "energy-prices.json")),
                            ("COUNTRY", energy.CountryResolver(detector=lambda: "RO", currency_detector=lambda c: None))):
            patcher = patch.object(energy, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        with patch.object(energy, "current_runtime", return_value=None):
            body = client.get(f"/api/history/sessions/{session['id']}").json()
        self.assertEqual(body["energy"]["currency"], "RON")
        self.assertAlmostEqual(body["energy"]["kWh"], round(400 * 15 / 3600 / 1000, 4))
        self.assertEqual(body["energy"]["coverage"], 1.0)
        self.assertIn("samples", body)
        # A failing estimate never breaks the session detail.
        with patch.object(energy, "current_price", side_effect=RuntimeError("boom")), self.assertLogs("orbit.history", "ERROR"):
            body = client.get(f"/api/history/sessions/{session['id']}").json()
        self.assertNotIn("energy", body)
        self.assertEqual(client.get("/api/history/sessions/missing").status_code, 404)


class RuntimeLifecycleTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.store = orbit_settings.SettingsStore(self.folder / "settings.json")
        orbit_settings.set_shared_store(self.store)
        self.addCleanup(orbit_settings.set_shared_store, None)
        for name, value in (("PRICE_TABLE", energy.PriceTable(self.folder / "energy-prices.json")),
                            ("COUNTRY", energy.CountryResolver(detector=lambda: "RO", currency_detector=lambda c: None))):
            patcher = patch.object(energy, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.addCleanup(energy.stop)

    def test_start_record_stop_without_network(self):
        with patch.object(energy, "PriceRefresher") as refresher:
            runtime = energy.start(path=self.folder / "ledger.sqlite3", refresh=False)
        refresher.assert_not_called()
        self.assertIs(energy.current_runtime(), runtime)
        energy.record_tick({"telemetryAvailable": True, "cpuPowerWatts": 100})
        energy.record_tick("not a snapshot")
        energy.stop()
        self.assertIsNone(energy.current_runtime())
        energy.record_tick({"telemetryAvailable": True})  # no runtime: nothing happens

    def test_refresher_starts_unless_turned_off(self):
        with patch.object(energy, "PriceRefresher") as refresher:
            energy.start(path=self.folder / "ledger.sqlite3")
            refresher.return_value.start.assert_called_once()
            energy.stop()
            refresher.return_value.stop.assert_called_once()
            refresher.reset_mock()
            with patch.dict(os.environ, {"ORBIT_ENERGY_PRICE_REFRESH": "0"}):
                energy.start(path=self.folder / "ledger.sqlite3")
            refresher.assert_not_called()

    def test_a_ledger_that_cannot_open_pauses_tracking_but_never_raises(self):
        with patch.object(energy, "Ledger", side_effect=sqlite3.OperationalError("disk I/O error")), \
             patch.object(energy, "LEDGER_RETRY_SECONDS", 3600), self.assertLogs("orbit.energy", "ERROR"):
            self.assertIsNone(energy.start(path=self.folder / "ledger.sqlite3", refresh=False))
        energy.record_tick({"telemetryAvailable": True})
        self.assertIsNotNone(energy._RETRY)
        energy.stop()
        self.assertIsNone(energy._RETRY)

    def test_a_ledger_that_fails_at_start_is_opened_again_later(self):
        real, attempts = energy.Ledger, []

        def flaky(path=None):
            attempts.append(path)
            if len(attempts) <= 2:
                raise sqlite3.OperationalError("unable to open database file")
            return real(path)
        path = self.folder / "ledger.sqlite3"
        with patch.object(energy, "Ledger", side_effect=flaky), patch.object(energy, "LEDGER_RETRY_SECONDS", 3600):
            with self.assertLogs("orbit.energy", "ERROR"):
                self.assertIsNone(energy.start(path=path, refresh=False))
            retry = energy._RETRY
            with self.assertLogs("orbit.energy", "WARNING"):
                self.assertFalse(retry.attempt())  # still locked
            self.assertIsNone(energy.current_runtime())
            with self.assertLogs("orbit.energy", "INFO") as logs:
                self.assertTrue(retry.attempt())
        self.assertIn("open again", "\n".join(logs.output))
        runtime = energy.current_runtime()
        self.assertIsNotNone(runtime)
        self.assertIsNone(energy._RETRY)
        self.assertEqual(attempts, [path, path, path])
        energy.record_tick({"telemetryAvailable": True, "cpuPowerWatts": 100})
        energy.record_tick({"telemetryAvailable": True, "cpuPowerWatts": 100})
        energy.stop()
        self.assertTrue(runtime.ledger.closed)
        with contextlib.closing(sqlite3.connect(path)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM energy_daily").fetchone()[0], 1)

    def test_the_retry_thread_opens_the_ledger_by_itself(self):
        real, attempts = energy.Ledger, []

        def flaky(path=None):
            attempts.append(path)
            if len(attempts) == 1:
                raise sqlite3.OperationalError("database is locked")
            return real(path)
        with patch.object(energy, "Ledger", side_effect=flaky), patch.object(energy, "LEDGER_RETRY_SECONDS", 0.01), \
             self.assertLogs("orbit.energy", "INFO"):
            energy.start(path=self.folder / "ledger.sqlite3", refresh=False)
            deadline = time.monotonic() + 5
            while energy.current_runtime() is None and time.monotonic() < deadline:
                time.sleep(0.01)
        self.assertIsNotNone(energy.current_runtime())

    def test_stop_while_retrying_leaves_nothing_open(self):
        with patch.object(energy, "Ledger", side_effect=sqlite3.OperationalError("locked")), \
             patch.object(energy, "LEDGER_RETRY_SECONDS", 3600), self.assertLogs("orbit.energy", "ERROR"):
            energy.start(path=self.folder / "ledger.sqlite3", refresh=False)
        retry = energy._RETRY
        energy.stop()
        self.assertFalse(retry.thread.is_alive())
        with patch.object(energy, "Ledger") as ledger:
            self.assertTrue(retry.attempt())  # stopped: does not even try
        ledger.assert_not_called()
        # A try that finishes after stop() closes what it opened.
        retry = energy.LedgerRetry(path=self.folder / "ledger.sqlite3", interval=3600)
        self.assertTrue(retry.attempt())
        self.assertIsNone(energy.current_runtime())

    def test_a_tracker_that_fails_to_build_closes_the_ledger(self):
        opened = []
        real = energy.Ledger

        def spy(path=None):
            opened.append(real(path))
            return opened[-1]

        def broken(ledger):
            raise RuntimeError("tracker failed")
        with patch.object(energy, "Ledger", side_effect=spy), patch.object(energy, "LEDGER_RETRY_SECONDS", 3600), \
             self.assertLogs("orbit.energy", "ERROR"):
            self.assertIsNone(energy.start(extra_trackers=(broken,), path=self.folder / "ledger.sqlite3", refresh=False))
        self.assertTrue(opened[0].closed)

    def test_boot_mode_reaches_the_country_resolver(self):
        energy.start(path=self.folder / "ledger.sqlite3", refresh=False, boot_mode=True)
        self.assertTrue(energy.COUNTRY.boot_mode)

    def test_agent_telemetry_hook_feeds_the_ledger(self):
        import orbit_agent as agent
        with patch.object(agent.orbit_energy, "record_tick") as hook, patch.object(agent, "HISTORY_RECORDER", None):
            agent.record_history({"telemetryAvailable": True, "cpuPowerWatts": 80})
        hook.assert_called_once_with({"telemetryAvailable": True, "cpuPowerWatts": 80})


class EnergyRouteTests(unittest.TestCase):
    def setUp(self):
        import orbit_agent as agent
        self.agent = agent
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.store = orbit_settings.SettingsStore(self.folder / "settings.json")
        orbit_settings.set_shared_store(self.store)
        self.addCleanup(orbit_settings.set_shared_store, None)
        self.country = "RO"
        for target, name, value in ((energy, "PRICE_TABLE", energy.PriceTable(self.folder / "energy-prices.json")),
                                    (energy, "COUNTRY", energy.CountryResolver(detector=lambda: self.country,
                                                                               currency_detector=lambda c: "JPY")),
                                    (agent, "API_TOKEN", TOKEN)):
            patcher = patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.client = TestClient(agent.app, base_url="https://testserver")
        self.addCleanup(self.client.close)
        self.headers = {"Authorization": f"Bearer {TOKEN}"}

    def test_price_get_put_and_reset(self):
        body = self.client.get("/api/energy/price", headers=self.headers).json()
        self.assertEqual((body["country"], body["pricePerKWh"], body["currency"], body["isOverride"]), ("RO", 1.4573, "RON", False))
        response = self.client.put("/api/energy/price", headers=self.headers, json={"pricePerKWh": 1.07, "currency": "RON"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual((response.json()["pricePerKWh"], response.json()["isOverride"]), (1.07, True))
        self.assertEqual(self.store.get("energy")["override"]["currency"], "RON")
        self.assertIn("setAt", self.store.get("energy")["override"])
        self.assertTrue(self.client.get("/api/energy/price", headers=self.headers).json()["isOverride"])
        response = self.client.put("/api/energy/price", headers=self.headers, json={"reset": True})
        self.assertEqual((response.json()["pricePerKWh"], response.json()["isOverride"]), (1.4573, False))
        self.assertNotIn("override", self.store.get("energy"))
        self.assertEqual(self.store.get("energy")["detectedCountry"], "RO")

    def test_price_errors_are_sentences_and_change_nothing(self):
        for payload in ({"pricePerKWh": "cheap", "currency": "RON"}, {"pricePerKWh": 1.0}, {"reset": True, "pricePerKWh": 1}):
            with self.subTest(payload=payload):
                response = self.client.put("/api/energy/price", headers=self.headers, json=payload)
                self.assertEqual(response.status_code, 422)
                self.assertIsInstance(response.json()["detail"], str)
        self.assertIsNone(self.store.get("energy", {}).get("override"))

    def test_saving_failure_is_503(self):
        with patch.object(self.store, "modify", side_effect=OSError("disk full")):
            response = self.client.put("/api/energy/price", headers=self.headers, json={"pricePerKWh": 1.0, "currency": "EUR"})
        self.assertEqual(response.status_code, 503)

    def test_country_without_a_price_suggests_the_windows_currency(self):
        self.country = "JP"
        body = self.client.get("/api/energy/price", headers=self.headers).json()
        self.assertEqual((body["country"], body["pricePerKWh"], body["currency"], body["source"]), ("JP", None, "JPY", None))

    def test_settings_get_and_put(self):
        self.assertEqual(self.client.get("/api/energy/settings", headers=self.headers).json(),
                         {"baseWatts": 60.0, "psuEfficiency": 0.88})
        response = self.client.put("/api/energy/settings", headers=self.headers, json={"baseWatts": 75})
        self.assertEqual(response.json(), {"baseWatts": 75.0, "psuEfficiency": 0.88})
        response = self.client.put("/api/energy/settings", headers=self.headers, json={"psuEfficiency": 2})
        self.assertEqual(response.status_code, 422)
        self.assertIn("0.5 to 1", response.json()["detail"])
        self.assertEqual(self.store.get("energy")["baseWatts"], 75.0)

    def test_summary_needs_the_ledger_and_a_valid_month(self):
        with patch.object(energy, "current_runtime", return_value=None):
            self.assertEqual(self.client.get("/api/energy/summary", headers=self.headers).status_code, 503)
        runtime = energy.start(path=self.folder / "ledger.sqlite3", refresh=False)
        self.addCleanup(energy.stop)
        for month in ("2026-13", "26-10", "2026-1", "x"):
            with self.subTest(month=month):
                self.assertEqual(self.client.get("/api/energy/summary", params={"month": month}, headers=self.headers).status_code, 422)
        runtime.record({"telemetryAvailable": True, "cpuPowerWatts": 100})
        body = self.client.get("/api/energy/summary", headers=self.headers).json()
        self.assertEqual(body["month"], runtime.today()[:7])
        self.assertEqual(body["currency"], "RON")
        self.assertEqual(body["price"]["pricePerKWh"], 1.4573)

    def test_plain_http_is_refused(self):
        client = TestClient(self.agent.app)
        self.addCleanup(client.close)
        self.assertEqual(client.get("/api/energy/price", headers=self.headers).status_code, 426)


class TrayTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.store = orbit_settings.SettingsStore(Path(folder.name) / "settings.json")
        self.country = "RO"
        for name, value in (("PRICE_TABLE", energy.PriceTable(Path(folder.name) / "energy-prices.json")),
                            ("COUNTRY", energy.CountryResolver(detector=lambda: self.country, currency_detector=lambda c: None))):
            patcher = patch.object(energy, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_message_shows_country_price_source_and_how_to_change_it(self):
        title, text = energy.tray_price_message(self.store)
        self.assertEqual(title, "Orbit · Electricity price")
        self.assertIn("Country: Romania (RO)", text)
        self.assertIn("Price: 1.4573 RON per kWh", text)
        self.assertIn("Eurostat nrg_pc_204 (2026-S1)", text)
        self.assertIn("Tools > Electricity Cost", text)
        self.store.update("energy", {"override": {"pricePerKWh": 1.07, "currency": "RON"}})
        self.assertIn("your own price", energy.tray_price_message(self.store)[1])
        self.assertIn("Price: 1.07 RON per kWh", energy.tray_price_message(self.store)[1])
        self.store.remove("energy")
        self.country = "JP"
        energy.COUNTRY.reset()
        text = energy.tray_price_message(self.store)[1]
        self.assertIn("no electricity price", text)
        self.assertIn("Country: JP", text)

    def test_tray_menu_item_opens_the_dialog(self):
        import orbit_tray as tray
        icon = tray.OrbitTrayIcon(status_provider=lambda: {}, on_stop=lambda: None, startup_manager=MagicMock(),
                                  boot_task=MagicMock(), apis=(MagicMock(), MagicMock(), MagicMock()))
        items = {item.get("id"): item for item in icon.build_menu_items() if item.get("id")}
        self.assertEqual(items[tray.ID_ELECTRICITY_PRICE]["label"], "Electricity price...")
        self.assertEqual(len({item.get("id") for item in icon.build_menu_items() if item.get("id")}),
                         len([item for item in icon.build_menu_items() if item.get("id")]))
        with patch.object(icon, "_async_message_box") as box, \
             patch.object(energy, "tray_price_message", return_value=("Title", "Text")):
            self.assertEqual(icon.execute_command(tray.ID_ELECTRICITY_PRICE), "electricity_price_shown")
        box.assert_called_once_with("Text", "Title", 0x00040040)
        with patch.object(icon, "_async_message_box") as box, \
             patch.object(energy, "tray_price_message", side_effect=RuntimeError("boom")), self.assertLogs("orbit.tray", "ERROR"):
            icon.execute_command(tray.ID_ELECTRICITY_PRICE)
        self.assertIn("could not read", box.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
