import SwiftUI
import UIKit

/// What Orbit Companion 5 adds on the PC: power timers and keep-awake, the devices that may use
/// it, its game library, the microphone and default output, and its activity log. Older
/// companions answer 404; everything then stays empty and the UI doesn't offer it.
@MainActor
final class PCCompanion: ObservableObject {
    @Published private(set) var capabilities: OrbitCapabilities?
    @Published private(set) var power: OrbitPowerState?
    /// When `power` arrived, so countdowns tick between refreshes.
    @Published private(set) var powerFetchedAt = Date()
    @Published private(set) var devices: [OrbitDevice] = []
    @Published private(set) var isLoadingDevices = false
    @Published var devicesError: String?
    @Published private(set) var library: OrbitLibrary?
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var activity: [OrbitActivityEntry] = []
    @Published var activityError: String?
    @Published private(set) var microphone: OrbitMicrophoneState?
    @Published private(set) var outputs: [Output] = []
    @Published private(set) var canSwitchOutput = false
    /// The last thing that went wrong, for a short message where the action was.
    @Published var lastError: String?

    struct Output: Decodable, Identifiable, Equatable {
        var id: String
        var name: String
        var isDefault: Bool?
    }

    private struct OutputsReply: Decodable {
        var devices: [Output]
        var defaultSwitchAvailable: Bool?
    }

    private weak var vm: OrbitViewModel?
    private var connection = ""
    private var covers: [String: UIImage] = [:]

    func attach(_ vm: OrbitViewModel) { self.vm = vm }

    /// Forget everything when the PC or its connection changes.
    func reset(for key: String) {
        guard key != connection else { return }
        connection = key
        capabilities = nil; power = nil; devices = []; devicesError = nil; library = nil
        activity = []; activityError = nil; microphone = nil; outputs = []; canSwitchOutput = false
        lastError = nil; covers = [:]
    }

    func has(_ feature: String) -> Bool { capabilities?.has(feature) == true }

    private var client: OrbitAPIClient? {
        guard let vm, vm.metrics.isOnline, !vm.isDemoMode, vm.hasSecureConnection else { return nil }
        return try? vm.companionClient()
    }

    /// Runs a request only if the answer still belongs to the current connection.
    private func current<T>(_ work: (OrbitAPIClient) async throws -> T) async throws -> T? {
        guard let client else { return nil }
        let key = connection
        let value = try await work(client)
        return key == connection ? value : nil
    }

    func refreshCapabilities() async {
        guard capabilities == nil else { return }
        capabilities = try? await current { try await $0.get("/api/capabilities") as OrbitCapabilities }
    }

    // MARK: Power

    func refreshPower() async {
        await refreshCapabilities()
        guard has("power.timer") || has("power.countdown") else { power = nil; return }
        if let state: OrbitPowerState = try? await current({ try await $0.get("/api/power") }) {
            power = state
            powerFetchedAt = Date()
        }
    }

    func remaining(_ seconds: Int?, at date: Date = Date()) -> Int? {
        seconds.map { max(0, $0 - Int(date.timeIntervalSince(powerFetchedAt))) }
    }

    func setTimer(_ choice: OrbitPowerTimerChoice, action: String) async {
        await powerRequest { let _: OrbitPowerTimer = try await $0.send("/api/power/timer", body: choice.body(action: action)) }
    }

    func cancelPending() async {
        await powerRequest { _ = try await $0.data("/api/power/cancel", method: "POST") }
    }

    func keepAwake(minutes: Int?) async {
        await powerRequest {
            let _: OrbitKeepAwake = try await $0.send("/api/power/keep-awake", method: "PUT", body: OrbitKeepAwakeRequest(minutes: minutes, display: false))
        }
    }

    func stopKeepAwake() async {
        await powerRequest { _ = try await $0.data("/api/power/keep-awake", method: "DELETE") }
    }

    func setPlan(_ plan: OrbitPowerPlan) async {
        guard !plan.active else { return }
        await powerRequest { let _: PlansReply = try await $0.send("/api/power/plan", method: "PUT", body: OrbitPowerPlanRequest(id: plan.id)) }
    }

    private struct PlansReply: Decodable { var plans: [OrbitPowerPlan] }

    private func powerRequest(_ work: (OrbitAPIClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await work(client)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshPower()
    }

    // MARK: Devices and activity

    func refreshDevices() async {
        await refreshCapabilities()
        guard has("devices"), !isLoadingDevices else { return }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        do {
            guard let list: OrbitDeviceList = try await current({ try await $0.get("/api/devices") }) else { return }
            devices = list.devices.sorted { ($0.current ? 0 : 1, $0.legacy ? 1 : 0, $0.name.lowercased()) < ($1.current ? 0 : 1, $1.legacy ? 1 : 0, $1.name.lowercased()) }
            devicesError = nil
        } catch {
            devicesError = (error as? OrbitError)?.statusCode == 403
                ? "Only devices allowed to manage the PC can see this list."
                : error.localizedDescription
        }
    }

    func revoke(_ device: OrbitDevice) async {
        do {
            _ = try await current { try await $0.data("/api/devices/\(device.id)", method: "DELETE") }
            devices.removeAll { $0.id == device.id }
        } catch {
            devicesError = error.localizedDescription
        }
        await refreshDevices()
    }

    func refreshActivity() async {
        await refreshCapabilities()
        guard has("activity") else { return }
        do {
            guard let page: OrbitActivityPage = try await current({
                try await $0.get("/api/activity", query: [URLQueryItem(name: "limit", value: "100")])
            }) else { return }
            activity = page.entries
            activityError = nil
        } catch {
            activityError = (error as? OrbitError)?.statusCode == 403
                ? "Only devices allowed to manage the PC can see its activity."
                : error.localizedDescription
        }
    }

    // MARK: Sound

    func refreshSound() async {
        await refreshCapabilities()
        if has("audio.microphone") {
            microphone = try? await current { try await $0.get("/api/audio/microphone") as OrbitMicrophoneState }
        }
        if has("audio.default"), let reply: OutputsReply = try? await current({ try await $0.get("/api/audio/outputs") }) {
            outputs = reply.devices
            canSwitchOutput = reply.defaultSwitchAvailable == true
        }
    }

    func setMicrophoneMuted(_ muted: Bool) async {
        microphone?.muted = muted
        do {
            _ = try await current { try await $0.send("/api/audio/microphone", body: OrbitMicrophoneRequest(muted: muted)) as OrbitMicrophoneMuteReply }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshSound()
    }

    func makeDefault(_ output: Output) async {
        do {
            _ = try await current { try await $0.send("/api/audio/default", body: OrbitDefaultOutputRequest(deviceID: output.id)) as OrbitStatusReply }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshSound()
    }

    // MARK: Library

    func refreshLibrary(rescan: Bool = false) async {
        await refreshCapabilities()
        guard has("library"), !isLoadingLibrary else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        let fetched: OrbitLibrary? = try? await current {
            rescan ? try await $0.send("/api/library/rescan", body: OrbitEmptyRequest()) : try await $0.get("/api/library")
        }
        if let fetched { library = fetched }
    }

    /// The game's cover from the PC (never from a store's website), cached for this PC.
    func cover(for game: OrbitLibraryGame) async -> UIImage? {
        guard let id = game.coverID else { return nil }
        if let cached = covers[id] { return cached }
        guard let data = try? await current({ try await $0.data("/api/library/covers/\(id)") }),
              let image = UIImage(data: data) else { return nil }
        covers[id] = image
        return image
    }

    func launch(_ game: OrbitLibraryGame) async -> Bool {
        do {
            _ = try await current { try await $0.send("/api/library/\(game.id)/launch", body: OrbitEmptyRequest()) as OrbitStatusReply }
            lastError = nil
            return true
        } catch {
            lastError = "Couldn't start \(game.title): \(error.localizedDescription)"
            return false
        }
    }
}

struct OrbitEmptyRequest: Encodable {}
struct OrbitStatusReply: Decodable { var status: String }
struct OrbitMicrophoneMuteReply: Decodable { var muted: Bool }
