"""Why a phone cannot reach this PC, and the fixes, for the companion window.

Windows 11 marks every new network Public, and a firewall rule made for Private
networks then does not apply: the phone finds nothing. The diagnosis reads the
network profile of the adapter Orbit listens on and Orbit's own firewall rules, and
turns them into one verdict with the fix that matters.

The fixes change Windows settings, so they run only when the owner clicks them in
the window on this PC, through an elevated PowerShell that Windows asks permission
for (UAC), exactly like the boot task. Nothing here runs elevated on its own.
"""
from datetime import datetime, timezone
import json
import os
import subprocess
import threading
import time

FIREWALL_GROUP = "Orbit PC Companion"
CREATE_NO_WINDOW = 0x08000000
CACHE_SECONDS = 30
UTF8 = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $ErrorActionPreference = 'Stop'; "
# A reading that finds nothing (no Orbit rule exists yet) still records a silenced error, and
# powershell.exe would then exit with 1. Real failures stop the script before this line.
READ_END = "; exit 0"
PROFILES_SCRIPT = (UTF8 + "Get-NetConnectionProfile | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; "
                   "Interface = [string]$_.InterfaceAlias; Index = [int]$_.InterfaceIndex; "
                   "Category = [string]$_.NetworkCategory } } | ConvertTo-Json -Compress" + READ_END)
RULES_SCRIPT = (UTF8 + f"Get-NetFirewallRule -Group '{FIREWALL_GROUP}' -ErrorAction SilentlyContinue | ForEach-Object {{ "
                "$port = $_ | Get-NetFirewallPortFilter; [pscustomobject]@{ Name = [string]$_.DisplayName; "
                "Enabled = [string]$_.Enabled; Profile = [string]$_.Profile; Action = [string]$_.Action; "
                "Direction = [string]$_.Direction; Protocol = [string]$port.Protocol; Port = [string]$port.LocalPort } } "
                "| ConvertTo-Json -Compress" + READ_END)
ADDRESSES_SCRIPT = (UTF8 + "Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { "
                    "[pscustomobject]@{ Address = [string]$_.IPAddress; Index = [int]$_.InterfaceIndex } } | ConvertTo-Json -Compress"
                    + READ_END)


def firewall_plan(secure_port=8766, legacy_port=8765):
    """The inbound rules Orbit needs: local subnet only, Private and Domain networks only."""
    return [
        {"key": "https", "name": f"Orbit PC Companion - Encrypted connection (TCP {secure_port})", "protocol": "TCP",
         "port": int(secure_port), "required": True, "purpose": "Every paired iPhone, iPad, Mac and Apple TV"},
        {"key": "bonjour", "name": "Orbit PC Companion - Find my PC (UDP 5353)", "protocol": "UDP", "port": 5353,
         "required": True, "purpose": "Find my PC during pairing (Bonjour)"},
        {"key": "legacy", "name": f"Orbit PC Companion - Apple Watch and older apps (TCP {legacy_port})", "protocol": "TCP",
         "port": int(legacy_port), "required": False, "purpose": "The Apple Watch and app versions before 5.0"},
    ]


def _quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def firewall_fix_script(secure_port=8766, legacy_port=8765):
    """Replace Orbit's rule group with exactly the rules of `firewall_plan` (idempotent)."""
    lines = ["$ErrorActionPreference = 'Stop'",
             f"Get-NetFirewallRule -Group {_quote(FIREWALL_GROUP)} -ErrorAction SilentlyContinue | Remove-NetFirewallRule"]
    for rule in firewall_plan(secure_port, legacy_port):
        lines.append(f"New-NetFirewallRule -DisplayName {_quote(rule['name'])} -Group {_quote(FIREWALL_GROUP)} "
                     f"-Direction Inbound -Action Allow -Protocol {rule['protocol']} -LocalPort {int(rule['port'])} "
                     "-RemoteAddress LocalSubnet -Profile Private,Domain | Out-Null")
    return "; ".join(lines)


def private_network_script(interface_index):
    if isinstance(interface_index, bool) or not isinstance(interface_index, int) or not 0 < interface_index < 1_000_000:
        raise ValueError("Unknown network adapter.")
    return f"Set-NetConnectionProfile -InterfaceIndex {interface_index} -NetworkCategory Private"


def powershell_parameters(script):
    return '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + script.replace('"', '\\"') + '"'


def run_elevated(script):
    """Ask Windows (UAC) to run `script` as administrator. Returns once the prompt was shown."""
    if os.name != "nt":
        raise OSError("This fix needs Windows.")
    import ctypes
    result = ctypes.windll.shell32.ShellExecuteW(None, "runas", "powershell.exe", powershell_parameters(script), None, 0)
    if result <= 32:
        raise OSError("Windows did not grant administrator rights.")
    return True


class PowerShell:
    def __init__(self, runner=None):
        self.runner = runner or self._run

    @staticmethod
    def _run(script, timeout=20):
        if os.name != "nt":
            raise OSError("PowerShell diagnostics need Windows.")
        completed = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                                   capture_output=True, timeout=timeout, creationflags=CREATE_NO_WINDOW)
        if completed.returncode != 0:
            message = (completed.stderr or b"").decode("utf-8", "replace").strip()[:300]
            raise OSError(f"PowerShell exited with code {completed.returncode}" + (f": {message}" if message else "."))
        return (completed.stdout or b"").decode("utf-8-sig", "replace")

    def objects(self, script):
        text = self.runner(script).strip()
        if not text:
            return []
        value = json.loads(text)
        items = value if isinstance(value, list) else [value]
        return [item for item in items if isinstance(item, dict)]


def _profiles_list(value):
    return [part.strip() for part in str(value or "").split(",") if part.strip()]


def _enabled(value):
    return str(value).strip().casefold() in ("true", "1", "yes")


class Diagnostics:
    def __init__(self, shell=None, secure_port=8766, legacy_port=8765, address=None, sunshine=None,
                 listening=None, elevate=run_elevated, clock=time.monotonic, ttl=CACHE_SECONDS):
        self.shell = shell or PowerShell()
        self.secure_port = secure_port
        self.legacy_port = legacy_port
        self.address = address or (lambda: None)
        self.sunshine = sunshine or (lambda: None)
        self.listening = listening or (lambda: True)
        self.elevate = elevate
        self.clock = clock
        self.ttl = ttl
        self._cached = None
        self._at = None
        self._lock = threading.Lock()

    # MARK: readings

    def network(self):
        """The profile of the adapter that carries Orbit's address, plus every profile."""
        profiles = [{"name": item.get("Name") or "Network", "interface": item.get("Interface") or "",
                     "interfaceIndex": int(item.get("Index") or 0), "category": item.get("Category") or "Unknown"}
                    for item in self.shell.objects(PROFILES_SCRIPT)]
        address = self.address()
        current = None
        if address and profiles:
            try:
                indexes = {item.get("Address"): int(item.get("Index") or 0) for item in self.shell.objects(ADDRESSES_SCRIPT)}
            except (OSError, ValueError, subprocess.SubprocessError):
                indexes = {}
            current = next((profile for profile in profiles if profile["interfaceIndex"] == indexes.get(address)), None)
        if current is None and len(profiles) == 1:
            current = profiles[0]
        return current, profiles

    def rules(self):
        found = {}
        for item in self.shell.objects(RULES_SCRIPT):
            found[str(item.get("Name"))] = {"enabled": _enabled(item.get("Enabled")),
                                            "profiles": _profiles_list(item.get("Profile")),
                                            "allow": str(item.get("Action")).casefold() == "allow",
                                            "inbound": str(item.get("Direction")).casefold() == "inbound",
                                            "protocol": str(item.get("Protocol") or "").upper(),
                                            "port": str(item.get("Port") or "")}
        result = []
        for rule in firewall_plan(self.secure_port, self.legacy_port):
            existing = found.get(rule["name"])
            working = bool(existing and existing["enabled"] and existing["allow"] and existing["inbound"]
                           and existing["port"] == str(rule["port"]) and existing["protocol"] == rule["protocol"])
            result.append({**rule, "present": existing is not None, "enabled": bool(existing and existing["enabled"]),
                           "profiles": existing["profiles"] if existing else [], "working": working})
        return result

    # MARK: the report

    def report(self, force=False):
        with self._lock:
            if not force and self._cached is not None and self.clock() - self._at < self.ttl:
                return self._cached
        report = self._build()
        with self._lock:
            self._cached, self._at = report, self.clock()
        return report

    def _build(self):
        checked = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        address = self.address()
        companion = {"state": "ok" if self.listening() else "problem", "address": address,
                     "securePort": self.secure_port, "detail": f"{address or 'No network address'} · HTTPS {self.secure_port}"}
        try:
            current, profiles = self.network()
            rules = self.rules()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            return {"checkedAt": checked, "available": False, "reason": str(error)[:300], "network": None, "profiles": [],
                    "firewall": {"state": "unknown", "rules": []}, "companion": companion, "sunshine": self.sunshine(),
                    "verdict": {"state": "unknown", "title": "Orbit could not check this PC's network",
                                "detail": "Windows PowerShell did not answer. The checks need Windows 10 or 11."},
                    "fixes": []}
        category = (current or {}).get("category", "Unknown")
        public = category.casefold() == "public"
        required = [rule for rule in rules if rule["required"]]
        missing = [rule for rule in required if not rule["working"]]
        covers_public = all("Public" in rule["profiles"] or "Any" in rule["profiles"] for rule in required if rule["working"])
        network = None
        if current is not None:
            network = {**current, "state": "problem" if public and not (covers_public and not missing) else "ok",
                       "detail": f"{current['name']} · {category}"}
        firewall = {"state": "problem" if missing else "ok", "rules": rules,
                    "detail": "Orbit's rules are missing" if len(missing) == len(required)
                    else ("Some of Orbit's rules are missing or turned off" if missing else "Orbit's rules allow phones on this network")}
        fixes = []
        if public and current is not None:
            fixes.append({"kind": "privateNetwork", "interfaceIndex": current["interfaceIndex"], "label": "Make this network Private"})
        if missing:
            fixes.append({"kind": "firewall", "label": "Add Orbit's firewall rules"})
        if public and current is not None:
            verdict = {"state": "problem", "title": "Phones cannot reach this PC",
                       "detail": f"Windows treats “{current['name']}” as a Public network, where Orbit is not allowed in. "
                                 "If this is your home network, make it Private."}
        elif missing:
            verdict = {"state": "warning", "title": "Windows Firewall may block your devices",
                       "detail": "Orbit's firewall rules are not there yet. If you allowed Orbit or Python when Windows asked, "
                                 "devices can still connect; adding the rules makes it certain."}
        elif companion["state"] != "ok":
            verdict = {"state": "problem", "title": "Orbit is not listening", "detail": "Restart Orbit PC Companion."}
        else:
            name = current["name"] if current else "this network"
            verdict = {"state": "ok", "title": f"Devices on {name} can reach this PC",
                       "detail": f"Encrypted connection on {address or 'this PC'}:{self.secure_port}, Find my PC on UDP 5353."}
        return {"checkedAt": checked, "available": True, "network": network, "profiles": profiles, "firewall": firewall,
                "companion": companion, "sunshine": self.sunshine(), "verdict": verdict, "fixes": fixes}

    # MARK: fixes (only from the window on this PC)

    def fix_firewall(self):
        self.elevate(firewall_fix_script(self.secure_port, self.legacy_port))
        self.invalidate()
        return True

    def make_private(self, interface_index):
        self.elevate(private_network_script(interface_index))
        self.invalidate()
        return True

    def invalidate(self):
        with self._lock:
            self._cached = None
