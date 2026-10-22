import SwiftUI
import UIKit

private struct ClipboardPayload: Decodable {
    let text: String
    let available: Bool
}

private struct ClipboardWritePayload: Encodable { let text: String }
private struct DesktopActionReply: Decodable { let status: String }

/// Text between the iPhone and the PC. A clipboard is read only when you tap: there is no
/// timer, no background pasteboard read and no automatic sync.
struct ClipboardView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var text = ""
    @State private var isBusy = false
    @State private var status: String?
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @FocusState private var editing: Bool
    @Environment(\.dismiss) private var dismiss

    private var fitsLimit: Bool { text.utf16.count * 2 + 2 <= 1_048_576 && !text.contains("\0") }
    private var canUsePC: Bool { !vm.isDemoMode && vm.metrics.isOnline && !isBusy }

    var body: some View {
        OrbitPage(spacing: 24) {
            editor

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        OrbitHaptics.tap()
                        readPC()
                    } label: {
                        buttonLabel("Get from PC", systemImage: "arrow.down.doc")
                    }
                    .orbitGlassButton()
                    .disabled(!canUsePC)
                    Button {
                        OrbitHaptics.tap()
                        sendToPC()
                    } label: {
                        buttonLabel(text.isEmpty ? "Clear PC" : "Send to PC", systemImage: text.isEmpty ? "xmark.circle" : "arrow.up.doc")
                    }
                    .orbitGlassButton(prominent: !text.isEmpty)
                    .disabled(!canUsePC || !fitsLimit)
                }
                if vm.isDemoMode || !vm.metrics.isOnline {
                    Text(vm.isDemoMode ? "Connect your own PC to use its clipboard." : "Connect to your PC to use its clipboard.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            feedback

            Text("Orbit reads a clipboard only when you tap Get from PC or Paste. Nothing is synced in the background.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Clipboard")
        .navigationBarTitleDisplayMode(.inline)
        .orbitCloseButton { dismiss() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
        .onChange(of: vm.connectionID) { _, _ in clearScreen() }
        .onDisappear { clearScreen() }
    }

    /// The text, with what the iPhone's clipboard can do with it underneath.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type or paste text here, or get what's on the PC's clipboard.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .focused($editing)
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Clipboard text")
            }
            .font(.body)
            .frame(minHeight: 170, maxHeight: 300)
            HStack(spacing: 8) {
                Text("^[\(text.count) character](inflect: true)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .orbitLiveNumber()
                Spacer(minLength: 8)
                if !text.isEmpty {
                    Button("Clear", systemImage: "xmark") {
                        text = ""
                        status = nil
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(.secondary)
                    .disabled(isBusy)
                    .accessibilityLabel("Clear the text")
                }
                PasteButton(payloadType: String.self) { values in
                    text = values.joined(separator: "\n")
                    status = "Pasted from the iPhone."
                    error = nil
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(OrbitPalette.well)
                .disabled(isBusy)
                Button {
                    OrbitHaptics.tap()
                    UIPasteboard.general.string = text
                    status = "Copied to the iPhone."
                    error = nil
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(OrbitPalette.well)
                .disabled(text.isEmpty || !fitsLimit || isBusy)
            }
        }
        .orbitSurface(padding: 12, radius: 22)
    }

    @ViewBuilder
    private var feedback: some View {
        if isBusy {
            HStack(spacing: 10) {
                ProgressView()
                Text("Working…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        } else if let error {
            OrbitInlineStatus(text: error, kind: .problem)
                .padding(.horizontal, 4)
        } else if let status {
            OrbitInlineStatus(text: status, kind: .success)
                .padding(.horizontal, 4)
        }
    }

    private func buttonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
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
                status = result.available ? "Got the PC's clipboard. Tap Copy to put it on the iPhone." : "The PC's clipboard has no text."
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
                status = payload.text.isEmpty ? "Cleared the PC's clipboard." : "Sent to the PC's clipboard."
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
    /// Agent 4.4+: the name Windows' own mixer shows, whether a stream plays right now,
    /// the Task Manager group (app, background, system) and the icon.
    var displayName: String? = nil
    var isActive: Bool? = nil
    var kind: String? = nil
    var iconID: String? = nil

    var title: String {
        guard let displayName, !displayName.isEmpty else { return name }
        return displayName
    }

    var detail: String {
        if pid == 0 { return "Windows system sounds" }
        return title == name ? "PID \(pid)" : "\(name) · PID \(pid)"
    }
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
                    AudioMixerSession(id: "demo-1", pid: 4100, name: "Example Game", volume: 80, isMuted: false, processCreateTime: 1, outputDeviceID: "out-1", outputDeviceName: "Speakers (Realtek Audio)", isActive: true, kind: "app"),
                    AudioMixerSession(id: "demo-2", pid: 5210, name: "Voice Chat", volume: 65, isMuted: false, processCreateTime: 2, outputDeviceID: "out-2", outputDeviceName: "Headset Earphone", isActive: false, kind: "app"),
                    AudioMixerSession(id: "demo-3", pid: 6320, name: "Music Player", volume: 45, isMuted: false, processCreateTime: 3, outputDeviceID: "out-1", outputDeviceName: "Speakers (Realtek Audio)", isActive: true, kind: "background"),
                    AudioMixerSession(id: "demo-4", pid: 0, name: "System sounds", volume: 100, isMuted: false, processCreateTime: nil, outputDeviceID: "out-1", outputDeviceName: "Speakers (Realtek Audio)", isActive: false, kind: "system")
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
        // A slider in use keeps its row where it is: the agent's order can change between polls.
        guard !isLoading, dragging.isEmpty, vm.metrics.isOnline else { return }
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
                error = "Windows isn't reporting app sound right now. Check the PC's speakers or headset."
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
                routingReason = "To choose where each app plays, update Orbit Companion on the PC, or use Volume mixer in Windows Settings."
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
                self.routingStatus = "Windows saved the new output. Some apps switch only after they play again or restart."
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
                        // Only the levels: name, group and icon come from the list.
                        self.sessions[index].volume = reply.session.volume
                        self.sessions[index].isMuted = reply.session.isMuted
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

/// The PC's volume mixer: the whole PC, then each app the way Windows groups them, with
/// mute, level and the speakers each app plays on.
struct AudioMixerView: View {
    @ObservedObject var vm: OrbitViewModel
    @StateObject private var mixer = AudioMixerModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var groups: [OrbitAudioSessionGroup<AudioMixerSession>] {
        OrbitAudioSessionKind.groups(mixer.sessions, kind: \.kind)
    }

    private var available: Bool { vm.metrics.isOnline && vm.metrics.volumeAvailable != false && !vm.isDemoMode }

    var body: some View {
        OrbitPage {
            pcVolume
            if let error = mixer.error {
                OrbitInlineStatus(text: error, kind: .problem)
                    .padding(.horizontal, 4)
            }
            if let status = mixer.routingStatus {
                OrbitInlineStatus(text: status, kind: .success)
                    .padding(.horizontal, 4)
            }
            if mixer.sessions.isEmpty {
                emptyState
            } else {
                ForEach(groups) { group in
                    OrbitGroup(title(group)) {
                        ForEach(group.sessions) { session in
                            AudioSessionRow(vm: vm, mixer: mixer, session: session)
                        }
                    }
                }
                if let reason = mixer.routingReason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
        }
        .navigationTitle("Volume Mixer")
        .navigationBarTitleDisplayMode(.inline)
        .orbitCloseButton { dismiss() }
        .refreshable { await mixer.refresh(vm) }
        .task(id: vm.connectionID) {
            vm.prepareAppIcons()
            while !Task.isCancelled {
                if scenePhase == .active { await mixer.refresh(vm) }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .onChange(of: vm.connectionID) { _, _ in mixer.reset() }
        .onDisappear { mixer.reset() }
    }

    private func title(_ group: OrbitAudioSessionGroup<AudioMixerSession>) -> String {
        switch group.kind {
        case .app, nil: return "Apps"
        case .background: return "Background Processes"
        case .system: return "Windows"
        }
    }

    private var pcVolume: some View {
        VStack(alignment: .leading, spacing: 12) {
            OrbitSectionHeader("PC Volume")
            HStack(spacing: 14) {
                Button {
                    OrbitHaptics.tap()
                    Task { await vm.sendPowerAction("mute") }
                } label: {
                    Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(vm.metrics.isMuted ? OrbitPalette.warm : .primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vm.metrics.isMuted ? "Unmute the PC" : "Mute the PC")
                Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100, step: 1) { editing in
                    vm.isDraggingVolume = editing
                }
                .accessibilityLabel("PC volume")
                Text(available ? (vm.metrics.isMuted ? "Muted" : "\(Int(vm.metrics.volume))%") : "—")
                    .font(.subheadline.weight(.semibold))
                    .orbitLiveNumber()
                    .foregroundStyle(vm.metrics.isMuted ? OrbitPalette.warm : .secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .orbitSurface(padding: 16, radius: 22)
            .disabled(!available)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if vm.isDemoMode || !vm.metrics.isOnline {
            OrbitEmptyMessage(systemImage: "speaker.slash", title: vm.isDemoMode ? "Not in demo mode" : "Your PC isn't connected",
                              message: vm.isDemoMode ? "Connect your own PC to control each app's volume." : "Connect to your PC to control each app's volume.")
        } else if mixer.isLoading || mixer.updated == nil {
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading what's playing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            OrbitEmptyMessage(systemImage: "speaker.wave.2", title: "Nothing is playing",
                              message: "Apps appear here once they play sound on the PC.")
        }
    }
}

/// One app in the mixer: its icon and name, whether it plays right now, where its sound
/// goes, and its own volume and mute.
private struct AudioSessionRow: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var mixer: AudioMixerModel
    var session: AudioMixerSession

    private var canRoute: Bool {
        mixer.routingAvailable && mixer.routingSessionID == nil && session.pid > 0 && session.processCreateTime != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                OrbitAppIconView(store: vm.appIcons, iconID: session.iconID, size: 30, dimmed: session.isMuted) {
                    Image(systemName: session.pid == 0 ? "speaker.wave.2" : "app")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    detail
                }
                Spacer(minLength: 8)
                if mixer.sendingIDs.contains(session.id) || mixer.routingSessionID == session.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            HStack(spacing: 14) {
                Button {
                    OrbitHaptics.tap()
                    mixer.toggleMute(vm, id: session.id)
                } label: {
                    Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(session.isMuted ? OrbitPalette.warm : .primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(session.isMuted ? "Unmute" : "Mute") \(session.title)")
                Slider(value: Binding(get: {
                    mixer.sessions.first(where: { $0.id == session.id })?.volume ?? session.volume
                }, set: { mixer.setVolume(vm, id: session.id, volume: $0) }), in: 0...100, step: 1,
                       onEditingChanged: { mixer.setDragging(session.id, $0) })
                    .accessibilityLabel("Volume for \(session.title)")
                Text(session.isMuted ? "Muted" : "\(Int(session.volume))%")
                    .font(.subheadline.weight(.semibold))
                    .orbitLiveNumber()
                    .foregroundStyle(session.isMuted ? OrbitPalette.warm : .secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
        .disabled(vm.isDemoMode || !vm.metrics.isOnline)
    }

    @ViewBuilder
    private var detail: some View {
        HStack(spacing: 6) {
            if session.isActive == true {
                HStack(spacing: 4) {
                    Circle()
                        .fill(OrbitPalette.online)
                        .frame(width: 6, height: 6)
                    Text("Playing")
                }
                .accessibilityElement(children: .combine)
                Text("·")
            }
            if session.pid == 0 {
                Text("Windows sounds")
            } else if mixer.outputs.isEmpty && session.outputDeviceName == nil {
                Text(session.name == session.title ? "Default output" : session.name)
                    .lineLimit(1)
            } else {
                Menu {
                    Button("Default Output") { mixer.route(vm, session: session, outputID: "") }
                    ForEach(mixer.outputs) { output in
                        Button(output.name) { mixer.route(vm, session: session, outputID: output.id) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(session.outputDeviceName ?? "Default output")
                            .lineLimit(1)
                        if canRoute {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                    }
                }
                .disabled(!canRoute)
                .accessibilityLabel("Plays on \(session.outputDeviceName ?? "the default output"). Choose another output")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .tint(.secondary)
    }
}
