"""Compile and run the App Store rating prompt rules (Shared/OrbitReviewPrompt.swift) with a fake clock.

Covers: fewer than 5 different days (launches on the same day count once, midnight in the device's time zone,
a clock set back), demo mode and every other blocker (onboarding, stream, alert, paywall, Windows' countdown,
not in front), once per version, 120 days between requests, the 5 minutes after an error, and the 2.5-second
delay (a blocker, the paywall or an error during it drops the prompt).

Then checks the wiring: the files are in the iPhone/iPad and Mac targets only (Apple TV and Apple Watch have no
rating prompt), the root views hand over `requestReview` and their blockers, the good moments (connected to a
real PC, a deck button or power action that worked) and the errors are reported, the paywalls pause it, and the
record stays out of the iCloud settings sync.

No StoreKit, UserDefaults, device or network is touched.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Orbit-iOS"

with tempfile.TemporaryDirectory(prefix="orbit-review-prompt-") as directory:
    binary = Path(directory) / "review-prompt-tests"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
        str(APP / "Shared/OrbitReviewPrompt.swift"),
        str(APP / "Tests/OrbitReviewPromptTests.swift"),
        "-o", str(binary),
    ], check=True)
    result = subprocess.run([str(binary)], check=True, timeout=60, capture_output=True, text=True)
    print(result.stdout, end="")
    for section in ("days:", "rules:", "prompter: under 5 days", "prompter: demo mode"):
        assert section in result.stdout, f"the checks did not all run ({section!r} missing)"


def read(path):
    return (APP / path).read_text(encoding="utf-8")


# Targets: iPhone/iPad and Mac only.
project = read("Orbit.xcodeproj/project.pbxproj")
phases = {}
for match in re.finditer(r"(\w{24}) /\* (\S+) \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};", project, re.S):
    _, name, body = match.groups()
    phase = re.search(r"(\w{24}) /\* Sources \*/", body).group(1)
    phases[name] = re.search(phase + r" /\* Sources \*/ = \{.*?files = \((.*?)\);", project, re.S).group(1)
for source in ("OrbitReviewPrompt.swift", "OrbitReviewPromptHost.swift"):
    for target in ("Orbit", "OrbitMac"):
        assert f"{source} in Sources" in phases[target], f"{source} is not in {target}"
    for target in ("OrbitTV", "OrbitWatch", "OrbitWidgets", "OrbitWatchWidgets", "OrbitShare", "OrbitNotificationService"):
        assert f"{source} in Sources" not in phases.get(target, ""), f"{source} must not be in {target}"
for folder in ("OrbitTV", "OrbitWatch"):
    for path in (APP / folder).glob("*.swift"):
        text = path.read_text(encoding="utf-8")
        assert "requestReview" not in text and "OrbitReviewPrompter" not in text, f"{path.name}: no rating prompt on {folder}"

host = read("Shared/OrbitReviewPromptHost.swift")
assert host.startswith("#if os(iOS) || os(macOS)"), "the StoreKit side is for iOS and macOS only"
assert r"@Environment(\.requestReview)" in host and "attachPresenter" in host and "detachPresenter" in host
assert "UIAlertController" in host and "attachedSheet" in host and "modalWindow" in host, "alerts are checked on both platforms"
assert "didBecomeActiveNotification" in host, "days are counted when Orbit comes to the front"

# iPhone/iPad: the root view, its blockers, the moments and the errors.
content = read("Orbit/ContentView.swift")
ios_host = content[content.index(".orbitReviewPromptHost"):]
ios_host = ios_host[:ios_host.index("return blockers")]
for needle in ("vm.isDemoMode", ".demoMode", "vm.hasCompletedOnboarding", "vm.showOnboarding", ".onboarding",
               "stream.isPresented", "stream.session?.isActive", "vm.isShowingStreamView", "MoonlightIdleTimer.isHeld",
               "vm.powerCountdown.running()", ".powerCountdown"):
    assert needle in ios_host, f"iPhone blockers: {needle} missing"
assert "stream.launchError" in content and "vm.streamError" in content, "stream errors are reported on iPhone"
model = read("Orbit/ModelsAndServices.swift")
assert "noteGoodMoment(.connected)" in model and "!wasOnline && decoded.isOnline" in model, "iPhone: connected moment"
assert "OrbitReviewPrompter.powerActions.contains(action) { OrbitReviewPrompter.shared.noteGoodMoment(.powerAction)" in model
assert model.count("OrbitReviewPrompter.shared.noteError()") >= 5, "iPhone: errors (connection lost, connect, wake, power)"
power = model[model.index("func sendPowerAction"):model.index("func noteActionSent")]
demo = power[:power.index("guard metrics.isOnline")]
assert "isDemoMode" in demo and "return" in demo and "noteGoodMoment" not in demo, "demo power actions return before any moment"
deck = read("Orbit/DeckView.swift")
assert "noteGoodMoment(.deckButton)" in deck and "if kind == .failure { OrbitReviewPrompter.shared.noteError() }" in deck
deck_demo = deck[deck.index("if phase == .demo {"):deck.index("guard button.id.allSatisfy")]
assert "noteGoodMoment" not in deck_demo, "a demo deck button is not a good moment"
assert ".orbitPausesReviewPrompt(.paywall)" in read("Orbit/Appearance.swift"), "the iPhone paywall pauses the prompt"
assert "public static var isHeld: Bool { holds > 0 }" in read("Packages/MoonlightCore/Sources/MoonlightCore/StreamSession.swift")

# Mac.
mac_app = read("OrbitMac/OrbitMacApp.swift")
mac_host = mac_app[mac_app.index(".orbitReviewPromptHost"):]
mac_host = mac_host[:mac_host.index("return blockers")]
for needle in ("viewModel.isDemoMode", ".demoMode", "stream.isPresented", "stream.session?.isActive", "viewModel.isStreaming",
               "viewModel.powerCountdown.running()", "MacMainWindow.isKey", ".notInFront"):
    assert needle in mac_host, f"Mac blockers: {needle} missing"
mac_model = read("OrbitMac/OrbitMacViewModel.swift")
assert "noteGoodMoment(.connected)" in mac_model and "noteGoodMoment(.powerAction)" in mac_model
assert mac_model.count("OrbitReviewPrompter.shared.noteError()") >= 4, "Mac: errors (connection lost, actions, wake)"
mac_power = mac_model[mac_model.index("func sendAction"):mac_model.index("func cancelPowerCountdown")]
assert mac_power.index("if isDemoMode") < mac_power.index("noteGoodMoment"), "Mac demo actions return before any moment"
mac_deck = read("OrbitMac/OrbitMacDeckView.swift")
run = mac_deck[mac_deck.index("func runDeckButton"):mac_deck.index("func editDeck")]
assert run.index("if isDemoMode") < run.index("noteGoodMoment(.deckButton)"), "a Mac demo deck button is not a good moment"
assert "OrbitReviewPrompter.shared.noteError()" in run
assert "static var isKey: Bool" in mac_deck
assert "card.orbitPausesReviewPrompt(.paywall)" in read("Shared/OrbitProStore.swift"), "the Mac paywall pauses the prompt"

# The power actions that count; media keys and volume do not.
prompt = read("Shared/OrbitReviewPrompt.swift")
assert 'static let powerActions: Set<String> = ["lock", "sleep", "shutdown", "restart"]' in prompt

# The record stays on the device: not in the iCloud settings catalogs.
assert 'defaultsKey = "orbit.reviewPrompt.v1"' in prompt
for path in ("Shared/OrbitSettingsSync.swift", "Orbit/Appearance.swift", "OrbitMac/OrbitMacDesign.swift", "Shared/OrbitPCSync.swift"):
    assert "reviewPrompt" not in read(path), f"{path}: the rating prompt record must not sync through iCloud"
assert "NSUbiquitousKeyValueStore" not in prompt and "NSUbiquitousKeyValueStore" not in host
print("wiring: iPhone/iPad and Mac only, blockers, good moments, errors, paywalls, record kept on the device: OK")
