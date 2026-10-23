import AppIntents
import SwiftUI

/// "Shortcuts actions" and "Automation ideas" in Tools → Apple Ecosystem → Widgets & Siri: every
/// action Orbit adds to the Shortcuts app (OrbitPCIntents.swift and the Pro power actions), plus
/// automations people can build from them. Used inside `WidgetHelpView`'s List.
struct OrbitShortcutsHelpSections: View {
    @Environment(\.orbitTheme) private var theme

    private struct Row: Identifiable {
        let title: String
        let detail: String
        let icon: String
        var id: String { title }
    }

    private let actions: [Row] = [
        Row(title: "Lock PC", detail: "Locks Windows, like pressing Windows+L.", icon: "lock.fill"),
        Row(title: "Set PC Volume", detail: "Sets the PC volume from 0 to 100%.", icon: "speaker.wave.2.fill"),
        Row(title: "Toggle PC Mute", detail: "Mutes the PC, or unmutes it.", icon: "speaker.slash.fill"),
        Row(title: "Control PC Media", detail: "Play/Pause, next or previous track in whatever is playing.", icon: "playpause.fill"),
        Row(title: "Copy Text to PC Clipboard", detail: "Puts text on the PC's clipboard, ready for Ctrl+V.", icon: "doc.on.clipboard"),
        Row(title: "Type Text on PC", detail: "Types into the window in front, up to 1,000 characters.", icon: "keyboard"),
        Row(title: "Open Link on PC", detail: "Opens a web link in the PC's browser.", icon: "safari"),
        Row(title: "Launch Game on PC", detail: "Starts a game from Sunshine's app list.", icon: "gamecontroller.fill"),
        Row(title: "Get PC Reading", detail: "Returns a number: temperature (°C), load (%), power (W) or FPS.", icon: "thermometer.medium"),
        Row(title: "Get PC Status", detail: "Returns one sentence about the PC, and says so when it's off.", icon: "desktopcomputer"),
        Row(title: "Sleep PC When Downloads Finish", detail: "Sleeps or shuts down the PC after its Steam, Epic or GOG downloads.", icon: "arrow.down.circle"),
        Row(title: "Power On, Sleep, Shut Down, Restart PC", detail: "Power actions, with Orbit Pro.", icon: "power")
    ]

    private let ideas: [Row] = [
        Row(title: "Leave home → Lock PC", detail: "Nobody can use the PC while you're out.", icon: "location.fill"),
        Row(title: "Alarm stops → Power On PC", detail: "The PC is ready by the time you sit down (Orbit Pro).", icon: "alarm.fill"),
        Row(title: "Sleep Focus on → Sleep PC When Downloads Finish", detail: "Big downloads finish overnight, then the PC sleeps instead of running until morning.", icon: "moon.fill"),
        Row(title: "Arrive home → Power On PC, then Launch Game on PC", detail: "Add a Wait of a minute between them so Windows can start.", icon: "house.fill"),
        Row(title: "Back Tap → Toggle PC Mute", detail: "Settings → Accessibility → Touch → Back Tap runs any shortcut. The Action button works too.", icon: "hand.tap.fill"),
        Row(title: "Every evening → Get PC Reading", detail: "Pick GPU temperature, then If it's above 85, Show Notification.", icon: "thermometer.high")
    ]

    var body: some View {
        Section {
            ForEach(actions) { row($0) }
            ShortcutsLink()
                .shortcutsLinkStyle(.automaticOutline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } header: {
            Text("Shortcuts actions")
        } footer: {
            Text("In the Shortcuts app, tap +, then search for Orbit. Leave the PC empty to use your default PC. Siri also knows \"Lock my PC with Orbit\" and \"How is my PC doing in Orbit\".")
        }
        .orbitRow()

        Section {
            ForEach(ideas) { row($0) }
        } header: {
            Text("Automation ideas")
        } footer: {
            Text("Create them in Shortcuts → Automation → New Automation, and turn off Ask Before Running if you like.")
        }
        .orbitRow()
    }

    private func row(_ item: Row) -> some View {
        HStack(spacing: 12) {
            OrbitIconBadge(systemName: item.icon, tint: theme.accent, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// `ORBIT_INTENTS_SELFTEST=read|all` (in the simulator pass `SIMCTL_CHILD_ORBIT_INTENTS_SELFTEST`)
/// runs the Shortcuts actions against the default PC, prints one PASS/FAIL line each and exits.
/// It refuses to run unless `ORBIT_INTENTS_SELFTEST_PC` equals the default PC's name, so it is never
/// pointed at a real PC by accident: use it with a pretend PC only. `read` only reads; `all` also
/// changes the volume, types, copies, opens a link, launches an app, locks and sets a downloads rule;
/// `offline` expects a PC that doesn't answer; `older` expects an agent without `powerAfter`.
enum OrbitIntentsSelfTest {
    static func run(mode: String) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await perform(mode: mode)
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func check(_ name: String, _ body: () async throws -> String) async {
        do { print("PASS \(name): \(try await body())") } catch { print("FAIL \(name): \(error.localizedDescription)") }
    }

    private static func expectFailure(_ name: String, containing text: String, _ body: () async throws -> String) async {
        do {
            print("FAIL \(name): succeeded with \(try await body())")
        } catch {
            let message = error.localizedDescription
            print(message.contains(text) ? "PASS \(name) (refused): \(message)" : "FAIL \(name): unexpected error \(message)")
        }
    }

    private static func perform(mode: String) async {
        let expected = ProcessInfo.processInfo.environment["ORBIT_INTENTS_SELFTEST_PC"] ?? ""
        guard let pc = OrbitPCEntity.defaultPC(), !expected.isEmpty, pc.name == expected else {
            print("SELFTEST refused: set ORBIT_INTENTS_SELFTEST_PC to the default PC's name (default is \(OrbitPCEntity.defaultPC()?.name ?? "none")).")
            return
        }
        print("SELFTEST against \(pc.name) (\(pc.host)), mode \(mode)")
        switch mode {
        case "offline":
            // Pretend PC set to {"online": false}: nothing answers.
            await check("status while offline") { try await OrbitPCActions.status(pc: pc) }
            await expectFailure("reading while offline", containing: "isn't reachable") { try await OrbitPCActions.reading(.cpuTemperature, pc: pc).dialog }
            await expectFailure("lock while offline", containing: "isn't reachable") { try await OrbitPCActions.lock(pc: pc) }
            print("SELFTEST done")
            return
        case "older":
            // An agent without powerAfter (or without /api/capabilities at all).
            await expectFailure("downloads rule on an older agent", containing: "newer Orbit Companion") {
                try await OrbitPCActions.sleepWhenDownloadsFinish(.shutdown, delaySeconds: 60, pc: pc)
            }
            print("SELFTEST done")
            return
        default:
            break
        }
        await check("entities") { OrbitPCEntity.all().map(\.name).joined(separator: ", ") }
        await check("status (default PC)") { try await OrbitPCActions.status(pc: nil) }
        for reading in OrbitPCReading.allCases {
            await check("reading \(reading.rawValue)") {
                let result = try await OrbitPCActions.reading(reading, pc: pc)
                return "\(result.value) · \(result.dialog)"
            }
        }
        await check("Sunshine apps") { try await OrbitPCActions.sunshineApps(pc: pc).joined(separator: ", ") }
        await check("game picker without a chosen PC") { try await OrbitSunshineAppOptionsProvider().results().joined(separator: ", ") }
        await expectFailure("removed PC", containing: "no longer saved") { try await OrbitPCActions.lock(pc: OrbitPCEntity(id: "removed-pc", name: "Removed PC")) }
        await expectFailure("volume 150", containing: "0 to 100") { try await OrbitPCActions.setVolume(150, pc: pc) }
        await expectFailure("type emoji", containing: "Emoji") { try await OrbitPCActions.typeText("hi 🎮", pc: pc) }
        await expectFailure("open ftp link", containing: "http and https") { try await OrbitPCActions.open(link: "ftp://example.com/file", pc: pc) }
        await expectFailure("open link with password", containing: "user name or password") { try await OrbitPCActions.open(link: "https://user:secret@example.com", pc: pc) }
        await expectFailure("countdown 5 s", containing: "30 seconds") { try await OrbitPCActions.sleepWhenDownloadsFinish(.sleep, delaySeconds: 5, pc: pc) }
        let wasDemo = UserDefaults.standard.bool(forKey: "demoMode")
        UserDefaults.standard.set(true, forKey: "demoMode")
        await expectFailure("demo mode", containing: "Demo Mode") { try await OrbitPCActions.status(pc: pc) }
        UserDefaults.standard.set(wasDemo, forKey: "demoMode")
        guard mode == "all" else { print("SELFTEST done"); return }
        await check("volume 35") { try await OrbitPCActions.setVolume(35, pc: pc) }
        await check("toggle mute") { try await OrbitPCActions.toggleMute(pc: pc) }
        await check("toggle mute again") { try await OrbitPCActions.toggleMute(pc: pc) }
        await check("media next") { try await OrbitPCActions.media(.next, pc: pc) }
        await check("media play/pause") { try await OrbitPCActions.media(.playPause, pc: pc) }
        await check("clipboard") { try await OrbitPCActions.copyToClipboard("Orbit self-test: C++ & ünïcode ✓", pc: pc) }
        await check("type") { try await OrbitPCActions.typeText("Hello from Orbit C++ 1+1=2\nsecond line", pc: pc) }
        await check("open link") { try await OrbitPCActions.open(link: "https://example.com/orbit?q=1+2", pc: pc) }
        await check("launch notepad (partial name)") { try await OrbitPCActions.launch("notepad", pc: pc) }
        await expectFailure("launch unknown game", containing: "isn't in") { try await OrbitPCActions.launch("Half-Life 3", pc: pc) }
        await check("lock") { try await OrbitPCActions.lock(pc: pc) }
        await check("sleep when downloads finish") { try await OrbitPCActions.sleepWhenDownloadsFinish(.sleep, delaySeconds: 90, pc: pc) }
        print("SELFTEST done")
    }
}
#endif
