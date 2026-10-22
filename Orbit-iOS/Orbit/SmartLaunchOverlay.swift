import SwiftUI

/// While Orbit starts a game on the PC, waking it first when it sleeps: the game, the step
/// Orbit is on, and the satellite circling until the PC answers.
struct SmartLaunchOverlay: View {
    @ObservedObject var vm: OrbitViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                OrbitMark(status: .working, size: 56)
                VStack(spacing: 4) {
                    Text(vm.activeStreamingGame?.title ?? "Your game")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(step)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
                OrbitMeter(fraction: progress, style: AnyShapeStyle(.tint))
                    .frame(width: 160)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 30)
            .frame(maxWidth: 300)
            .orbitGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .animation(OrbitMotion.standard, value: vm.smartLaunchStep)
    }

    private var step: String {
        switch vm.smartLaunchStep {
        case .idle: return ""
        case .checkingPC: return "Checking your PC…"
        case .sendingWoL: return "Waking your PC…"
        case .waitingBoot: return "Waiting for your PC to wake up…"
        case .handshaking: return "Connecting…"
        case .launchingGame: return "Starting it on your PC…"
        case .streaming: return "Opening…"
        }
    }

    private var progress: Double {
        switch vm.smartLaunchStep {
        case .idle: return 0
        case .checkingPC: return 0.15
        case .sendingWoL: return 0.3
        case .waitingBoot: return 0.45
        case .handshaking: return 0.65
        case .launchingGame: return 0.85
        case .streaming: return 1
        }
    }
}
