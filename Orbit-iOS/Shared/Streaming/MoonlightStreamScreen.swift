import Combine
import MoonlightCore
import SwiftUI

/// Full-screen stream: video surface, a translucent overlay that gets out of the way, and the
/// launch / connecting / ended states. Shared by iOS, tvOS and macOS.
struct MoonlightStreamScreen: View {
    @ObservedObject var controller: MoonlightStreamController
    var accent: Color
    @StateObject private var handle = MoonlightSurfaceHandle()
    @State private var overlayVisible = true
    @State private var statsVisible = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = controller.session, let request = controller.request {
                MoonlightSessionLayer(session: session, request: request, handle: handle, accent: accent,
                                      overlayVisible: $overlayVisible, statsVisible: $statsVisible,
                                      onEnd: { quit in controller.end(quitApp: quit) }, onReconnect: { controller.retry() })
            } else {
                MoonlightLaunchStateView(controller: controller, accent: accent)
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        .onAppear { statsVisible = controller.request?.settings.showStatistics ?? false }
        .onDisappear { if controller.isPresented { controller.end(quitApp: false) } }
    }
}

// MARK: - Launching

private struct MoonlightLaunchStateView: View {
    @ObservedObject var controller: MoonlightStreamController
    var accent: Color

    var body: some View {
        VStack(spacing: 18) {
            if let busy = controller.busyError {
                MoonlightStreamCard(icon: "exclamationmark.circle", tint: .orange, title: "\(busy.runningTitle ?? "Another app") is running",
                                    message: "Sunshine streams one app at a time. Quit it to start \(controller.request?.app.title ?? "this app"), or watch it instead.") {
                    Button { controller.quitRunningAppAndLaunch() } label: { Label("Quit it and stream", systemImage: "stop.fill") }
                        .buttonStyle(MoonlightOverlayButtonStyle(tint: .orange, prominent: true))
                    if busy.runningTitle != nil {
                        Button { controller.streamRunningAppInstead() } label: { Label("Watch \(busy.runningTitle ?? "it") instead", systemImage: "play.fill") }
                            .buttonStyle(MoonlightOverlayButtonStyle(tint: accent))
                    }
                    Button("Cancel") { controller.end(quitApp: false) }.buttonStyle(MoonlightOverlayButtonStyle(tint: .white))
                }
            } else if let error = controller.launchError {
                MoonlightStreamCard(icon: "xmark.octagon", tint: .orange, title: "Could not start the stream", message: error) {
                    Button { controller.retry() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                        .buttonStyle(MoonlightOverlayButtonStyle(tint: accent, prominent: true))
                    Button("Close") { controller.end(quitApp: false) }.buttonStyle(MoonlightOverlayButtonStyle(tint: .white))
                }
            } else {
                MoonlightStreamCard(icon: nil, tint: accent, title: "Starting \(controller.request?.app.title ?? "stream")",
                                    message: "Asking Sunshine on \(controller.request?.pcName ?? "the PC") to launch it…", spinning: true) {
                    Button("Cancel") { controller.end(quitApp: false) }.buttonStyle(MoonlightOverlayButtonStyle(tint: .white))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Live session

private struct MoonlightSessionLayer: View {
    @ObservedObject var session: MoonlightStreamSession
    let request: MoonlightStreamController.Request
    @ObservedObject var handle: MoonlightSurfaceHandle
    let accent: Color
    @Binding var overlayVisible: Bool
    @Binding var statsVisible: Bool
    let onEnd: (Bool) -> Void
    let onReconnect: () -> Void
    @State private var hideTask: Task<Void, Never>?
    @State private var confirmEnd = false
    @State private var captureHintVisible = false
    @State private var captureHintTask: Task<Void, Never>?

    private var isStreaming: Bool { session.phase == .streaming }

    var body: some View {
        ZStack {
            MoonlightStreamSurface(session: session, settings: request.settings, handle: handle, onToggleOverlay: { toggleOverlay() },
                                   onEndStream: { onEnd(false) })
                .ignoresSafeArea()

            switch session.phase {
            case .connecting(let stage):
                MoonlightStreamCard(icon: nil, tint: accent, title: "Connecting to \(request.pcName)", message: stage, spinning: true) {
                    Button("Cancel") { onEnd(false) }.buttonStyle(MoonlightOverlayButtonStyle(tint: .white))
                }
            case .failed(let message):
                MoonlightStreamCard(icon: "xmark.octagon", tint: .orange, title: "Stream failed", message: message) {
                    Button { onReconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                        .buttonStyle(MoonlightOverlayButtonStyle(tint: accent, prominent: true))
                    Button("Close") { onEnd(false) }.buttonStyle(MoonlightOverlayButtonStyle(tint: .white))
                }
            case .ended(let message):
                MoonlightStreamCard(icon: "checkmark.circle", tint: accent, title: "Stream ended", message: message ?? "\(request.app.title) is no longer streaming.") {
                    Button { onReconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                        .buttonStyle(MoonlightOverlayButtonStyle(tint: accent, prominent: true))
                    Button("Close") { onEnd(false) }.buttonStyle(MoonlightOverlayButtonStyle(tint: .white))
                }
            case .streaming, .idle:
                EmptyView()
            }

            if isStreaming {
                VStack(spacing: 0) {
                    if overlayVisible || confirmEnd {
                        topBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom) {
                        if statsVisible { MoonlightStatisticsPanel(statistics: session.statistics, accent: accent).transition(.opacity) }
                        Spacer(minLength: 0)
                        if overlayVisible { hint.transition(.opacity) }
                    }
                    .padding(16)
                }
                .animation(.spring(response: 0.32, dampingFraction: 1), value: overlayVisible)
                .animation(.spring(response: 0.32, dampingFraction: 1), value: statsVisible)
            }

            #if os(macOS)
            if isStreaming, captureHintVisible {
                VStack {
                    Spacer()
                    Text("Mouse and keyboard captured  ·  ⌃⌥⇧Z releases them  ·  ⌃⌥⇧Q ends the stream")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                        .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
            #endif
        }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: captureHintVisible)
        .onChange(of: session.phase) { _, phase in
            if phase == .streaming { overlayVisible = true; scheduleHide() } else { hideTask?.cancel(); overlayVisible = true }
        }
        .onChange(of: handle.mouseCaptured) { _, captured in
            if captured {
                overlayVisible = false
                captureHintVisible = true
                captureHintTask?.cancel()
                captureHintTask = Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard !Task.isCancelled else { return }
                    captureHintVisible = false
                }
            } else {
                captureHintVisible = false
                overlayVisible = true
                scheduleHide()
            }
        }
        .confirmationDialog("End the stream?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("Disconnect") { onEnd(false) }
            Button("Quit \(request.app.title) on PC", role: .destructive) { onEnd(true) }
            Button("Keep streaming", role: .cancel) { scheduleHide() }
        } message: {
            Text("Disconnecting leaves \(request.app.title) running on \(request.pcName); you can resume later.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(session.connectionIsPoor ? Color.orange : accent).frame(width: 8, height: 8)
                Text(request.app.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("·").foregroundStyle(.secondary)
                Text(request.pcName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if session.isHDR { Text("HDR").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 2).background(accent.opacity(0.25), in: Capsule()) }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                overlayButton("chart.bar.xaxis", label: "Statistics", active: statsVisible) { statsVisible.toggle(); scheduleHide() }
                #if os(iOS)
                overlayButton("keyboard", label: "Keyboard", active: handle.keyboardVisible) { handle.toggleKeyboard(); scheduleHide() }
                #endif
                #if os(macOS)
                overlayButton("cursorarrow.click.2", label: "Capture mouse", active: false) { handle.captureMouse() }
                #endif
                overlayButton("xmark", label: "End stream", active: false, tint: .orange) { confirmEnd = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var hint: some View {
        Group {
            #if os(iOS)
            Text(request.settings.touchMode == .trackpad ? "Drag to move · tap to click · two fingers scroll · hold to drag · three-finger tap for controls" : "Touch the screen directly · three-finger tap for controls")
            #elseif os(macOS)
            Text(handle.mouseCaptured ? "⌃⌥⇧Z releases the mouse and keyboard · ⌃⌥⇧Q ends the stream" : "Click the video to capture mouse and keyboard · ⌃⌥⇧Q or the ✕ button ends the stream")
            #else
            Text("Touch surface moves the pointer · click selects · play/pause right-clicks · Menu leaves the stream")
            #endif
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func overlayButton(_ symbol: String, label: String, active: Bool, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(MoonlightOverlayButtonStyle(tint: tint ?? accent, prominent: active, circular: true))
        .accessibilityLabel(label)
    }

    private func toggleOverlay() {
        overlayVisible.toggle()
        if overlayVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, !confirmEnd else { return }
            #if os(macOS)
            guard handle.mouseCaptured else { return }
            #endif
            overlayVisible = false
        }
    }
}

// MARK: - Pieces

private struct MoonlightStatisticsPanel: View {
    let statistics: MoonlightStreamStatistics
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Video", statistics.width > 0 ? "\(statistics.width)×\(statistics.height) @ \(statistics.frameRate) · \(statistics.codec)\(statistics.hdr ? " HDR" : "")" : "—")
            row("Decoded", "\(statistics.framesPerSecond) fps · \(statistics.pendingFrames) queued")
            row("Bitrate", "\(statistics.bitrateKbps / 1000) Mbps")
            row("Latency", statistics.roundTripMs.map { "\($0) ms ±\(statistics.roundTripVarianceMs ?? 0)" } ?? "—")
            row("Host", statistics.averageHostLatencyMs.map { String(format: "%.1f ms", $0) } ?? "—")
            row("Lost", "\(statistics.droppedFrames) of \(statistics.receivedFrames + statistics.droppedFrames)")
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(accent).frame(width: 58, alignment: .leading)
            Text(value).foregroundStyle(.primary)
        }
    }
}

private struct MoonlightStreamCard<Actions: View>: View {
    let icon: String?
    let tint: Color
    let title: String
    let message: String
    var spinning = false
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            if spinning {
                ProgressView().controlSize(.large).tint(tint)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 34, weight: .medium)).foregroundStyle(tint)
            }
            Text(title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { actions }.padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .padding(24)
    }
}

struct MoonlightOverlayButtonStyle: ButtonStyle {
    var tint: Color
    var prominent = false
    var circular = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, circular ? 0 : 14)
            .padding(.vertical, circular ? 0 : 9)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background {
                if circular {
                    Circle().fill(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial))
                } else {
                    Capsule().fill(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial))
                }
            }
            .overlay {
                if circular { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1) } else { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
            }
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}
