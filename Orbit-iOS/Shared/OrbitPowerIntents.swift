import AppIntents
import Foundation

// MARK: - Pro power intents for Siri, Shortcuts and the watch

// Power On, Shut Down, Sleep and Restart as Shortcuts actions and App Shortcuts ("Put my PC to sleep
// with Orbit"). Compiled into Orbit, OrbitWatch and OrbitWatchWidgets, never into OrbitWidgets: when
// Orbit isn't running, iOS runs an intent that the widget extension also contains in the widget
// process, and App Shortcuts fail there ("Couldn't find AppShortcutsProvider", shown as "Unable to
// run App Shortcut"). Home Screen widgets, Live Activities and Control Center use widget-only copies
// (OrbitWidgets/OrbitWidgetPowerIntents.swift). The type names stay as they are, because saved
// shortcuts refer to them.
struct OrbitWakePCIntent: AppIntent {
    static var title: LocalizedStringResource = "Power On PC (Wake-on-LAN)"
    static var description = IntentDescription("Sends a Wake-on-LAN magic packet to turn on your paired PC.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "PC ID")
    var pcID: String?

    init() {}
    init(pcID: String?) { self.pcID = pcID }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if os(iOS)
        guard OrbitProEntitlement.cachedIsUnlocked else { throw OrbitProRequiredError() }
        #endif
        let result = try await OrbitWidgetPowerService.wakePC(id: pcID)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct OrbitShutdownPCIntent: AppIntent {
    static var title: LocalizedStringResource = "Shut Down PC"
    static var description = IntentDescription("Safely shuts down your paired Windows PC over encrypted HTTPS.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "PC ID")
    var pcID: String?

    init() {}
    init(pcID: String?) { self.pcID = pcID }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if os(iOS)
        guard OrbitProEntitlement.cachedIsUnlocked else { throw OrbitProRequiredError() }
        #endif
        let result = try await OrbitWidgetPowerService.sendPowerAction("shutdown", id: pcID)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct OrbitSleepPCIntent: AppIntent {
    static var title: LocalizedStringResource = "Put PC to Sleep"
    static var description = IntentDescription("Puts your paired Windows PC into sleep mode.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "PC ID")
    var pcID: String?

    init() {}
    init(pcID: String?) { self.pcID = pcID }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if os(iOS)
        guard OrbitProEntitlement.cachedIsUnlocked else { throw OrbitProRequiredError() }
        #endif
        let result = try await OrbitWidgetPowerService.sendPowerAction("sleep", id: pcID)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct OrbitRestartPCIntent: AppIntent {
    static var title: LocalizedStringResource = "Restart PC"
    static var description = IntentDescription("Restarts your paired Windows PC.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "PC ID")
    var pcID: String?

    init() {}
    init(pcID: String?) { self.pcID = pcID }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if os(iOS)
        guard OrbitProEntitlement.cachedIsUnlocked else { throw OrbitProRequiredError() }
        #endif
        let result = try await OrbitWidgetPowerService.sendPowerAction("restart", id: pcID)
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}
