import SwiftUI
import WatchKit

/// Media: what's playing on the PC and the keys to control it. The game that runs (with its
/// frame rate and a way to quit it), play/pause and skipping, and the PC's volume, which the
/// Digital Crown turns once you tap it.
struct WatchMediaPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var showsGames = false
    @State private var confirmsQuit = false

    private var enabled: Bool { vm.canControlPC }
    private var game: String? { vm.isOnline ? vm.telemetry.game : nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let game { nowPlaying(game) }
                transport
                WatchVolumeControl(vm: vm)
                if !vm.games.isEmpty {
                    Button {
                        showsGames = true
                    } label: {
                        WatchButtonLabel(title: "Start a Game", systemImage: "gamecontroller", alignment: .leading)
                    }
                    .watchButton()
                    .disabled(!enabled)
                }
                // Quitting is rare and loses progress, so it waits at the bottom.
                if game != nil {
                    Button {
                        confirmsQuit = true
                    } label: {
                        WatchButtonLabel(title: "Quit Game", systemImage: "xmark", alignment: .leading, isDestructive: true)
                    }
                    .watchButton()
                    .disabled(!enabled)
                }
                WatchFeedbackLine(vm: vm)
            }
            .watchAnimation(value: game)
            .tint(vm.tint)
        }
        .watchDebugScrollAnchor()
        .navigationTitle("Media")
        .sheet(isPresented: $showsGames) { WatchGamesSheet(vm: vm) }
        .confirmationDialog("Quit \(game ?? "the game")?", isPresented: $confirmsQuit, titleVisibility: .visible) {
            Button("Quit Game", role: .destructive) {
                Task { await vm.sendPowerAction("kill_game") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved progress in the game may be lost.")
        }
        #if DEBUG
        .onAppear {
            if WatchDebugOptions.sheet == "games" { showsGames = true }
            if WatchDebugOptions.sheet == "quit" { confirmsQuit = true }
        }
        #endif
    }

    // MARK: Game

    private func nowPlaying(_ game: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Playing now")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(game)
                .font(.headline)
                .lineLimit(2)
            if let frameRate = WatchVitals.frameRate(vm.telemetry), let value = frameRate.value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.orbitReading(28))
                        .orbitLiveNumber()
                    Text("fps")
                        .font(.orbitReading(14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 6) {
            transportButton("Previous", systemImage: "backward.fill", action: "media_prev")
            transportButton("Play or Pause", systemImage: "playpause.fill", action: "media_play_pause", prominent: true)
                .handGestureShortcut(.primaryAction)
            transportButton("Next", systemImage: "forward.fill", action: "media_next")
        }
    }

    private func transportButton(_ title: String, systemImage: String, action: String, prominent: Bool = false) -> some View {
        Button {
            Task { await vm.sendPowerAction(action) }
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
        }
        .buttonStyle(WatchRowButtonStyle(prominent: prominent, tint: vm.tint))
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

// MARK: - Volume

/// The PC's volume. Tap the level to hand the Digital Crown over, turn it, tap again when done.
/// The buttons under it step by five and mute.
struct WatchVolumeControl: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var level: Double = 40
    @State private var crownActive = false
    @FocusState private var crownFocused: Bool

    private var enabled: Bool { vm.canControlPC }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                crownActive.toggle()
                crownFocused = crownActive
            } label: {
                levelCard
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .focusable(crownActive)
            .focused($crownFocused)
            .digitalCrownRotation($level, from: 0, through: 100, by: 1, sensitivity: .medium,
                                  isContinuous: false, isHapticFeedbackEnabled: true)
            .onChange(of: level) { _, value in
                // Readings from the PC move the level without becoming another volume command.
                if crownActive && enabled && abs(value - vm.volume) >= 1 { vm.setPCVolume(value) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PC volume")
            .accessibilityValue(enabled ? (vm.isMuted ? "Muted" : "\(Int(level.rounded())) percent") : "Unavailable")
            .accessibilityHint("Tap, then turn the Digital Crown.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(5)
                case .decrement: step(-5)
                @unknown default: break
                }
            }
            HStack(spacing: 6) {
                stepButton("Volume Down", systemImage: "minus", amount: -5)
                Button {
                    Task { await vm.sendPowerAction("mute") }
                } label: {
                    Image(systemName: vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(vm.isMuted ? OrbitPalette.warm : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(WatchRowButtonStyle(tint: vm.tint))
                .disabled(!enabled)
                .accessibilityLabel(vm.isMuted ? "Unmute the PC" : "Mute the PC")
                stepButton("Volume Up", systemImage: "plus", amount: 5)
            }
        }
        .onAppear {
            level = vm.volume
            #if DEBUG
            if WatchDebugOptions.crownActive { crownActive = true }
            #endif
        }
        .onChange(of: vm.volume) { _, value in
            if abs(level - value) >= 1 { level = value }
        }
        .onChange(of: vm.selectedTab) { _, page in
            if page != WatchPage.media.rawValue { finish() }
        }
        .onChange(of: enabled) { _, isEnabled in
            if !isEnabled { finish() }
        }
        .onDisappear(perform: finish)
    }

    private var levelCard: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Volume")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "digitalcrown.horizontal.arrow.counterclockwise")
                    .font(.caption2)
                    .foregroundStyle(crownActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                Text(valueText)
                    .font(.orbitReading(20))
                    .foregroundStyle(vm.isMuted ? OrbitPalette.warm : .primary)
                    .orbitLiveNumber()
            }
            OrbitMeter(fraction: enabled ? level / 100 : nil, style: AnyShapeStyle(.tint), height: 6)
                .opacity(vm.isMuted ? 0.35 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OrbitPalette.surface, in: shape)
        .overlay { shape.strokeBorder(crownActive ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 2) }
        .contentShape(shape)
    }

    private var valueText: String {
        guard enabled else { return "—" }
        return vm.isMuted ? "Muted" : "\(Int(level.rounded()))%"
    }

    private func stepButton(_ title: String, systemImage: String, amount: Double) -> some View {
        Button {
            step(amount)
            WKInterfaceDevice.current().play(.click)
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
        }
        .buttonStyle(WatchRowButtonStyle(tint: vm.tint))
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private func step(_ amount: Double) {
        let value = min(100, max(0, vm.volume + amount))
        level = value
        vm.setPCVolume(value)
    }

    private func finish() {
        crownActive = false
        crownFocused = false
    }
}

// MARK: - Games

/// The games Sunshine knows on the PC, from Orbit on iPhone. Tap one to start it on the PC.
struct WatchGamesSheet: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(vm.games) { game in
                Button {
                    vm.launchGame(game)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Text(game.title)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if game.title.caseInsensitiveCompare(vm.activeGame ?? "") == .orderedSame {
                            Text("Playing")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!vm.canControlPC)
                .accessibilityHint("Starts the game on the PC")
            }
            .tint(vm.tint)
            .navigationTitle("Games")
            .containerBackground(OrbitPalette.canvas, for: .navigation)
        }
    }
}
