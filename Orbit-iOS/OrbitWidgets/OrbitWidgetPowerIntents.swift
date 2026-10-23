import AppIntents
import Foundation

// Power buttons for Home Screen widgets, Live Activities and Control Center (Orbit Pro).
//
// Widget-only copies of the Pro power intents in Shared/OrbitPowerIntents.swift. iOS runs an intent
// that both the app and this extension contain in this extension while Orbit is closed, and then
// the App Shortcuts that use it fail ("Unable to run App Shortcut"). Separate types keep Siri and
// Shortcuts on the app's intents and these buttons in the widget process. They don't show up in
// the Shortcuts app (`isDiscoverable = false`), which lists the app's versions instead.

struct OrbitWidgetWakePCIntent: AppIntent {
    static let title: LocalizedStringResource = "Power On PC (Wake-on-LAN)"
    static let description = IntentDescription("Sends a Wake-on-LAN magic packet to turn on your paired PC.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "PC ID")
    var pcID: String?

    init() {}
    init(pcID: String?) { self.pcID = pcID }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard OrbitProEntitlement.cachedIsUnlocked else { throw OrbitProRequiredError() }
        return .result(dialog: IntentDialog(stringLiteral: try await OrbitWidgetPowerService.wakePC(id: pcID)))
    }
}

struct OrbitWidgetShutdownPCIntent: AppIntent {
    static let title: LocalizedStringResource = "Shut Down PC"
    static let description = IntentDescription("Safely shuts down your paired Windows PC over encrypted HTTPS.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "PC ID")
    var pcID: String?

    init() {}
    init(pcID: String?) { self.pcID = pcID }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard OrbitProEntitlement.cachedIsUnlocked else { throw OrbitProRequiredError() }
        return .result(dialog: IntentDialog(stringLiteral: try await OrbitWidgetPowerService.sendPowerAction("shutdown", id: pcID)))
    }
}

struct OrbitWidgetSleepPCIntent: AppIntent {
    static let title: LocalizedStringResource = "Put PC to Sleep"
    static let description = IntentDescription("Puts your paired Windows PC into sleep mode.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "PC ID")
    var pcID: String?

    init() {}
    init(pcID: String?) { self.pcID = pcID }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard OrbitProEntitlement.cachedIsUnlocked else { throw OrbitProRequiredError() }
        return .result(dialog: IntentDialog(stringLiteral: try await OrbitWidgetPowerService.sendPowerAction("sleep", id: pcID)))
    }
}
