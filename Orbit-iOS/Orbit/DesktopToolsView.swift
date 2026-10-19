import SwiftUI
import UIKit

private struct ClipboardPayload: Decodable {
    let text: String
    let available: Bool
}

private struct ClipboardWritePayload: Encodable { let text: String }
private struct DesktopActionReply: Decodable { let status: String }

/// Clipboard access always follows a visible user action. There is no timer,
/// background pasteboard read, or automatic PC-to-phone synchronization.
struct ClipboardView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var text = ""
    @State private var isBusy = false
    @State private var status: String?
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    private var fitsLimit: Bool { text.utf16.count * 2 + 2 <= 1_048_576 && !text.contains("\0") }
    private var canUsePC: Bool { !vm.isDemoMode && vm.metrics.isOnline && !isBusy }

    @Environment(\.orbitTheme) private var theme

    var body: some View {
        List {
            Section("Clipboard Text") {
                TextEditor(text: $text)
                    .frame(minHeight: 170, maxHeight: 280)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Clipboard text")
                HStack {
                    Text("\(text.count.formatted()) chars")
                    Spacer()
                    if !text.isEmpty {
                        Button("Clear", role: .destructive) { text = ""; status = nil }
                            .disabled(isBusy)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .orbitRow()

            Section {
                HStack(spacing: 10) {
                    transferButton("Pull from PC", icon: "arrow.down.doc.fill", tint: theme.accent, enabled: canUsePC) { readPC() }
                    transferButton(text.isEmpty ? "Clear PC" : "Push to PC", icon: "arrow.up.doc.fill", tint: .mint, enabled: canUsePC && fitsLimit) { sendToPC() }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            } header: {
                Text("Quick Transfer")
            } footer: {
                Text("Clipboard access always follows a tap. Orbit never reads or syncs the clipboard in the background.")
            }
            .orbitRow()

            Section("iPhone Clipboard") {

                HStack {
                    Label("Paste from iPhone", systemImage: "iphone")
                    Spacer()
                    PasteButton(payloadType: String.self) { values in
                        text = values.joined(separator: "\n")
                        status = "Pasted from iPhone."
                        error = nil
                    }
                    .labelStyle(.titleOnly)
                    .disabled(isBusy)
                }

                Button {
                    UIPasteboard.general.string = text
                    status = "Copied to iPhone."
                    error = nil
                } label: {
                    Label("Copy to iPhone Clipboard", systemImage: "doc.on.doc.fill")
                }
                .disabled(text.isEmpty || !fitsLimit || isBusy)
            }
            .orbitRow()

            if isBusy { Section { HStack { ProgressView(); Text("Syncing…").font(.subheadline) } }.orbitRow() }
            if let status { Section { Label(status, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.mint) }.orbitRow(tint: .mint) }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange) }.orbitRow(tint: .orange) }
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
        .navigationTitle("Clipboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Pull from PC", systemImage: "arrow.down.doc") { readPC() }
                        .disabled(!canUsePC)
                    Button("Push to PC", systemImage: "arrow.up.doc") { sendToPC() }
                        .disabled(!canUsePC || !fitsLimit)
                    Button("Copy to iPhone", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                        status = "Copied to iPhone."
                    }
                    .disabled(text.isEmpty)
                    Divider()
                    Button("Clear Editor", systemImage: "trash", role: .destructive) {
                        text = ""; status = nil
                    }
                    .disabled(text.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onChange(of: vm.connectionID) { _, _ in clearScreen() }
        .onDisappear { clearScreen() }
    }

    private func transferButton(_ title: String, icon: String, tint: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            OrbitHaptics.tap()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.orbitPressable)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private func readPC() {
        guard canUsePC else { return }
        let generation = vm.connectionID
        let client: OrbitAPIClient
        do { client = try vm.companionClient() }
        catch { self.error = error.localizedDescription; return }
        isBusy = true; status = nil; error = nil
        operation = Task { @MainActor in
            do {
                let result: ClipboardPayload = try await client.get("/api/clipboard")
                guard !Task.isCancelled, generation == vm.connectionID else { return }
                text = result.text
                status = result.available ? "PC text loaded. Tap Copy to iPhone to put it on your phone's clipboard." : "The PC clipboard does not contain text."
            } catch {
                guard !Task.isCancelled, generation == vm.connectionID else { return }
                self.error = error.localizedDescription
            }
            if generation == vm.connectionID { isBusy = false; operation = nil }
        }
    }

    private func sendToPC() {
        guard canUsePC, fitsLimit else { return }
        let generation = vm.connectionID
        let payload = ClipboardWritePayload(text: text)
        let client: OrbitAPIClient
        do { client = try vm.companionClient() }
        catch { self.error = error.localizedDescription; return }
        isBusy = true; status = nil; error = nil
        operation = Task { @MainActor in
            do {
                let _: DesktopActionReply = try await client.send("/api/clipboard", method: "PUT", body: payload)
                guard !Task.isCancelled, generation == vm.connectionID else { return }
                status = payload.text.isEmpty ? "PC clipboard cleared." : "Text sent to the PC clipboard."
            } catch {
                guard !Task.isCancelled, generation == vm.connectionID else { return }
                self.error = error.localizedDescription
            }
            if generation == vm.connectionID { isBusy = false; operation = nil }
        }
    }

    private func clearScreen() {
        operation?.cancel(); operation = nil
        text = ""; status = nil; error = nil; isBusy = false
    }
}

private struct AudioMixerSession: Codable, Identifiable {
    let id: String
    let pid: Int
    let name: String
    var volume: Double
    var isMuted: Bool
    var processCreateTime: Double?
    var outputDeviceID: String?
    var outputDeviceName: String?
}

private struct AudioOutputDevice: Decodable, Identifiable { let id: String; let name: String }
private struct AudioOutputsReply: Decodable {
    let devices: [AudioOutputDevice]
    let routingAvailable: Bool
    let routingUnavailableReason: String?
}
private struct AudioRouteChange: Encodable { let id: String; let expectedCreateTime: Double; let deviceID: String }
private struct AudioRouteReply: Decodable { let status: String; let pid: Int; let deviceID: String }

private struct AudioSessionsReply: Decodable {
    let sessions: [AudioMixerSession]
    let available: Bool
}

private struct AudioSessionChange: Encodable {
    let id: String
    var volume: Double?
    var isMuted: Bool?
}

private struct AudioSessionReply: Decodable {
    let status: String
    let session: AudioMixerSession
}

/// One worker serializes changes across sessions. Pending slider positions are
/// replaced with the newest value; mute and volume updates merge instead of
/// cancelling one another. Each request captures the original PC's TLS client.
@MainActor
private final class AudioMixerModel: ObservableObject {
    @Published private(set) var sessions: [AudioMixerSession] = []
    @Published private(set) var isLoading = false
    @Published private(set) var sendingIDs: Set<String> = []
    @Published private(set) var error: String?
    @Published private(set) var updated: Date?
    @Published private(set) var outputs: [AudioOutputDevice] = []
    @Published private(set) var routingAvailable = false
    @Published private(set) var routingReason: String?
    @Published private(set) var routingSessionID: String?
    @Published private(set) var routingStatus: String?
    private var routingTask: Task<Void, Never>?
    private struct Command {
        var body: AudioSessionChange
        let generation: Int
        var revision: Int
        let send: (AudioSessionChange) async throws -> AudioSessionReply
    }
    private var pending: [String: Command] = [:]
    private var order: [String] = []
    private var revisions: [String: Int] = [:]
    private var changed: [String: Date] = [:]
    private var dragging: Set<String> = []
    private var worker: Task<Void, Never>?
    private var lifetime = 0

    func refresh(_ vm: OrbitViewModel) async {
        if vm.isDemoMode {
            if sessions.isEmpty {
                sessions = [
                    AudioMixerSession(id: "demo-1", pid: 4100, name: "Example Game", volume: 80, isMuted: false, processCreateTime: 1, outputDeviceID: "out-1", outputDeviceName: "Speakers (Realtek Audio)"),
                    AudioMixerSession(id: "demo-2", pid: 5210, name: "Voice Chat", volume: 65, isMuted: false, processCreateTime: 2, outputDeviceID: "out-2", outputDeviceName: "Headset Earphone"),
                    AudioMixerSession(id: "demo-3", pid: 6320, name: "Music Player", volume: 45, isMuted: false, processCreateTime: 3, outputDeviceID: "out-1", outputDeviceName: "Speakers (Realtek Audio)")
                ]
                outputs = [
                    AudioOutputDevice(id: "out-1", name: "Speakers (Realtek Audio)"),
                    AudioOutputDevice(id: "out-2", name: "Headset Earphone")
                ]
                routingAvailable = true
                updated = Date()
            }
            return
        }
        guard !isLoading, vm.metrics.isOnline else { return }
        let generation = vm.connectionID
        let currentLifetime = lifetime
        let initialRevisions = revisions
        isLoading = true
        defer { if lifetime == currentLifetime { isLoading = false } }
        do {
            let client = try vm.companionClient()
            let reply: AudioSessionsReply = try await client.get("/api/audio/sessions")
            guard !Task.isCancelled, generation == vm.connectionID, lifetime == currentLifetime else { return }
            guard reply.available else {
                error = "Windows audio sessions are unavailable. Check the active playback device."
                return
            }
            var seen = Set<String>()
            sessions = reply.sessions.filter {
                $0.volume.isFinite && (0...100).contains($0.volume) && seen.insert($0.id).inserted
            }.map { fetched in
                guard let local = sessions.first(where: { $0.id == fetched.id }) else { return fetched }
                let keepLocal = dragging.contains(fetched.id) || sendingIDs.contains(fetched.id)
                    || revisions[fetched.id] != initialRevisions[fetched.id]
                    || Date().timeIntervalSince(changed[fetched.id] ?? .distantPast) < 1.5
                guard keepLocal else { return fetched }
                var result = fetched
                result.volume = local.volume; result.isMuted = local.isMuted
                return result
            }
            updated = Date()
            if sendingIDs.isEmpty { error = nil }
            do {
                let available: AudioOutputsReply = try await client.get("/api/audio/outputs")
                guard !Task.isCancelled, generation == vm.connectionID, lifetime == currentLifetime else { return }
                outputs = available.devices
                routingAvailable = available.routingAvailable
                routingReason = available.routingUnavailableReason
            } catch {
                guard !Task.isCancelled, generation == vm.connectionID, lifetime == currentLifetime else { return }
                routingAvailable = false
                routingReason = "Per-app output selection is unavailable. Update Orbit Agent, or use Windows Settings → System → Sound → Volume mixer."
            }
        } catch {
            guard !Task.isCancelled, generation == vm.connectionID, lifetime == currentLifetime else { return }
            self.error = error.localizedDescription
        }
    }

    func setDragging(_ id: String, _ active: Bool) {
        if active { dragging.insert(id) } else { dragging.remove(id); changed[id] = Date() }
    }

    func setVolume(_ vm: OrbitViewModel, id: String, volume: Double) {
        guard volume.isFinite else { return }
        let value = min(100, max(0, volume)).rounded()
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].volume = value
        enqueue(vm, id: id, volume: value)
    }

    func toggleMute(_ vm: OrbitViewModel, id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].isMuted.toggle()
        enqueue(vm, id: id, muted: sessions[index].isMuted)
    }

    func route(_ vm: OrbitViewModel, session: AudioMixerSession, outputID: String) {
        guard routingAvailable, routingSessionID == nil, !vm.isDemoMode, vm.metrics.isOnline,
              session.pid > 0, let created = session.processCreateTime, created.isFinite, created > 0 else { return }
        let generation = vm.connectionID, currentLifetime = lifetime
        let client: OrbitAPIClient
        do { client = try vm.companionClient() }
        catch { self.error = error.localizedDescription; return }
        routingSessionID = session.id; routingStatus = nil; error = nil
        let body = AudioRouteChange(id: session.id, expectedCreateTime: created, deviceID: outputID)
        routingTask = Task { [weak self, weak vm] in
            guard let self, let vm else { return }
            defer { if self.lifetime == currentLifetime { self.routingSessionID = nil; self.routingTask = nil } }
            do {
                let _: AudioRouteReply = try await client.send("/api/audio/route", body: body)
                guard !Task.isCancelled, generation == vm.connectionID, self.lifetime == currentLifetime else { return }
                self.routingStatus = "Windows saved this app's output preference. Some apps need playback or the app restarted before audio moves."
                await self.refresh(vm)
            } catch {
                guard !Task.isCancelled, generation == vm.connectionID, self.lifetime == currentLifetime else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func enqueue(_ vm: OrbitViewModel, id: String, volume: Double? = nil, muted: Bool? = nil) {
        guard !vm.isDemoMode, vm.metrics.isOnline else { return }
        do {
            let client = try vm.companionClient()
            let revision = (revisions[id] ?? 0) + 1
            revisions[id] = revision; changed[id] = Date()
            if var command = pending[id] {
                if let volume { command.body.volume = volume }
                if let muted { command.body.isMuted = muted }
                command.revision = revision
                pending[id] = command
            } else {
                pending[id] = Command(body: AudioSessionChange(id: id, volume: volume, isMuted: muted),
                                      generation: vm.connectionID, revision: revision,
                                      send: { body in try await client.send("/api/audio/session", body: body) })
                order.append(id)
            }
            sendingIDs.insert(id)
            startWorker(vm)
        } catch { self.error = error.localizedDescription }
    }

    private func startWorker(_ vm: OrbitViewModel) {
        guard worker == nil else { return }
        let currentLifetime = lifetime
        worker = Task { [weak self, weak vm] in
            while !Task.isCancelled {
                guard let self, let vm, self.lifetime == currentLifetime, !self.order.isEmpty else { break }
                let id = self.order.removeFirst()
                guard let command = self.pending.removeValue(forKey: id) else { continue }
                guard command.generation == vm.connectionID, !vm.isDemoMode else { break }
                do {
                    let reply = try await command.send(command.body)
                    guard !Task.isCancelled, self.lifetime == currentLifetime, command.generation == vm.connectionID else { break }
                    if self.revisions[id] == command.revision, !self.dragging.contains(id),
                       reply.session.id == id, reply.session.volume.isFinite, (0...100).contains(reply.session.volume),
                       let index = self.sessions.firstIndex(where: { $0.id == id }) {
                        self.sessions[index] = reply.session
                    }
                    self.error = nil
                } catch {
                    guard !Task.isCancelled, self.lifetime == currentLifetime, command.generation == vm.connectionID else { break }
                    self.error = error.localizedDescription
                }
                if self.pending[id] == nil { self.sendingIDs.remove(id) }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
            }
            guard let self, self.lifetime == currentLifetime else { return }
            self.worker = nil
        }
    }

    func reset() {
        lifetime += 1
        worker?.cancel(); worker = nil
        routingTask?.cancel(); routingTask = nil
        sessions = []; error = nil; updated = nil; isLoading = false
        outputs = []; routingAvailable = false; routingReason = nil; routingSessionID = nil; routingStatus = nil
        pending = [:]; order = []; revisions = [:]; changed = [:]; dragging = []; sendingIDs = []
    }
}

struct AudioMixerView: View {
    @ObservedObject var vm: OrbitViewModel
    @StateObject private var mixer = AudioMixerModel()
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.orbitTheme) private var theme

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    OrbitIconBadge(systemName: "slider.vertical.3", tint: .purple, size: 40, filled: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(mixer.sessions.count) audio session\(mixer.sessions.count == 1 ? "" : "s")")
                            .font(.headline.weight(.bold))
                            .contentTransition(.numericText())
                        if let updated = mixer.updated {
                            Text("Updated \(updated.formatted(date: .omitted, time: .standard)) · \(mixer.routingAvailable ? "output routing ready" : "volume & mute")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text("Per-app volume, mute and output device")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if mixer.isLoading { ProgressView().tint(theme.accent) }
                }
                .padding(.vertical, 2)
                masterVolumeRow
                if let reason = mixer.routingReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if vm.isDemoMode {
                    Label("Connect a PC to use the audio mixer", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .orbitRow(tint: .purple)
            if let error = mixer.error {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                    .orbitRow(tint: .orange)
            }
            if let status = mixer.routingStatus {
                Section { Label(status, systemImage: "speaker.wave.2").font(.caption).foregroundStyle(.mint) }
                    .orbitRow(tint: .mint)
            }
            Section("Applications") {
                if mixer.isLoading && mixer.sessions.isEmpty {
                    HStack { ProgressView(); Text("Reading audio sessions…").padding(.leading, 8) }
                } else if mixer.sessions.isEmpty {
                    OrbitEmptyState(icon: "speaker.wave.2", title: "No active audio sessions",
                                    message: "Play audio in any PC app to control its volume here.", tint: .purple)
                } else {
                    ForEach(mixer.sessions) { session in sessionRow(session) }
                }
            }
            .orbitRow()
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
        .navigationTitle("Audio Mixer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await mixer.refresh(vm) } } label: {
                    if mixer.isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(mixer.isLoading || vm.isDemoMode || !vm.metrics.isOnline)
                .accessibilityLabel("Refresh audio sessions")
            }
        }
        .refreshable { await mixer.refresh(vm) }
        .task(id: vm.connectionID) {
            while !Task.isCancelled {
                if scenePhase == .active { await mixer.refresh(vm) }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .onChange(of: vm.connectionID) { _, _ in mixer.reset() }
        .onDisappear { mixer.reset() }
    }

    private var masterVolumeRow: some View {
        HStack(spacing: 12) {
            Button {
                OrbitHaptics.tap()
                Task { await vm.sendPowerAction("mute") }
            } label: {
                OrbitIconBadge(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill", tint: vm.metrics.isMuted ? .orange : theme.accent, size: 32)
            }
            .buttonStyle(.orbitPressable)
            .accessibilityLabel(vm.metrics.isMuted ? "Unmute PC" : "Mute PC")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Master").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(vm.metrics.volumeAvailable == false ? "—" : (vm.metrics.isMuted ? "Muted" : "\(Int(vm.metrics.volume))%"))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(vm.metrics.isMuted ? .orange : .white)
                        .contentTransition(.numericText())
                }
                Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100, step: 1) { editing in
                    vm.isDraggingVolume = editing
                }
                .tint(vm.metrics.isMuted ? .orange : theme.accent)
                .accessibilityLabel("PC master volume")
            }
        }
        .disabled(!vm.metrics.isOnline || vm.metrics.volumeAvailable == false)
        .opacity(!vm.metrics.isOnline || vm.metrics.volumeAvailable == false ? 0.5 : 1)
    }

    private func sessionRow(_ session: AudioMixerSession) -> some View {
        let tint: Color = session.isMuted ? .orange : .purple
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: session.pid == 0 ? "speaker.wave.2.bubble.fill" : "app.fill", tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(session.pid == 0 ? "Windows system sounds" : "PID \(session.pid)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if mixer.sendingIDs.contains(session.id) { ProgressView().controlSize(.mini) }
                Text(session.isMuted ? "Muted" : "\(Int(session.volume))%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(session.isMuted ? .orange : .white)
                    .contentTransition(.numericText())
                    .frame(minWidth: 48, alignment: .trailing)
                Button {
                    OrbitHaptics.tap()
                    mixer.toggleMute(vm, id: session.id)
                } label: {
                    Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(tint.opacity(0.16), in: Circle())
                        .foregroundStyle(tint)
                }
                .buttonStyle(.orbitPressable)
                .accessibilityLabel("\(session.isMuted ? "Unmute" : "Mute") \(session.name)")
            }
            Slider(value: Binding(get: {
                mixer.sessions.first(where: { $0.id == session.id })?.volume ?? session.volume
            }, set: { mixer.setVolume(vm, id: session.id, volume: $0) }), in: 0...100, step: 1,
                   onEditingChanged: { mixer.setDragging(session.id, $0) })
                .tint(tint)
                .accessibilityLabel("Volume for \(session.name)")
            HStack {
                Label(session.outputDeviceName ?? "Current output", systemImage: "hifispeaker")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if mixer.routingSessionID == session.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Menu {
                        Button("System default") { mixer.route(vm, session: session, outputID: "") }
                        ForEach(mixer.outputs) { output in
                            Button(output.name) { mixer.route(vm, session: session, outputID: output.id) }
                        }
                    } label: {
                        Label("Output", systemImage: "arrow.triangle.branch")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.accent.opacity(0.14), in: Capsule())
                            .foregroundStyle(theme.accent)
                    }
                    .disabled(!mixer.routingAvailable || mixer.routingSessionID != nil || session.pid == 0 || session.processCreateTime == nil)
                    .accessibilityLabel("Choose output for \(session.name)")
                }
            }
        }
        .padding(.vertical, 8)
        .disabled(vm.isDemoMode || !vm.metrics.isOnline)
    }
}
