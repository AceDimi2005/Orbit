"""Network diagnosis and the elevated fixes, with a fake PowerShell: nothing changes Windows."""
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import orbit_diagnostics as diagnostics

PROFILE_PUBLIC = {"Name": "Dimi-Home 5G", "Interface": "Wi-Fi", "Index": 12, "Category": "Public"}
PROFILE_PRIVATE = {**PROFILE_PUBLIC, "Category": "Private"}
WSL = {"Name": "Network 3", "Interface": "vEthernet (WSL)", "Index": 31, "Category": "Public"}
ADDRESSES = [{"Address": "192.168.1.196", "Index": 12}, {"Address": "172.24.0.1", "Index": 31}]


def rules(enabled=True, profile="Domain, Private"):
    plan = diagnostics.firewall_plan()
    return [{"Name": rule["name"], "Enabled": "True" if enabled else "False", "Profile": profile, "Action": "Allow",
             "Direction": "Inbound", "Protocol": rule["protocol"], "Port": str(rule["port"])} for rule in plan]


class FakeShell:
    def __init__(self, profiles, firewall, addresses=ADDRESSES, fail=False):
        self.profiles, self.firewall, self.addresses, self.fail = profiles, firewall, addresses, fail
        self.scripts = []

    def runner(self, script):
        self.scripts.append(script)
        if self.fail:
            raise OSError("powershell.exe was not found")
        if "Get-NetConnectionProfile" in script:
            value = self.profiles
        elif "Get-NetFirewallRule" in script:
            value = self.firewall
        else:
            value = self.addresses
        if isinstance(value, list) and len(value) == 1:
            value = value[0]  # ConvertTo-Json writes one object without the array
        return json.dumps(value) if value else ""


def make(shell, elevate=None, clock=None):
    return diagnostics.Diagnostics(shell=diagnostics.PowerShell(runner=shell.runner), address=lambda: "192.168.1.196",
                                   sunshine=lambda: {"installed": True}, elevate=elevate or (lambda script: True),
                                   clock=clock or (lambda: 0.0))


class ScriptTests(unittest.TestCase):
    def test_firewall_rules_are_local_subnet_private_and_domain_only(self):
        script = diagnostics.firewall_fix_script(8766, 8765)
        self.assertEqual(script.count("New-NetFirewallRule"), 3)
        self.assertEqual(script.count("-RemoteAddress LocalSubnet -Profile Private,Domain"), 3)
        for port, protocol in ((8766, "TCP"), (5353, "UDP"), (8765, "TCP")):
            self.assertIn(f"-Protocol {protocol} -LocalPort {port}", script)
        self.assertIn("Remove-NetFirewallRule", script)  # idempotent: the group is replaced
        self.assertNotIn("Public", script)

    def test_private_network_script_only_takes_an_adapter_number(self):
        self.assertEqual(diagnostics.private_network_script(12), "Set-NetConnectionProfile -InterfaceIndex 12 -NetworkCategory Private")
        for bad in ("12; Remove-Item C:\\", 0, -1, True, 12.5, None):
            with self.assertRaises(ValueError):
                diagnostics.private_network_script(bad)

    def test_elevation_needs_windows(self):
        with unittest.mock.patch.object(diagnostics.os, "name", "posix"):
            with self.assertRaises(OSError):
                diagnostics.run_elevated("Get-Date")

    def test_readings_exit_0_unless_they_failed_and_failures_say_why(self):
        for script in (diagnostics.PROFILES_SCRIPT, diagnostics.RULES_SCRIPT, diagnostics.ADDRESSES_SCRIPT):
            self.assertTrue(script.startswith(diagnostics.UTF8))  # $ErrorActionPreference = 'Stop' comes first
            self.assertTrue(script.endswith("; exit 0"))
        for stderr, expected in ((b"", "PowerShell exited with code 1."), (b"Access denied", "PowerShell exited with code 1: Access denied")):
            completed = SimpleNamespace(returncode=1, stdout=b"", stderr=stderr)
            with patch.object(diagnostics, "os", SimpleNamespace(name="nt")), \
                    patch.object(diagnostics.subprocess, "run", return_value=completed):
                with self.assertRaises(OSError) as raised:
                    diagnostics.PowerShell._run(diagnostics.RULES_SCRIPT)
            self.assertEqual(str(raised.exception), expected)

    def test_powershell_output_of_one_object_or_many(self):
        shell = diagnostics.PowerShell(runner=lambda script: json.dumps({"Name": "only"}))
        self.assertEqual(shell.objects("x"), [{"Name": "only"}])
        shell = diagnostics.PowerShell(runner=lambda script: "")
        self.assertEqual(shell.objects("x"), [])


class VerdictTests(unittest.TestCase):
    def test_public_network_is_the_problem_with_its_fix(self):
        shell = FakeShell([PROFILE_PUBLIC, WSL], [])
        report = make(shell).report()
        self.assertEqual(report["verdict"]["state"], "problem")
        self.assertEqual(report["verdict"]["title"], "Phones cannot reach this PC")
        self.assertIn("Dimi-Home 5G", report["verdict"]["detail"])
        self.assertEqual(report["network"]["interfaceIndex"], 12)  # the adapter that carries Orbit's address
        self.assertEqual([fix["kind"] for fix in report["fixes"]], ["privateNetwork", "firewall"])
        self.assertEqual(report["fixes"][0]["interfaceIndex"], 12)
        self.assertEqual(len(report["profiles"]), 2)

    def test_missing_rules_on_a_private_network_are_a_warning(self):
        report = make(FakeShell([PROFILE_PRIVATE], [])).report()
        self.assertEqual(report["verdict"]["state"], "warning")
        self.assertEqual([fix["kind"] for fix in report["fixes"]], ["firewall"])
        self.assertEqual(report["firewall"]["state"], "problem")

    def test_rules_turned_off_count_as_missing(self):
        report = make(FakeShell([PROFILE_PRIVATE], rules(enabled=False))).report()
        self.assertEqual(report["verdict"]["state"], "warning")
        self.assertTrue(all(rule["present"] and not rule["working"] for rule in report["firewall"]["rules"]))

    def test_everything_in_place(self):
        report = make(FakeShell([PROFILE_PRIVATE], rules())).report()
        self.assertEqual(report["verdict"], {"state": "ok", "title": "Devices on Dimi-Home 5G can reach this PC",
                                             "detail": "Encrypted connection on 192.168.1.196:8766, Find my PC on UDP 5353."})
        self.assertEqual(report["fixes"], [])
        self.assertEqual(report["firewall"]["rules"][0]["profiles"], ["Domain", "Private"])

    def test_powershell_failure_is_reported_not_guessed(self):
        report = make(FakeShell([], [], fail=True)).report()
        self.assertFalse(report["available"])
        self.assertEqual(report["verdict"]["state"], "unknown")
        self.assertEqual(report["fixes"], [])

    def test_results_are_cached_until_forced_or_a_fix(self):
        shell = FakeShell([PROFILE_PRIVATE], rules())
        now = {"value": 0.0}
        elevated = []
        checker = make(shell, elevate=elevated.append, clock=lambda: now["value"])
        checker.report()
        calls = len(shell.scripts)
        checker.report()
        self.assertEqual(len(shell.scripts), calls)
        now["value"] += diagnostics.CACHE_SECONDS + 1
        checker.report()
        self.assertGreater(len(shell.scripts), calls)
        calls = len(shell.scripts)
        checker.report(force=True)
        self.assertGreater(len(shell.scripts), calls)
        checker.fix_firewall()
        self.assertIn("New-NetFirewallRule", elevated[0])
        calls = len(shell.scripts)
        checker.report()  # the fix invalidated the cache
        self.assertGreater(len(shell.scripts), calls)
        checker.make_private(12)
        self.assertEqual(elevated[-1], "Set-NetConnectionProfile -InterfaceIndex 12 -NetworkCategory Private")


if __name__ == "__main__":
    unittest.main()
