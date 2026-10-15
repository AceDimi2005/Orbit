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

    var body: some View {
        List {
            Section {
                Label("Copy between your iPhone and PC", systemImage: "doc.on.clipboard")
                    .font(.headline)
                Text("Transfer text and links when you choose. Orbit does not watch either clipboard or save a clipboard history. Text on this screen is cleared when you leave or change PCs.")
                    .font(.caption).foregroundStyle(.secondary)
                if vm.isDemoMode {
                    Label("Connect a PC to use clipboard transfers", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Text") {
                TextEditor(text: $text)
                    .frame(minHeight: 190, maxHeight: 300)
                    .font(.body)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Clipboard text")
                HStack {
                    Text("\(text.count.formatted()) characters")
                    Spacer()
                    Button("Clear", role: .destructive) { text = ""; status = nil }
                        .disabled(text.isEmpty || isBusy)
                }.font(.caption).foregroundStyle(.secondary)
                if !fitsLimit {
                    Text("Text must fit within 1 MB and cannot include null characters.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("iPhone") {
                HStack {
                    Label("Paste from iPhone", systemImage: "iphone")
                    Spacer()
                    PasteButton(payloadType: String.self) { values in
                        text = values.joined(separator: "\n")
                        status = "Pasted into Orbit. Tap Send to PC to transfer it."
                        error = nil
                    }
                    .labelStyle(.titleOnly)
                    .disabled(isBusy)
                }
                Button {
                    UIPasteboard.general.string = text
                    status = "Copied to the iPhone clipboard."
                    error = nil
                } label: { Label("Copy to iPhone", systemImage: "doc.on.doc") }
                    .disabled(text.isEmpty || !fitsLimit || isBusy)
            }
            Section("PC") {
                Button { readPC() } label: {
                    Label("Read PC clipboard", systemImage: "arrow.down.doc")
                }.disabled(!canUsePC)
                Button { sendToPC() } label: {
                    Label(text.isEmpty ? "Clear PC clipboard" : "Send text to PC", systemImage: "arrow.up.doc")
                }.disabled(!canUsePC || !fitsLimit)
                Text("Sending replaces the PC's current clipboard text. The connection uses the certificate paired in My PCs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isBusy { Section { HStack { ProgressView(); Text("Transferring text…").font(.subheadline) } } }
            if let status { Section { Label(status, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.mint) } }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) } }
        }
        .navigationTitle("Clipboard")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: vm.connectionID) { _, _ in clearScreen() }
        .onDisappear { clearScreen() }
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
}

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
        guard !isLoading, !vm.isDemoMode, vm.metrics.isOnline else { return }
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
        sessions = []; error = nil; updated = nil; isLoading = false
        pending = [:]; order = []; revisions = [:]; changed = [:]; dragging = []; sendingIDs = []
    }
}

struct AudioMixerView: View {
    @ObservedObject var vm: OrbitViewModel
    @StateObject private var mixer = AudioMixerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                Label("Volume for each application", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Text("Open an app and play audio to create its Windows audio session. These controls adjust that session on the default playback device. An app can have more than one session.")
                    .font(.caption).foregroundStyle(.secondary)
                if vm.isDemoMode {
                    Label("Connect a PC to use the audio mixer", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let updated = mixer.updated {
                    HStack { Text("\(mixer.sessions.count) sessions"); Spacer(); Text(updated, style: .time) }
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = mixer.error {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            }
            Section("Applications") {
                if mixer.isLoading && mixer.sessions.isEmpty {
                    HStack { ProgressView(); Text("Reading audio sessions…").padding(.leading, 8) }
                } else if mixer.sessions.isEmpty {
                    ContentUnavailableView("No audio sessions", systemImage: "speaker.wave.2",
                                           description: Text("Keep Orbit Agent running on your PC, then open an app and play audio. Set up the encrypted connection in My PCs to use this feature."))
                } else {
                    ForEach(mixer.sessions) { session in sessionRow(session) }
                }
            }
        }
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

    private func sessionRow(_ session: AudioMixerSession) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "app.fill").foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(session.pid == 0 ? "Windows system sounds" : "PID \(session.pid)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if mixer.sendingIDs.contains(session.id) { ProgressView().controlSize(.mini) }
                Button { mixer.toggleMute(vm, id: session.id) } label: {
                    Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .tint(session.isMuted ? .orange : .cyan)
                .accessibilityLabel("\(session.isMuted ? "Unmute" : "Mute") \(session.name)")
            }
            HStack {
                Slider(value: Binding(get: {
                    mixer.sessions.first(where: { $0.id == session.id })?.volume ?? session.volume
                }, set: { mixer.setVolume(vm, id: session.id, volume: $0) }), in: 0...100, step: 1,
                       onEditingChanged: { mixer.setDragging(session.id, $0) })
                    .tint(.cyan)
                    .accessibilityLabel("Volume for \(session.name)")
                Text("\(Int(session.volume))%")
                    .font(.caption.monospacedDigit()).frame(width: 42, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .disabled(vm.isDemoMode || !vm.metrics.isOnline)
    }
}
