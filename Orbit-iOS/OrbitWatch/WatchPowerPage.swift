import SwiftUI
import WatchKit

/// Power: what you can do to the PC in the state it is in. Wake when it is asleep, Unlock
/// when it is locked, and Lock, Sleep, Restart and Shut Down when it is on. Everything that
/// turns it off asks first.
struct WatchPowerPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var confirmation: WatchPowerAction?
    @State private var showsUnlock = false

    var body: some View {
        let status = WatchPCStatus(vm: vm)
        ScrollView {
            VStack(spacing: 8) {
                switch status {
                case .online:
                    ForEach([WatchPowerAction.lock, .sleep, .restart, .shutdown]) { actionButton($0) }
                case .locked:
                    unlockButton
                    ForEach([WatchPowerAction.sleep, .restart, .shutdown]) { actionButton($0) }
                case .offline:
                    Button {
                        Task { await vm.wakePC() }
                    } label: {
                        WatchButtonLabel(title: "Wake PC", systemImage: "power")
                    }
                    .watchButton(prominent: true)
                    .disabled(!vm.isPhoneReachable)
                    WatchHint(vm.isPhoneReachable
                              ? "Your iPhone sends the wake signal over your network."
                              : "Keep your iPhone nearby to wake the PC. It sends the signal.")
                case .waking:
                    Button {} label: {
                        WatchButtonLabel(title: "Waking…", systemImage: "power", isWorking: true)
                    }
                    .watchButton(prominent: true)
                    .disabled(true)
                    WatchHint("This takes up to a minute.")
                case .connecting:
                    ProgressView()
                        .padding(.vertical, 12)
                    WatchHint("Reaching the PC.")
                case .setup:
                    WatchHint("Pair your PC in Orbit on iPhone to control its power from here.")
                }
                WatchFeedbackLine(vm: vm)
            }
            .watchAnimation(value: status)
            .tint(vm.tint)
        }
        .watchDebugScrollAnchor()
        .navigationTitle("Power")
        .confirmationDialog(confirmation?.question ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible) {
            if let action = confirmation {
                Button(action.title, role: action == .sleep ? nil : .destructive) {
                    confirmation = nil
                    send(action)
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation?.explanation ?? "")
        }
        .sheet(isPresented: $showsUnlock) { WatchUnlockSheet(vm: vm) }
        #if DEBUG
        .onAppear {
            switch WatchDebugOptions.sheet {
            case "unlock": showsUnlock = true
            case "sleep": confirmation = .sleep
            case "shutdown": confirmation = .shutdown
            default: break
            }
        }
        #endif
    }

    private var unlockButton: some View {
        Button {
            showsUnlock = true
        } label: {
            WatchButtonLabel(title: "Unlock", systemImage: "lock.open", isWorking: vm.isUnlocking)
        }
        .watchButton(prominent: true)
        .disabled(vm.isUnlocking)
    }

    private func actionButton(_ action: WatchPowerAction) -> some View {
        Button {
            if action.asksFirst {
                confirmation = action
            } else {
                send(action)
            }
        } label: {
            WatchButtonLabel(title: action.title, systemImage: action.systemImage, alignment: .leading,
                             isDestructive: action == .shutdown)
        }
        .watchButton()
        .disabled(!vm.canControlPC)
    }

    private func send(_ action: WatchPowerAction) {
        Task { await vm.sendPowerAction(action.rawValue) }
    }
}

/// Power actions with the words the iPhone uses to confirm them.
enum WatchPowerAction: String, Identifiable {
    case lock, sleep, restart, shutdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lock: return "Lock"
        case .sleep: return "Sleep"
        case .restart: return "Restart"
        case .shutdown: return "Shut Down"
        }
    }

    var systemImage: String {
        switch self {
        case .lock: return "lock"
        case .sleep: return "moon"
        case .restart: return "arrow.clockwise"
        case .shutdown: return "power"
        }
    }

    /// Locking is harmless; everything that stops the PC asks first.
    var asksFirst: Bool { self != .lock }

    var question: String {
        switch self {
        case .lock: return "Lock the PC?"
        case .sleep: return "Put the PC to sleep?"
        case .restart: return "Restart the PC?"
        case .shutdown: return "Shut down the PC?"
        }
    }

    var explanation: String {
        switch self {
        case .lock: return "Windows shows the sign-in screen."
        case .sleep: return "You can wake it again from Orbit."
        case .restart, .shutdown: return "Unsaved work in open apps on the PC may be lost."
        }
    }
}

// MARK: - Unlock

/// Asks for the Windows password once. The iPhone types it on the PC's sign-in screen
/// through a short stream; neither device keeps it.
struct WatchUnlockSheet: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Windows password for \(vm.pcName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("Password", text: $password)
                    Button {
                        let typed = password
                        password = ""
                        Task {
                            await vm.unlockPC(password: typed)
                            dismiss()
                        }
                    } label: {
                        WatchButtonLabel(title: vm.isUnlocking ? "Unlocking…" : "Unlock", systemImage: "lock.open",
                                         isWorking: vm.isUnlocking)
                    }
                    .watchButton(prominent: true)
                    .disabled(password.isEmpty || vm.isUnlocking || !vm.isPhoneReachable)
                    Text(vm.isPhoneReachable
                         ? "Your iPhone types it once on the sign-in screen. It's never saved."
                         : "Keep your iPhone nearby. It types the password for the watch.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(vm.tint)
            }
            .navigationTitle("Unlock")
            .containerBackground(OrbitPalette.canvas, for: .navigation)
        }
    }
}
