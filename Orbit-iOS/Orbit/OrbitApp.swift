import AppIntents
import SwiftUI

@main
struct OrbitApp: App {
    /// APNs token and notification taps/actions for PC alerts (`OrbitNotifications.swift`).
    @UIApplicationDelegateAdaptor(OrbitAppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["ORBIT_IDENTITY_SELFTEST"] { OrbitIdentitySelfTest.run(mode: mode) }
        if let mode = ProcessInfo.processInfo.environment["ORBIT_INTENTS_SELFTEST"] { OrbitIntentsSelfTest.run(mode: mode) }
        #endif
        OrbitIntentClient.startMirroringDemoMode()
        OrbitShortcutsParameters.start()
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
        // Free actions (OrbitPCIntents.swift, OrbitPresentationIntents.swift). Apple allows 10 App
        // Shortcuts; 1 is left. Keep every App Shortcut intent out of the widget
        // extension (the Pro ones above live in Shared/OrbitPowerIntents.swift): iOS runs an intent
        // that both targets compile in the widget process while Orbit is closed, where App Shortcuts
        // fail ("Couldn't find AppShortcutsProvider", "Unable to run App Shortcut").
        AppShortcut(
            intent: LockPCIntent(),
            phrases: [
                "Lock my PC with \(.applicationName)",
                "Lock my computer in \(.applicationName)",
                "Lock \(\.$pc) with \(.applicationName)"
            ],
            shortTitle: "Lock PC",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: GetPCStatusIntent(),
            phrases: [
                "How is my PC doing in \(.applicationName)",
                "Check on my PC with \(.applicationName)",
                "Get my PC status in \(.applicationName)",
                "How is \(\.$pc) doing in \(.applicationName)"
            ],
            shortTitle: "PC Status",
            systemImageName: "desktopcomputer"
        )
        AppShortcut(
            intent: GetPCReadingIntent(),
            phrases: [
                "What's my PC's \(\.$reading) in \(.applicationName)",
                "Check my PC's \(\.$reading) with \(.applicationName)",
                "How hot is my PC in \(.applicationName)"
            ],
            shortTitle: "PC Reading",
            systemImageName: "thermometer.medium"
        )
        AppShortcut(
            intent: SleepWhenDownloadsFinishIntent(),
            phrases: [
                "Sleep my PC when downloads finish with \(.applicationName)",
                "Put my PC to sleep after its downloads in \(.applicationName)"
            ],
            shortTitle: "Sleep After Downloads",
            systemImageName: "arrow.down.circle"
        )
        // Presentation remote: "Next slide with Orbit" runs the default action (next); the spoken
        // action ("Black screen with Orbit", "Previous slide with Orbit") picks another one.
        AppShortcut(
            intent: PresentationControlIntent(),
            phrases: [
                "Next slide with \(.applicationName)",
                "Next slide in \(.applicationName)",
                "\(\.$action) with \(.applicationName)",
                "\(\.$action) in my presentation with \(.applicationName)"
            ],
            shortTitle: "Next Slide",
            systemImageName: "rectangle.inset.filled.and.person.filled"
        )
    }
}

#if DEBUG
/// `ORBIT_IDENTITY_SELFTEST=create|tls|cleanup` (in the simulator pass it as
/// `SIMCTL_CHILD_ORBIT_IDENTITY_SELFTEST`) checks the per-host Sunshine client identity in the iOS
/// Keychain and exits: `create` makes one and prints its certificate, `tls` reloads it in a new
/// process and authenticates with it to `ORBIT_TLS_URL` (server certificate in
/// `ORBIT_TLS_SERVER_CERT_B64`), `cleanup` deletes it.
enum OrbitIdentitySelfTest {
    private static let referenceKey = "orbit.selftest.identity"

    static func run(mode: String) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await perform(mode: mode)
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func storedReference() -> MoonlightIdentityReference? {
        UserDefaults.standard.data(forKey: referenceKey).flatMap { try? JSONDecoder().decode(MoonlightIdentityReference.self, from: $0) }
    }

    private static func perform(mode: String) async {
        let environment = ProcessInfo.processInfo.environment
        switch mode {
        case "create":
            do {
                let created = try MoonlightIdentityStore.createForPairing()
                UserDefaults.standard.set(try JSONEncoder().encode(created.reference), forKey: referenceKey)
                print("created \(created.reference.id) · TLS identity \(created.identity.secIdentity != nil)")
                print(created.identity.certificatePEM)
            } catch {
                print("create failed: \(error)")
            }
        case "tls":
            guard let reference = storedReference() else { print("no stored reference"); return }
            do {
                let identity = try MoonlightIdentityStore.identity(for: reference)
                print("reloaded \(reference.id) · same certificate \(identity.certificateDER == reference.certificateDER) · TLS identity \(identity.secIdentity != nil)")
                let shared = try MoonlightIdentityStore.loadOrCreate()
                print("shared identity is a different certificate: \(shared.certificateDER != reference.certificateDER)")
                if let url = environment["ORBIT_TLS_URL"].flatMap(URL.init(string:)),
                   let serverDER = environment["ORBIT_TLS_SERVER_CERT_B64"].flatMap({ Data(base64Encoded: $0) }) {
                    let endpoints = try MoonlightEndpoints.standard(host: url.host ?? "127.0.0.1", httpPort: url.port ?? 47989, httpsPort: url.port ?? 47984)
                    let transport = MoonlightTransport(endpoints: endpoints, uniqueID: "selftest0000beef", deviceName: "Orbit self-test",
                                                       serverCertificate: serverDER, identity: identity.secIdentity)
                    let reply = try await transport.request(secure: true, path: url.path.isEmpty ? "/serverinfo" : url.path, query: [], timeout: 10)
                    print("TLS with the per-host client certificate: HTTP 200 · \(String(decoding: reply.prefix(80), as: UTF8.self))")
                }
            } catch {
                print("tls failed: \(error)")
            }
        case "cleanup":
            guard let reference = storedReference() else { print("no stored reference"); return }
            MoonlightIdentityStore.remove(reference)
            UserDefaults.standard.removeObject(forKey: referenceKey)
            print("removed \(reference.id) · reload \((try? MoonlightIdentityStore.identity(for: reference)) == nil ? "fails as expected" : "STILL WORKS")")
        default:
            print("unknown mode \(mode)")
        }
    }
}
#endif
