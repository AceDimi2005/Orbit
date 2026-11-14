import Combine
import Foundation

// Display mode (Win+P) and default audio devices on the PC, for the iPhone/iPad, Mac and Apple TV apps.
// The PC side: `orbit_display_mode.py` (feature `displayMode`: GET/POST /api/display/mode) and
// `orbit_desktop.py` (feature `audioDefaults`: GET /api/audio/devices, POST /api/audio/default),
// PC Companion 4.6.0b4 and later. An older PC Companion answers 404, which the apps show as
// "update the PC Companion". Both need the encrypted connection.

// MARK: - Display mode

/// The four modes of Windows' Win+P panel, in its order. Raw values are the PC's API names.
enum OrbitDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case pcScreenOnly = "internal"
    case duplicate = "clone"
    case extend = "extend"
    case secondScreenOnly = "external"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pcScreenOnly: "PC screen only"
        case .duplicate: "Duplicate"
        case .extend: "Extend"
        case .secondScreenOnly: "Second screen only"
        }
    }

    var subtitle: String {
        switch self {
        case .pcScreenOnly: "Only the main display shows the desktop"
        case .duplicate: "Every display shows the same picture"
        case .extend: "The displays make one big desktop"
        case .secondScreenOnly: "Only the second display shows the desktop"
        }
    }

    var symbol: String {
        switch self {
        case .pcScreenOnly: "display"
        case .duplicate: "rectangle.on.rectangle"
        case .extend: "display.2"
        case .secondScreenOnly: "tv"
        }
    }
}

/// One display Windows can drive (connected, on or off).
struct OrbitPCDisplay: Decodable, Hashable, Sendable {
    var name: String
    var connection: String
    var active: Bool
    var builtIn: Bool
    var virtual: Bool

    var symbol: String {
        if virtual { return "rectangle.dashed" }
        if builtIn { return "laptopcomputer" }
        return connection == "HDMI" ? "tv" : "display"
    }

    var detail: String {
        let kind = virtual ? "Virtual display" : connection
        return "\(kind) · \(active ? "On" : "Off")"
    }
}

/// `GET /api/display/mode` (and the answer to a switch).
struct OrbitDisplayModeStatus: Decodable, Sendable {
    var available: Bool
    var reason: String?
    var mode: String?
    var displays: [OrbitPCDisplay]

    /// nil when Windows uses a layout outside the four modes (for example one set by hand in Settings).
    var currentMode: OrbitDisplayMode? { mode.flatMap(OrbitDisplayMode.init(rawValue:)) }

    /// Why the PC would refuse `mode` before asking Windows (the same rule as `orbit_display_mode.refusal`).
    func refusal(for mode: OrbitDisplayMode) -> String? {
        guard available, mode != .pcScreenOnly else { return nil }
        if displays.count < 2 { return "Needs a second display" }
        if mode == .secondScreenOnly, displays.filter({ !$0.virtual }).count < 2 { return "The only other display is virtual" }
        return nil
    }

    static let demo = OrbitDisplayModeStatus(available: true, reason: nil, mode: OrbitDisplayMode.extend.rawValue, displays: [
        OrbitPCDisplay(name: "DELL U2723QE", connection: "DisplayPort", active: true, builtIn: false, virtual: false),
        OrbitPCDisplay(name: "LG TV SSCR2", connection: "HDMI", active: true, builtIn: false, virtual: false)
    ])
}

private struct OrbitDisplayModeBody: Encodable { let mode: String }

// MARK: - Default audio devices

enum OrbitAudioFlow: String, CaseIterable, Identifiable, Sendable {
    case output, input

    var id: String { rawValue }
    var title: String { self == .output ? "Output" : "Input" }
    var symbol: String { self == .output ? "hifispeaker.fill" : "mic.fill" }
    var emptyText: String { self == .output ? "No playback device" : "No microphone" }
}

/// An active playback or recording device. `isDefault` is Windows' default device (console role);
/// `isDefaultCommunication` the one calls use, which Orbit moves too when it changes the default.
struct OrbitAudioDevice: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isDefault: Bool
    var isDefaultCommunication: Bool
}

/// `GET /api/audio/devices` (and the answer to a change).
struct OrbitAudioDevices: Decodable, Sendable {
    var outputs: [OrbitAudioDevice]
    var inputs: [OrbitAudioDevice]

    func devices(_ flow: OrbitAudioFlow) -> [OrbitAudioDevice] { flow == .output ? outputs : inputs }
    func current(_ flow: OrbitAudioFlow) -> OrbitAudioDevice? { devices(flow).first(where: \.isDefault) }

    static let demo = OrbitAudioDevices(outputs: [
        OrbitAudioDevice(id: "out-1", name: "Speakers (Realtek Audio)", isDefault: true, isDefaultCommunication: true),
        OrbitAudioDevice(id: "out-2", name: "Headset Earphone (Arctis Nova)", isDefault: false, isDefaultCommunication: false),
        OrbitAudioDevice(id: "out-3", name: "LG TV SSCR2 (NVIDIA High Definition Audio)", isDefault: false, isDefaultCommunication: false)
    ], inputs: [
        OrbitAudioDevice(id: "in-1", name: "Microphone (Arctis Nova)", isDefault: true, isDefaultCommunication: true),
        OrbitAudioDevice(id: "in-2", name: "Microphone (USB Webcam)", isDefault: false, isDefaultCommunication: false)
    ])

    /// The lists after `device` became the default for every role, for demo mode.
    func choosing(_ device: OrbitAudioDevice, flow: OrbitAudioFlow) -> OrbitAudioDevices {
        func mark(_ list: [OrbitAudioDevice]) -> [OrbitAudioDevice] {
            list.map { OrbitAudioDevice(id: $0.id, name: $0.name, isDefault: $0.id == device.id, isDefaultCommunication: $0.id == device.id) }
        }
        return flow == .output ? OrbitAudioDevices(outputs: mark(outputs), inputs: inputs) : OrbitAudioDevices(outputs: outputs, inputs: mark(inputs))
    }
}

private struct OrbitAudioDefaultBody: Encodable { let flow: String; let deviceID: String }

// MARK: - Requests

enum OrbitPCDisplayAudioAPI {
    static let displayModePath = "/api/display/mode"
    static let audioDevicesPath = "/api/audio/devices"
    static let audioDefaultPath = "/api/audio/default"

    /// nil: the PC Companion predates display modes (404).
    static func displayMode(_ client: OrbitAPIClient) async throws -> OrbitDisplayModeStatus? {
        do {
            let reply: OrbitDisplayModeStatus = try await client.get(displayModePath)
            return reply
        } catch let error as OrbitError where error.statusCode == 404 { return nil }
    }

    static func setDisplayMode(_ client: OrbitAPIClient, _ mode: OrbitDisplayMode) async throws -> OrbitDisplayModeStatus {
        // Windows can take a few seconds to bring displays up; the PC answers after the switch.
        try await client.withTimeout(30).send(displayModePath, body: OrbitDisplayModeBody(mode: mode.rawValue))
    }

    /// nil: the PC Companion predates default device selection (404).
    static func audioDevices(_ client: OrbitAPIClient) async throws -> OrbitAudioDevices? {
        do {
            let reply: OrbitAudioDevices = try await client.get(audioDevicesPath)
            return reply
        } catch let error as OrbitError where error.statusCode == 404 { return nil }
    }

    static func setDefault(_ client: OrbitAPIClient, flow: OrbitAudioFlow, deviceID: String) async throws -> OrbitAudioDevices {
        try await client.send(audioDefaultPath, body: OrbitAudioDefaultBody(flow: flow.rawValue, deviceID: deviceID))
    }
}

// MARK: - Screen state

/// What a display mode screen shows, for one PC at a time. `reset()` (another PC, the screen closing)
/// makes answers to requests still running land nowhere.
@MainActor
final class OrbitDisplayModeController: ObservableObject {
    @Published private(set) var status: OrbitDisplayModeStatus?
    /// The PC Companion predates display modes.
    @Published private(set) var olderAgent = false
    @Published private(set) var isLoading = false
    @Published private(set) var switching: OrbitDisplayMode?
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    private var lifetime = 0

    func refresh(_ makeClient: () throws -> OrbitAPIClient) async {
        guard !isLoading, switching == nil else { return }
        let current = lifetime
        isLoading = true
        defer { if current == lifetime { isLoading = false } }
        do {
            let client = try makeClient()
            let reply = try await OrbitPCDisplayAudioAPI.displayMode(client)
            guard current == lifetime else { return }
            olderAgent = reply == nil
            status = reply
            error = nil
        } catch {
            guard current == lifetime else { return }
            self.error = error.localizedDescription
        }
    }

    func select(_ mode: OrbitDisplayMode, _ makeClient: () throws -> OrbitAPIClient) async {
        guard switching == nil else { return }
        let current = lifetime
        let client: OrbitAPIClient
        do { client = try makeClient() } catch { self.error = error.localizedDescription; return }
        switching = mode
        error = nil
        message = nil
        defer { if current == lifetime { switching = nil } }
        do {
            let reply = try await OrbitPCDisplayAudioAPI.setDisplayMode(client, mode)
            guard current == lifetime else { return }
            status = reply
            message = "The PC switched to \(mode.title)."
        } catch {
            guard current == lifetime else { return }
            self.error = error.localizedDescription
        }
    }

    func showDemo() {
        if status == nil { status = .demo }
        olderAgent = false
    }

    func selectDemo(_ mode: OrbitDisplayMode) {
        status?.mode = mode.rawValue
        if var displays = status?.displays, displays.count >= 2 {
            displays[0].active = mode != .secondScreenOnly
            displays[1].active = mode != .pcScreenOnly
            status?.displays = displays
        }
        message = "Demo · switched to \(mode.title)."
    }

    func reset() {
        lifetime += 1
        status = nil; olderAgent = false; isLoading = false; switching = nil; error = nil; message = nil
    }
}

/// Default output and input for one PC at a time, like `OrbitDisplayModeController`.
@MainActor
final class OrbitAudioDefaultsController: ObservableObject {
    @Published private(set) var devices: OrbitAudioDevices?
    /// The PC Companion predates default device selection.
    @Published private(set) var olderAgent = false
    @Published private(set) var isLoading = false
    @Published private(set) var changing: OrbitAudioFlow?
    @Published private(set) var error: String?
    /// The lists are demo mode's sample devices.
    @Published private(set) var showsDemo = false
    private var lifetime = 0
    private var refreshedAt: Date?

    /// `maxAge`: skip the request when the last answer is newer than this (for screens that poll).
    func refresh(_ makeClient: () throws -> OrbitAPIClient, maxAge: TimeInterval = 0) async {
        guard !isLoading, changing == nil else { return }
        if maxAge > 0, let refreshedAt, Date().timeIntervalSince(refreshedAt) < maxAge { return }
        let current = lifetime
        isLoading = true
        defer { if current == lifetime { isLoading = false } }
        do {
            let client = try makeClient()
            let reply = try await OrbitPCDisplayAudioAPI.audioDevices(client)
            guard current == lifetime else { return }
            olderAgent = reply == nil
            devices = reply
            showsDemo = false
            refreshedAt = Date()
            error = nil
        } catch {
            guard current == lifetime else { return }
            self.error = error.localizedDescription
        }
    }

    func choose(_ device: OrbitAudioDevice, flow: OrbitAudioFlow, _ makeClient: () throws -> OrbitAPIClient) async {
        guard changing == nil, !device.isDefault else { return }
        let current = lifetime
        let client: OrbitAPIClient
        do { client = try makeClient() } catch { self.error = error.localizedDescription; return }
        changing = flow
        error = nil
        defer { if current == lifetime { changing = nil } }
        do {
            let reply = try await OrbitPCDisplayAudioAPI.setDefault(client, flow: flow, deviceID: device.id)
            guard current == lifetime else { return }
            devices = reply
            refreshedAt = Date()
        } catch {
            guard current == lifetime else { return }
            self.error = error.localizedDescription
        }
    }

    func showDemo() {
        if devices == nil || !showsDemo { devices = .demo; showsDemo = true }
        olderAgent = false
    }

    func chooseDemo(_ device: OrbitAudioDevice, flow: OrbitAudioFlow) {
        devices = devices?.choosing(device, flow: flow)
    }

    func reset() {
        lifetime += 1
        devices = nil; olderAgent = false; isLoading = false; changing = nil; error = nil; refreshedAt = nil; showsDemo = false
    }
}
