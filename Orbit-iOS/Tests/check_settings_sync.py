"""Compile and run the iCloud settings sync rules (Shared/OrbitSettingsSync.swift) and the "Sync with iCloud"
switch of the saved-PC sync (Shared/OrbitPCSync.swift) against in-memory stores.

Simulates an iPhone, an iPad and a Mac sharing one iCloud key-value store: first upload, joining devices,
newest-edit-wins with slow clocks and write races, tombstones for removals, Pro themes on a device without
Orbit Pro, the Pro lockdown staying local, value validation, per-PC overview layouts, and the switch (off reads
and writes nothing; PCs removed meanwhile are published once it is back on).

Also checks that the apps wire it up: the file is in the iPhone and Mac targets, every platform shows the
switch, and the Apple TV, Mac and iPhone only read iCloud while it is on.

No iCloud account, network or device is touched.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Orbit-iOS"

with tempfile.TemporaryDirectory(prefix="orbit-settings-sync-") as directory:
    binary = Path(directory) / "settings-sync-tests"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
        str(APP / "Shared/OrbitPCSync.swift"),
        str(APP / "Shared/OrbitSettingsSync.swift"),
        str(APP / "Tests/OrbitSettingsSyncTests.swift"),
        "-o", str(binary),
    ], check=True)
    result = subprocess.run([str(binary)], check=True, timeout=60, capture_output=True, text=True)
    print(result.stdout, end="")
    assert "settings sync:" in result.stdout and "iCloud switch:" in result.stdout, "the checks did not all run"

# Wiring in the apps.
project = (APP / "Orbit.xcodeproj/project.pbxproj").read_text()
phases = {}
for match in re.finditer(r"(\w{24}) /\* (\S+) \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};", project, re.S):
    _, name, body = match.groups()
    phase = re.search(r"(\w{24}) /\* Sources \*/", body).group(1)
    files = re.search(phase + r" /\* Sources \*/ = \{.*?files = \((.*?)\);", project, re.S).group(1)
    phases[name] = files
for target in ("Orbit", "OrbitMac"):
    assert "OrbitSettingsSync.swift in Sources" in phases[target], f"OrbitSettingsSync.swift is not in {target}"
for target in ("Orbit", "OrbitMac", "OrbitTV"):
    assert "OrbitPCSync.swift in Sources" in phases[target], f"OrbitPCSync.swift is not in {target}"

ios = (APP / "Orbit/ContentView.swift").read_text()
assert "Sync with iCloud" in ios and "vm.setCloudSync" in ios, "the iPhone/iPad Settings switch is missing"
assert "OrbitSettingsSync.shared.startOnIPhoneOrIPad()" in (APP / "Orbit/ModelsAndServices.swift").read_text()
mac_settings = (APP / "OrbitMac/OrbitMacSettingsView.swift").read_text()
assert "Sync with iCloud" in mac_settings and "vm.setCloudSync" in mac_settings, "the Mac Settings switch is missing"
assert "OrbitSettingsSync.shared.startOnMac()" in (APP / "OrbitMac/OrbitMacViewModel.swift").read_text()
tv = (APP / "OrbitTV/OrbitTVViews.swift").read_text()
assert "vm.setCloudSync(!vm.isCloudSyncOn)" in tv, "the Apple TV switch is missing"

# Direct reads of the saved PCs in iCloud honour the switch.
for path in ("OrbitMac/OrbitMacViewModel+Services.swift", "OrbitTV/OrbitTVViewModel.swift"):
    text = (APP / path).read_text()
    reads = [m.start() for m in re.finditer(r'NSUbiquitousKeyValueStore\.default\.data\(forKey: "orbit\.syncedPCs\.v1"\)', text)]
    assert reads, f"{path}: no iCloud read found"
    for start in reads:
        line = text[text.rfind("\n", 0, start) + 1:text.find("\n", start)]
        assert "OrbitCloudSyncSwitch.isOn" in line, f"{path}: iCloud read without the switch: {line.strip()}"

# Lockdown after a refund adopts its change instead of publishing it.
assert 'adoptLocalValues(forKeys: ["orbit.theme", "orbit.activity.accent"])' in (APP / "Orbit/Appearance.swift").read_text()
assert 'adoptLocalValues(forKeys: ["mac.theme"])' in (APP / "OrbitMac/OrbitMacDesign.swift").read_text()
# The old, never-read theme copy in iCloud is gone.
assert 'NSUbiquitousKeyValueStore.default.set' not in (APP / "Orbit/Appearance.swift").read_text()
print("wiring: targets, switches on iPhone/iPad, Mac and Apple TV, gated iCloud reads, local lockdown: OK")
