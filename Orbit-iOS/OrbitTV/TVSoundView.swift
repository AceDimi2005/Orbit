import SwiftUI

/// Sound: the PC's volume and media keys, then every app playing sound with its own level,
/// grouped the way Windows' mixer groups them.
struct TVSoundView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var outputFor: TVAudioSession?
    @State private var showsAddPC = false

    private var state: TVPCState { TVPCState(vm: vm) }

    var body: some View {
        Group {
            if state.isReachable {
                ScrollView {
                    VStack(alignment: .leading, spacing: TVMetrics.sectionSpacing) {
                        HStack(alignment: .top, spacing: TVMetrics.gridSpacing) {
                            TVMasterVolumeCard()
                            TVMediaCard()
                                .frame(width: 520)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        TVMixerSection(outputFor: $outputFor)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
                .scrollClipDisabled()
                .tvDebugScrollAnchor()
            } else {
                TVPCStatusScreen(state: state, purpose: "control its sound") { showsAddPC = true }
            }
        }
        .sheet(item: $outputFor) { session in
            TVOutputPicker(session: session)
        }
        .fullScreenCover(isPresented: $showsAddPC) {
            TVAddPCView { showsAddPC = false }
                .tvFullScreenPage()
        }
        .onChange(of: vm.selectedPCID) { _, _ in showsAddPC = false }
        // Apps start and stop playing on their own; keep the mixer current while it is on screen.
        .task(id: vm.metrics.isOnline) {
            while !Task.isCancelled {
                if scenePhase == .active, vm.metrics.isOnline, !vm.isDemoMode { await vm.refreshAudioMixer() }
                do { try await Task.sleep(for: .seconds(6)) } catch { break }
            }
        }
        #if DEBUG
        .task {
            if TVDebugLaunch.sheet == "output" {
                try? await Task.sleep(for: .seconds(1.5))
                outputFor = vm.audioSessions.first
            }
        }
        #endif
    }
}

// MARK: - Master volume & media

private struct TVMasterVolumeCard: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @Environment(\.tvToast) private var toast

    private var available: Bool { vm.metrics.volumeAvailable != false && (vm.metrics.isOnline || vm.isDemoMode) }
    private var muted: Bool { available && vm.metrics.isMuted }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("PC Volume")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            if available {
                HStack(alignment: .center, spacing: 44) {
                    Text(muted ? "Muted" : "\(Int(vm.metrics.volume.rounded()))%")
                        .font(.orbitReading(96))
                        .foregroundStyle(muted ? OrbitPalette.warm : Color.primary)
                        .orbitLiveNumber()
                        .frame(width: 270, alignment: .leading)
                        .accessibilityLabel(muted ? "PC volume muted" : "PC volume \(Int(vm.metrics.volume.rounded())) percent")
                    OrbitMeter(fraction: vm.metrics.volume / 100,
                               style: AnyShapeStyle(muted ? OrbitPalette.warm : Color.white), height: 10)
                    HStack(spacing: 22) {
                        TVIconButton("Turn Down", systemImage: "minus") {
                            Task { await vm.adjustMasterVolume(by: -5) }
                        }
                        TVIconButton(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                            Task {
                                if !(await vm.sendAction("mute")) { toast(vm.lastActionError) }
                            }
                        }
                        TVIconButton("Turn Up", systemImage: "plus") {
                            Task { await vm.adjustMasterVolume(by: 5) }
                        }
                    }
                }
            } else {
                Text("Windows isn't reporting a volume right now. Each app's level below still works.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
        .focusSection()
    }
}

private struct TVMediaCard: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @Environment(\.tvToast) private var toast

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Media")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 22) {
                key("Previous", "backward.fill", "media_prev")
                key("Play or Pause", "playpause.fill", "media_play_pause")
                    .tvDebugFocus("media")
                key("Next", "forward.fill", "media_next")
            }
            Spacer(minLength: 0)
            Text("Play/Pause on the remote works too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
        .focusSection()
    }

    private func key(_ title: String, _ symbol: String, _ action: String) -> some View {
        TVIconButton(title, systemImage: symbol) {
            Task {
                if !(await vm.sendAction(action)) { toast(vm.lastActionError) }
            }
        }
    }
}

// MARK: - Mixer

private struct TVMixerSection: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @Binding var outputFor: TVAudioSession?

    var body: some View {
        let groups = OrbitAudioSessionKind.groups(vm.audioSessions, kind: \.kind)
        VStack(alignment: .leading, spacing: TVMetrics.sectionSpacing - 16) {
            if groups.isEmpty {
                VStack(alignment: .leading, spacing: TVMetrics.titleSpacing) {
                    TVSectionTitle("Apps")
                    Text("Nothing is playing sound on the PC. Apps show up here when they do.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
                }
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: TVMetrics.titleSpacing) {
                    TVSectionTitle(title(group.kind))
                    VStack(spacing: 24) {
                        ForEach(group.sessions) { session in
                            TVMixerRow(session: session, outputFor: $outputFor)
                        }
                    }
                }
                .focusSection()
            }
        }
    }

    private func title(_ kind: OrbitAudioSessionKind?) -> String {
        switch kind {
        case .app, nil: return "Apps"
        case .background: return "Background Processes"
        case .system: return "Windows"
        }
    }
}

private struct TVMixerRow: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    var session: TVAudioSession
    @Binding var outputFor: TVAudioSession?

    private var canRoute: Bool { (vm.audioRoutingAvailable || vm.isDemoMode) && !vm.audioOutputs.isEmpty && session.processCreateTime != nil }

    var body: some View {
        HStack(spacing: 36) {
            TVAppIcon(store: vm.appIcons, iconID: session.iconID, name: session.title, size: 72, dimmed: session.isMuted,
                      symbol: session.pid == 0 ? "speaker.wave.2" : nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 520, alignment: .leading)
            OrbitMeter(fraction: session.volume / 100,
                       style: AnyShapeStyle(session.isMuted ? OrbitPalette.warm : Color.white), height: 8)
            Text(session.isMuted ? "Muted" : "\(Int(session.volume.rounded()))%")
                .font(.orbitReading(44))
                .foregroundStyle(session.isMuted ? OrbitPalette.warm : Color.primary)
                .orbitLiveNumber()
                .frame(width: 150, alignment: .trailing)
            HStack(spacing: 20) {
                TVIconButton("Turn Down \(session.title)", systemImage: "minus") {
                    Task { await vm.adjustAppVolume(session, by: -10) }
                }
                .tvDebugFocus(session.id == vm.audioSessions.first?.id ? "mixer" : (session.id == vm.audioSessions.last?.id ? "mixer-last" : ""))
                TVIconButton("Turn Up \(session.title)", systemImage: "plus") {
                    Task { await vm.adjustAppVolume(session, by: 10) }
                }
                TVIconButton(session.isMuted ? "Unmute \(session.title)" : "Mute \(session.title)",
                             systemImage: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    Task { await vm.toggleAppMute(session) }
                }
                if canRoute {
                    TVIconButton("Choose Speakers for \(session.title)", systemImage: "hifispeaker") {
                        outputFor = session
                    }
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 26)
        .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: TVMetrics.rowRadius, style: .continuous))
    }

    /// "Playing · Speakers (Realtek Audio)": what it is doing, then where it plays.
    private var detail: String {
        var parts: [String] = []
        if session.isActive == true { parts.append("Playing") }
        parts.append(session.outputDeviceName ?? "Default output")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Output picker

private struct TVOutputPicker: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    var session: TVAudioSession
    @Environment(\.dismiss) private var dismiss

    private var current: TVAudioSession { vm.audioSessions.first { $0.id == session.id } ?? session }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(vm.audioOutputs) { device in
                        let selected = current.outputDeviceID == device.id || current.outputDeviceName == device.name
                        Button {
                            Task {
                                await vm.routeAppAudio(current, to: device.id)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 24) {
                                Text(device.name)
                                    .lineLimit(2)
                                Spacer(minLength: 16)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.callout.weight(.semibold))
                                        .accessibilityLabel("Current")
                                }
                            }
                            .tvRowLabel()
                        }
                    }
                } header: {
                    TVListHeader("Play On")
                } footer: {
                    Text("Other apps keep playing where they are.")
                }
            }
            .listStyle(.grouped)
            .tint(nil)
            .navigationTitle(current.title)
        }
    }
}
