import AppIntents
import SwiftUI

@main
struct OrbitApp: App {
    init() {
        OrbitAppShortcuts.updateAppShortcutParameters()
        OrbitBackgroundRefresh.register()
        Self.migrateDefaultTheme()
    }

    /// Ocean used to be the implicit default theme. Installs that never picked another theme
    /// move to Noir once; an explicit choice of any other theme is left alone.
    private static func migrateDefaultTheme() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "orbit.theme.noirMigrated") else { return }
        defaults.set(true, forKey: "orbit.theme.noirMigrated")
        if defaults.string(forKey: "orbit.theme") == "ocean" { defaults.set("noir", forKey: "orbit.theme") }
        if defaults.string(forKey: "orbit.activity.accent") == "ocean" { defaults.set("noir", forKey: "orbit.activity.accent") }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct OrbitAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OrbitWakePCIntent(),
            phrases: [
                "Power on my PC with \(.applicationName)",
                "Wake up my PC in \(.applicationName)",
                "Turn on my computer with \(.applicationName)"
            ],
            shortTitle: "Power On PC",
            systemImageName: "power"
        )
        AppShortcut(
            intent: OrbitShutdownPCIntent(),
            phrases: [
                "Shut down my PC with \(.applicationName)",
                "Turn off my PC in \(.applicationName)",
                "Power off my computer with \(.applicationName)"
            ],
            shortTitle: "Shut Down PC",
            systemImageName: "power.circle.fill"
        )
        AppShortcut(
            intent: OrbitSleepPCIntent(),
            phrases: [
                "Put my PC to sleep with \(.applicationName)",
                "Sleep my computer in \(.applicationName)"
            ],
            shortTitle: "Sleep PC",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: OrbitRestartPCIntent(),
            phrases: [
                "Restart my PC with \(.applicationName)",
                "Reboot my computer in \(.applicationName)"
            ],
            shortTitle: "Restart PC",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
