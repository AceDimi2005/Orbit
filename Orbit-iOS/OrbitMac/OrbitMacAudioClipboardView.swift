import AppKit
import Combine
import SwiftUI

// MARK: - Audio mixer

/// Per-app audio mixer: master volume, playback devices and one glass row per
/// Windows audio session with volume, mute and (when the agent supports it)
/// per-app output routing. Only values the agent reported are shown.
struct MacAudioView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    /// Sessions whose slider is currently being dragged; auto-refresh pauses while non-empty.
    @State private var draggingIDs: Set<String> = []

    private var volumeKnown: Bool { vm.metrics.volumeAvailable != false }

    var body: some View {
        MacPage {
            VStack(alignment: .leading, spacing: 16) {
                if vm.currentPC == nil && !vm.isDemoMode {
                    unpairedState
                } else if !vm.metrics.isOnline {
                    offlineState
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        masterCard.frame(maxWidth: .infinity)
                        outputsCard.frame(maxWidth: .infinity)
                    }
                    notices
                    sessionsHeader
                    sessionsContent
                }
            }
        }
        .task {
            await vm.refreshAudio()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { break }
                guard draggingIDs.isEmpty, vm.audioRoutingSessionID == nil else { continue }
                await vm.refreshAudio()
            }
        }
        .onChange(of: vm.selectedPCID) { _, _ in
            draggingIDs = []
            Task { await vm.refreshAudio() }
        }
    }

    // MARK: Master

    private var isMuted: Bool { vm.metrics.isMuted }
    private var masterTint: Color { isMuted ? .orange : theme.accent }
    /// `nil` keeps the ring empty when the agent did not report a system volume.
    private var masterProgress: Double? { volumeKnown ? vm.metrics.volume / 100 : nil }
    private var masterValueText: String { volumeKnown ? "\(Int(vm.metrics.volume.rounded()))" : "—" }
    private var masterHint: String {
        volumeKnown
            ? "⌘⌥↑ and ⌘⌥↓ nudge the volume · ⌘⇧M toggles mute"
            : "The agent did not report a system volume. Check the default playback device on the PC."
    }

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSectionHeader("Volume", subtitle: vm.selectedPCName, icon: "speaker.wave.3.fill") {
                MacStatusPill(text: isMuted ? "Muted" : "Live", tint: isMuted ? .orange : .mint, pulsing: !isMuted)
            }
            HStack(alignment: .center, spacing: 16) {
                masterRing
                masterReadout
                masterMuteButton
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 20, tint: theme.accent, elevated: true)
    }

    private var masterRing: some View {
        ZStack {
            MacRing(progress: masterProgress, lineWidth: 6, tint: masterTint)
                .frame(width: 72, height: 72)
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isMuted ? AnyShapeStyle(Color.orange) : AnyShapeStyle(theme.heroGradient))
        }
    }

    private var masterReadout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(masterValueText)
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if volumeKnown {
                    Text("%").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            masterSlider
            Text(masterHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var masterMuteButton: some View {
        Button {
            Task { await vm.sendAction("mute") }
        } label: {
            Label(isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
        .buttonStyle(MacHoverButtonStyle(tint: masterTint, prominent: isMuted))
        .help(isMuted ? "Unmute the PC (⌘⇧M)" : "Mute the PC (⌘⇧M)")
    }

    private var masterSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100) { editing in
                vm.isDraggingVolume = editing
            }
            .disabled(!volumeKnown)
            .accessibilityLabel("PC volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Outputs

    private var outputsSubtitle: String? {
        if vm.audioOutputs.isEmpty { return nil }
        return vm.audioOutputs.count == 1 ? "1 playback device" : "\(vm.audioOutputs.count) playback devices"
    }

    private var outputsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Outputs", subtitle: outputsSubtitle, icon: "hifispeaker.fill") {
                if vm.audioRoutingAvailable {
                    MacStatusPill(text: "Per-app routing", tint: .mint, icon: "arrow.triangle.branch")
                } else {
                    MacStatusPill(text: "Mixer only", tint: .secondary, icon: "slider.horizontal.3")
                }
            }
            if vm.audioOutputs.isEmpty {
                Text(vm.audioUpdated == nil && !vm.isDemoMode ? "Reading playback devices…" : "The agent did not report any playback devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(vm.audioOutputs) { output in
                        outputRow(output)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    private func outputRow(_ output: MacAudioOutput) -> some View {
        let routed = vm.audioSessions.filter { $0.outputDeviceID == output.id }.count
        return HStack(spacing: 10) {
            MacIconBadge(systemName: "hifispeaker.fill", tint: theme.secondary, size: 28)
            Text(output.name)
                .font(.system(.subheadline, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if routed > 0 {
                MacStatChip(label: routed == 1 ? "app" : "apps", value: "\(routed)", icon: "app.fill", tint: theme.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if let error = vm.audioError, !vm.audioSessions.isEmpty {
            MacNotice(title: "Audio problem", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let status = vm.audioStatus {
            MacNotice(title: "Output changed", message: status, icon: "checkmark.circle.fill", tint: theme.accent)
        }
        if !vm.audioRoutingAvailable, let reason = vm.audioRoutingReason {
            MacNotice(title: "Per-app output routing unavailable", message: reason, icon: "arrow.triangle.branch", tint: theme.secondary)
        }
    }

    // MARK: Sessions

    private var sessionsSubtitle: String? {
        var parts: [String] = []
        if !vm.audioSessions.isEmpty {
            parts.append(vm.audioSessions.count == 1 ? "1 app" : "\(vm.audioSessions.count) apps")
        }
        if let updated = vm.audioUpdated {
            parts.append("Updated \(updated.formatted(date: .omitted, time: .standard))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var anyUnmuted: Bool { vm.audioSessions.contains { !$0.isMuted } }

    private var sessionsHeader: some View {
        MacSectionHeader("Apps", subtitle: sessionsSubtitle, icon: "slider.vertical.3") {
            HStack(spacing: 8) {
                if !vm.audioSessions.isEmpty {
                    Button(anyUnmuted ? "Mute all" : "Unmute all") {
                        let target = anyUnmuted
                        for session in vm.audioSessions where session.isMuted != target { vm.toggleAppMute(session) }
                    }
                    .buttonStyle(MacHoverButtonStyle(tint: anyUnmuted ? .orange : theme.accent))
                    .help(anyUnmuted ? "Mute every app" : "Unmute every app")
                }
                if vm.isLoadingAudio {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await vm.refreshAudio() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(MacIconButtonStyle(size: 26))
                    .disabled(vm.isDemoMode)
                    .help("Refresh audio sessions")
                    .accessibilityLabel("Refresh audio sessions")
                }
            }
        }
    }

    @ViewBuilder
    private var sessionsContent: some View {
        if vm.audioSessions.isEmpty {
            if let error = vm.audioError {
                MacEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Audio sessions unavailable",
                    message: error,
                    tint: .orange,
                    actionTitle: "Try again",
                    action: { Task { await vm.refreshAudio() } }
                )
                .macGlass(cornerRadius: 20, tint: .orange)
            } else if vm.isLoadingAudio || (vm.audioUpdated == nil && !vm.isDemoMode) {
                loadingCard
            } else {
                MacEmptyState(
                    icon: "speaker.slash",
                    title: "No apps are playing audio",
                    message: "Windows only lists applications with an active audio session. Start playback on the PC and this list fills in automatically.",
                    tint: theme.accent,
                    actionTitle: "Refresh",
                    action: { Task { await vm.refreshAudio() } }
                )
                .macGlass(cornerRadius: 20, tint: theme.accent)
            }
        } else {
            // Like Windows Task Manager: apps, then background processes, then Windows.
            VStack(alignment: .leading, spacing: 16) {
                ForEach(OrbitAudioSessionKind.groups(vm.audioSessions, kind: \.kind)) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if group.kind != nil {
                            Text(group.title)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                        ForEach(group.sessions) { session in
                            MacAudioclipSessionRow(session: session, draggingIDs: $draggingIDs)
                        }
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: vm.audioSessions.map(\.id))
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Reading audio sessions from \(vm.selectedPCName)…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 16)
    }

    // MARK: Empty states

    private var unpairedState: some View {
        MacEmptyState(
            icon: "desktopcomputer",
            title: "No PC paired",
            message: "Pair a PC, or import the one you already paired on your iPhone, to control its audio from this Mac.",
            tint: theme.accent,
            actionTitle: "Pair or import a PC",
            action: { vm.selectedSection = .pcs }
        )
        .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
    }

    private var offlineState: some View {
        MacEmptyState(
            icon: "wifi.slash",
            title: "\(vm.selectedPCName) is offline",
            message: vm.connectionError.map { "The audio mixer needs a live connection. \($0)" } ?? "The audio mixer needs a live connection to the Orbit Agent.",
            tint: .orange,
            actionTitle: vm.isWaking ? "Waking…" : "Retry",
            action: { Task { await vm.refreshMetrics() } }
        )
        .macGlass(cornerRadius: 22, tint: .orange)
    }
}

/// One Windows audio session: icon, name, output device, mute, volume.
private struct MacAudioclipSessionRow: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    let session: MacAudioSession
    @Binding var draggingIDs: Set<String>
    @State private var hovered = false

    private var symbol: String {
        MacAudioclipIcon.symbol(for: session.name, activeGame: vm.metrics.activeGame, activeProcess: vm.metrics.activeGameProcess)
    }
    private var tint: Color { MacAudioclipIcon.tint(for: symbol, theme: theme) }
    private var isRouting: Bool { vm.audioRoutingSessionID == session.id }
    private var meta: String {
        var parts: [String] = []
        if session.pid == 0 {
            parts.append("Windows system sounds")
        } else {
            if session.title != session.name { parts.append(session.name) }
            parts.append("PID \(session.pid)")
        }
        if let device = session.outputDeviceName, !device.isEmpty { parts.append(device) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                OrbitAppIconView(store: vm.appIcons, iconID: session.iconID, size: 36, dimmed: session.isMuted) {
                    MacIconBadge(systemName: symbol, tint: tint, size: 36, filled: symbol == "gamecontroller.fill")
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.system(.headline, weight: .semibold))
                            .lineLimit(1)
                        if session.isMuted {
                            MacStatusPill(text: "Muted", tint: .orange, icon: "speaker.slash.fill")
                        } else if session.isActive == true {
                            MacStatusPill(text: "Playing", tint: .mint, icon: "waveform")
                        }
                    }
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if vm.audioRoutingAvailable && !vm.audioOutputs.isEmpty {
                    routingMenu
                }
                muteButton
            }
            volumeRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 16, tint: tint, hovered: hovered)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.title), \(MacFormat.percent(session.volume))\(session.isMuted ? ", muted" : "")")
    }

    private var routingMenu: some View {
        HStack(spacing: 6) {
            if isRouting {
                ProgressView().controlSize(.small)
            }
            Menu {
                ForEach(vm.audioOutputs) { output in
                    Button {
                        Task { await vm.routeApp(session, to: output.id) }
                    } label: {
                        if output.id == session.outputDeviceID {
                            Label(output.name, systemImage: "checkmark")
                        } else {
                            Text(output.name)
                        }
                    }
                }
            } label: {
                Label(session.outputDeviceName ?? "Choose output", systemImage: "hifispeaker")
                    .font(.system(.caption, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 200)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(vm.audioRoutingSessionID != nil)
            .help("Route this app's audio to another playback device")
            .accessibilityLabel("Output device for \(session.title)")
        }
    }

    private var muteButton: some View {
        Button {
            vm.toggleAppMute(session)
        } label: {
            Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(MacIconButtonStyle(tint: session.isMuted ? .orange : .white, size: 30))
        .help(session.isMuted ? "Unmute \(session.title)" : "Mute \(session.title)")
        .accessibilityLabel(session.isMuted ? "Unmute \(session.title)" : "Mute \(session.title)")
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { session.volume }, set: { vm.setAppVolume(session, volume: $0) }), in: 0...100) { editing in
                if editing { draggingIDs.insert(session.id) } else { draggingIDs.remove(session.id) }
                vm.setAudioDragging(session.id, editing)
            }
            .tint(session.isMuted ? .orange : tint)
            .accessibilityLabel("\(session.title) volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(MacFormat.percent(session.volume))
                .font(.system(.callout, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(width: 48, alignment: .trailing)
        }
        .opacity(session.isMuted ? 0.6 : 1)
    }
}

/// Icon heuristics for audio sessions (names only; nothing is inferred about readings).
private enum MacAudioclipIcon {
    static func symbol(for name: String, activeGame: String?, activeProcess: String?) -> String {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return "app.fill" }
        if let game = activeGame?.lowercased(), !game.isEmpty, lower.contains(game) || game.contains(lower) { return "gamecontroller.fill" }
        if let process = activeProcess?.lowercased(), !process.isEmpty, lower.contains(process) || process.contains(lower) { return "gamecontroller.fill" }
        if matches(lower, ["chrome", "firefox", "edge", "safari", "brave", "opera", "vivaldi", "browser"]) { return "globe" }
        if matches(lower, ["spotify", "music", "itunes", "tidal", "deezer", "foobar", "winamp", "vlc", "player"]) { return "music.note" }
        if matches(lower, ["discord", "teamspeak", "slack", "teams", "zoom", "skype", "voice", "chat"]) { return "bubble.left.and.bubble.right.fill" }
        if matches(lower, ["steam", "game", "epic", "riot", "battle.net", "launcher", "ubisoft", "gog"]) { return "gamecontroller.fill" }
        if matches(lower, ["system sounds", "system"]) { return "speaker.wave.2.fill" }
        return "app.fill"
    }

    private static func matches(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    static func tint(for symbol: String, theme: MacTheme) -> Color {
        switch symbol {
        case "globe": return Color(red: 0.48, green: 0.72, blue: 1)
        case "music.note": return Color(red: 0.35, green: 0.94, blue: 0.66)
        case "bubble.left.and.bubble.right.fill": return Color(red: 0.68, green: 0.65, blue: 0.98)
        case "gamecontroller.fill": return .mint
        case "speaker.wave.2.fill": return theme.secondary
        default: return theme.accent
        }
    }
}

// MARK: - Shared clipboard

/// Text clipboard shared with the PC. Nothing is polled: every transfer is a
/// button press, and the editor doubles as a scratch pad.
struct MacClipboardView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @AppStorage("mac.clipboardMono") private var monospaced = false
    @State private var macSnapshot: MacAudioclipPasteboardSnapshot?

    /// Mirrors `clipboardFitsLimit`: UTF-16 bytes plus terminator, 1 MiB cap.
    private static let limitBytes: Int64 = 1_048_576
    private var usedBytes: Int64 { Int64(vm.clipboardText.utf16.count) * 2 + 2 }
    private var canTalkToPC: Bool { vm.metrics.isOnline && !vm.isDemoMode && !vm.isClipboardBusy }
    private var editorFont: Font { monospaced ? .system(.body, design: .monospaced) : .system(.body) }
    private var previewFont: Font { monospaced ? .system(.callout, design: .monospaced) : .system(.callout) }

    var body: some View {
        MacPage {
            VStack(alignment: .leading, spacing: 16) {
                if vm.currentPC == nil && !vm.isDemoMode {
                    unpairedState
                } else if !vm.metrics.isOnline {
                    offlineState
                } else {
                    header
                    if vm.isDemoMode { demoNotice }
                    if let error = vm.clipboardError {
                        MacNotice(title: "Clipboard problem", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if let status = vm.clipboardStatus {
                        MacNotice(title: "Clipboard", message: status, icon: "checkmark.circle.fill", tint: theme.accent)
                    }
                    editorCard
                    actionsGrid
                    macPreviewCard
                }
            }
        }
        .onAppear { refreshMacPreview() }
        .onChange(of: vm.selectedPCID) { _, _ in refreshMacPreview() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMacPreview()
        }
    }

    // MARK: Header

    private var header: some View {
        MacSectionHeader(
            "Shared clipboard",
            subtitle: "Text moves only when you ask · \(vm.selectedPCName)\(vm.currentPC?.isSecure == true ? " · encrypted link" : "")",
            icon: "doc.on.clipboard.fill"
        ) {
            HStack(spacing: 10) {
                if vm.isClipboardBusy {
                    ProgressView().controlSize(.small)
                }
                Toggle("Monospaced", isOn: $monospaced)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show the text in a monospaced font")
            }
        }
    }

    private var demoNotice: some View {
        MacNotice(
            title: "Demo mode",
            message: "Pull and Push need a paired PC. The editor and the Mac clipboard buttons still work.",
            icon: "sparkles",
            tint: .orange
        )
    }

    // MARK: Editor

    private var counterText: String {
        var parts = [
            "\(vm.clipboardText.count.formatted()) characters",
            "\(MacFormat.bytes(usedBytes)) of \(MacFormat.bytes(Self.limitBytes))"
        ]
        if vm.clipboardText.contains("\0") { parts.append("contains a null character") }
        return parts.joined(separator: " · ")
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $vm.clipboardText)
                    .font(editorFont)
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .padding(6)
                    .frame(height: 300)
                    .accessibilityLabel("Shared clipboard text")
                if vm.clipboardText.isEmpty {
                    Text("Type or paste text here, then push it to your PC. Pull loads whatever the PC has copied.")
                        .font(editorFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            HStack(spacing: 10) {
                Image(systemName: vm.clipboardFitsLimit ? "character.cursor.ibeam" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(vm.clipboardFitsLimit ? Color.secondary : Color.red)
                Text(counterText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(vm.clipboardFitsLimit ? Color.secondary : Color.red)
                    .lineLimit(1)
                Spacer(minLength: 8)
                MacStatChip(label: "Pull", value: "⌘⇧R", icon: "keyboard")
                MacStatChip(label: "Push", value: "⌘↩")
            }
        }
        .padding(14)
        .macGlass(cornerRadius: 18, tint: theme.accent, elevated: true)
    }

    // MARK: Actions

    private var actionsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 8)], spacing: 8) {
            Button {
                Task { await vm.pullClipboard() }
            } label: {
                Label("Pull from PC", systemImage: "arrow.down.doc.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!canTalkToPC)
            .help("Load the text on the PC clipboard (⌘⇧R)")

            Button {
                Task { await vm.pushClipboard() }
            } label: {
                Label("Push to PC", systemImage: "arrow.up.doc.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canTalkToPC || vm.clipboardText.isEmpty || !vm.clipboardFitsLimit)
            .help(vm.clipboardFitsLimit ? "Send this text to the PC clipboard (⌘↩)" : "The text exceeds the 1 MB clipboard limit")

            Button {
                vm.copyClipboardToMac()
                refreshMacPreview()
            } label: {
                Label("Copy to Mac", systemImage: "doc.on.doc.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(MacHoverButtonStyle())
            .disabled(vm.clipboardText.isEmpty)
            .help("Copy this text to the Mac clipboard")

            Button {
                vm.pasteFromMac()
                refreshMacPreview()
            } label: {
                Label("Paste from Mac", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
            }
            .buttonStyle(MacHoverButtonStyle())
            .help("Replace the text with the Mac clipboard")

            Button {
                vm.clipboardText = ""
                vm.clipboardStatus = nil
                vm.clipboardError = nil
            } label: {
                Label("Clear", systemImage: "xmark.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(MacHoverButtonStyle(tint: .orange))
            .disabled(vm.clipboardText.isEmpty)
            .help("Clear the editor (the PC clipboard is not changed)")
        }
    }

    // MARK: Mac pasteboard preview

    private var macPreviewSubtitle: String? {
        guard let snapshot = macSnapshot else { return nil }
        let lines = snapshot.totalLines == 1 ? "1 line" : "\(snapshot.totalLines) lines"
        return "\(snapshot.characters.formatted()) characters · \(lines)"
    }

    private var macPreviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacSectionHeader("On This Mac", subtitle: macPreviewSubtitle, icon: "laptopcomputer") {
                Button {
                    refreshMacPreview()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(MacIconButtonStyle(size: 26))
                .help("Re-read the Mac clipboard")
                .accessibilityLabel("Refresh Mac clipboard preview")
            }
            if let snapshot = macSnapshot {
                Text(snapshot.preview.isEmpty ? " " : snapshot.preview)
                    .font(previewFont)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if snapshot.hiddenLines > 0 {
                    Text(snapshot.hiddenLines == 1 ? "+1 more line" : "+\(snapshot.hiddenLines) more lines")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("The Mac clipboard does not contain text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    private func refreshMacPreview() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            macSnapshot = nil
            return
        }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        macSnapshot = MacAudioclipPasteboardSnapshot(
            preview: lines.prefix(3).joined(separator: "\n"),
            totalLines: lines.count,
            hiddenLines: max(0, lines.count - 3),
            characters: text.count
        )
    }

    // MARK: Empty states

    private var unpairedState: some View {
        MacEmptyState(
            icon: "desktopcomputer",
            title: "No PC paired",
            message: "Pair a PC, or import the one you already paired on your iPhone, to share text between the clipboards.",
            tint: theme.accent,
            actionTitle: "Pair or import a PC",
            action: { vm.selectedSection = .pcs }
        )
        .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
    }

    private var offlineState: some View {
        MacEmptyState(
            icon: "wifi.slash",
            title: "\(vm.selectedPCName) is offline",
            message: vm.connectionError.map { "The shared clipboard needs a live connection. \($0)" } ?? "The shared clipboard needs a live connection to the Orbit Agent.",
            tint: .orange,
            actionTitle: vm.isWaking ? "Waking…" : "Retry",
            action: { Task { await vm.refreshMetrics() } }
        )
        .macGlass(cornerRadius: 22, tint: .orange)
    }
}

/// First lines of the Mac pasteboard, captured on demand (never polled).
private struct MacAudioclipPasteboardSnapshot {
    let preview: String
    let totalLines: Int
    let hiddenLines: Int
    let characters: Int
}
