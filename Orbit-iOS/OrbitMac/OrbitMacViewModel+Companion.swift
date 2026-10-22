import AppKit
import Foundation

// MARK: - Orbit Companion 5

/// What Orbit Companion 5 adds: capabilities, power timers and keep-awake, devices, the
/// microphone and default output, the game library and the activity log. Older companions
/// answer 404; every call then leaves its state empty and the UI simply doesn't offer it.
extension OrbitMacViewModel {
    func has(_ feature: String) -> Bool { capabilities?.has(feature) == true }

    func refreshCapabilities() async {
        guard !isDemoMode, metrics.isOnline else { return }
        let version = generation
        let fetched: OrbitCapabilities? = try? await client().get("/api/capabilities")
        guard version == generation else { return }
        capabilities = fetched
    }

    // MARK: Power

    func refreshPower() async {
        guard !isDemoMode, metrics.isOnline else { return }
        if capabilities == nil { await refreshCapabilities() }
        guard has("power.timer") || has("power.countdown") else { power = nil; return }
        let version = generation
        do {
            let state: OrbitPowerState = try await client().get("/api/power")
            guard version == generation else { return }
            power = state
            powerFetchedAt = Date()
            powerError = nil
        } catch {
            guard version == generation else { return }
            powerError = error.localizedDescription
        }
    }

    /// Seconds left on a timer or keep-awake, counted down locally between refreshes.
    func remaining(_ seconds: Int?, at date: Date = Date()) -> Int? {
        seconds.map { max(0, $0 - Int(date.timeIntervalSince(powerFetchedAt))) }
    }

    func setPowerTimer(_ choice: OrbitPowerTimerChoice, action: String) async {
        await powerRequest {
            let _: OrbitPowerTimer = try await $0.send("/api/power/timer", body: choice.body(action: action))
        }
    }

    /// Stops a timer or Windows' shutdown countdown, whichever is pending.
    func cancelPendingPower() async {
        await powerRequest { _ = try await $0.data("/api/power/cancel", method: "POST") }
        if powerError == nil { localCountdown = nil }
    }

    func setKeepAwake(minutes: Int?, display: Bool = false) async {
        await powerRequest {
            let _: OrbitKeepAwake = try await $0.send("/api/power/keep-awake", method: "PUT", body: OrbitKeepAwakeRequest(minutes: minutes, display: display))
        }
    }

    func stopKeepAwake() async {
        await powerRequest { _ = try await $0.data("/api/power/keep-awake", method: "DELETE") }
    }

    func setPowerPlan(_ plan: OrbitPowerPlan) async {
        guard !plan.active else { return }
        await powerRequest {
            let _: OrbitPowerPlansReply = try await $0.send("/api/power/plan", method: "PUT", body: OrbitPowerPlanRequest(id: plan.id))
        }
    }

    private func powerRequest(_ work: (OrbitAPIClient) async throws -> Void) async {
        guard !isDemoMode else { return }
        do {
            try await work(client())
            powerError = nil
        } catch {
            powerError = error.localizedDescription
            statusBanner = error.localizedDescription
        }
        await refreshPower()
    }

    // MARK: Devices

    func refreshDevices() async {
        guard !isDemoMode, metrics.isOnline, !isLoadingDevices else { return }
        if capabilities == nil { await refreshCapabilities() }
        guard has("devices") else { devices = []; return }
        let version = generation
        isLoadingDevices = true
        defer { if version == generation { isLoadingDevices = false } }
        do {
            let list: OrbitDeviceList = try await client().get("/api/devices")
            guard version == generation else { return }
            devices = list.devices.sorted { ($0.current ? 0 : 1, $0.legacy ? 1 : 0, $0.name.lowercased()) < ($1.current ? 0 : 1, $1.legacy ? 1 : 0, $1.name.lowercased()) }
            devicesError = nil
        } catch {
            guard version == generation else { return }
            devicesError = (error as? OrbitError)?.statusCode == 403
                ? "Only devices allowed to manage the PC can see this list."
                : error.localizedDescription
        }
    }

    func revoke(_ device: OrbitDevice) async {
        guard !isDemoMode else { return }
        do {
            _ = try await client().data("/api/devices/\(device.id)", method: "DELETE")
            devices.removeAll { $0.id == device.id }
        } catch {
            devicesError = error.localizedDescription
        }
        await refreshDevices()
    }

    // MARK: Sound

    func refreshMicrophone() async {
        guard !isDemoMode, metrics.isOnline else { return }
        if capabilities == nil { await refreshCapabilities() }
        guard has("audio.microphone") else { microphone = nil; return }
        let version = generation
        let state: OrbitMicrophoneState? = try? await client().get("/api/audio/microphone")
        guard version == generation else { return }
        microphone = state
    }

    func setMicrophoneMuted(_ muted: Bool) async {
        guard !isDemoMode else { return }
        microphone?.muted = muted
        do {
            let reply: OrbitMicrophoneReply = try await client().send("/api/audio/microphone", body: OrbitMicrophoneRequest(muted: muted))
            microphone?.muted = reply.muted
        } catch {
            audioError = error.localizedDescription
            await refreshMicrophone()
        }
    }

    func makeDefaultOutput(_ output: MacAudioOutput) async {
        guard !isDemoMode, output.isDefault != true else { return }
        do {
            let _: MacSimpleStatus = try await client().send("/api/audio/default", body: OrbitDefaultOutputRequest(deviceID: output.id))
            audioStatus = "\(output.name) is now the default output."
        } catch {
            audioError = error.localizedDescription
        }
        await refreshAudio()
    }

    // MARK: Library

    func refreshLibrary(rescan: Bool = false) async {
        guard !isDemoMode, metrics.isOnline, !isLoadingLibrary else { return }
        if capabilities == nil { await refreshCapabilities() }
        guard has("library") else { library = nil; return }
        let version = generation
        isLoadingLibrary = true
        defer { if version == generation { isLoadingLibrary = false } }
        do {
            let fetched: OrbitLibrary = rescan
                ? try await client().send("/api/library/rescan", body: OrbitEmptyBody())
                : try await client().get("/api/library")
            guard version == generation else { return }
            library = fetched
        } catch {
            guard version == generation else { return }
            statusBanner = "Could not read the game library: \(error.localizedDescription)"
        }
    }

    /// The game's cover from the PC (never from a store's website), cached for this PC.
    func cover(for game: OrbitLibraryGame) async -> NSImage? {
        guard let id = game.coverID, !isDemoMode else { return nil }
        if let cached = libraryCovers[id] { return cached }
        let version = generation
        guard let data = try? await client().data("/api/library/covers/\(id)"), version == generation,
              let image = NSImage(data: data) else { return nil }
        libraryCovers[id] = image
        return image
    }

    func launch(_ game: OrbitLibraryGame) async {
        if isDemoMode { statusBanner = "The demo can't start games."; return }
        do {
            let _: MacSimpleStatus = try await client().send("/api/library/\(game.id)/launch", body: OrbitEmptyBody())
            statusBanner = "Starting \(game.title) on \(selectedPCName)…"
        } catch {
            statusBanner = "Could not start \(game.title): \(error.localizedDescription)"
        }
    }

    // MARK: Activity

    func refreshActivity() async {
        guard !isDemoMode, metrics.isOnline else { return }
        if capabilities == nil { await refreshCapabilities() }
        guard has("activity") else { activity = []; return }
        let version = generation
        do {
            let page: OrbitActivityPage = try await client().get("/api/activity", query: [URLQueryItem(name: "limit", value: "100")])
            guard version == generation else { return }
            activity = page.entries
            activityError = nil
        } catch {
            guard version == generation else { return }
            activityError = (error as? OrbitError)?.statusCode == 403
                ? "Only devices allowed to manage the PC can see its activity."
                : error.localizedDescription
        }
    }
}

struct OrbitEmptyBody: Encodable {}
struct OrbitPowerPlansReply: Decodable { var plans: [OrbitPowerPlan] }
struct OrbitMicrophoneReply: Decodable { var muted: Bool }
