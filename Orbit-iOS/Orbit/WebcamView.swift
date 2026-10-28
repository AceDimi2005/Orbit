import AVFoundation
import SwiftUI
import UIKit

// iPhone as a PC webcam (DESIGN F10, Orbit Pro, Labs): Tools › Webcam. The camera, the connection and
// the PC setup live in `OrbitWebcamCapture.swift` and `OrbitWebcamModel.swift`.

/// Tools tile and `orbit://webcam` destination: Orbit Pro gate around the webcam screen.
struct WebcamScreen: View {
    @ObservedObject var vm: OrbitViewModel
    var showsDoneButton = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OrbitProGate(title: "Webcam",
                     message: "Use this \(OrbitWebcamDevice.word) as a webcam for Zoom, Teams, Discord, OBS and browsers on your PC. Part of Orbit Pro.") {
            WebcamView(vm: vm)
        }
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct WebcamView: View {
    @ObservedObject var vm: OrbitViewModel
    @StateObject private var model = OrbitWebcamModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @State private var confirmsSetup = false
    @State private var confirmsRemoval = false

    private var pcName: String { model.pcName }
    private var device: String { OrbitWebcamDevice.word }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 || (geometry.size.width > geometry.size.height && geometry.size.width >= 560)
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline || model.isDemo)
                if wide {
                    HStack(alignment: .top, spacing: 18) {
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 14) {
                                previewCard
                                streamControls
                                notes
                            }
                            .padding(.vertical, 12)
                        }
                        .frame(maxWidth: .infinity)
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 14) {
                                pcCard
                                qualityCard
                                compatibilityCard
                            }
                            .padding(.vertical, 12)
                        }
                        .frame(width: min(420, geometry.size.width * 0.42))
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: 1380)
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            previewCard
                            streamControls
                            notes
                            pcCard.id("webcam.pc")
                            qualityCard.id("webcam.picture")
                            compatibilityCard.id("webcam.compatibility")
                        }
                        .frame(maxWidth: 720)
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity)
                    }
                    .refreshable { await model.refresh() }
                    #if DEBUG
                    .modifier(OrbitSelfTestScroll())
                    #endif
                }
            }
        }
        .navigationTitle("Webcam")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .overlay { if model.isDimmed { dimmedOverlay } }
        .toolbar(model.isDimmed ? .hidden : .automatic, for: .navigationBar, .tabBar)
        .statusBarHidden(model.isDimmed)
        .persistentSystemOverlays(model.isDimmed ? .hidden : .automatic)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.isDimmed)
        .onAppear {
            model.appear(vm)
            #if DEBUG
            model.runSelfTestIfRequested()
            #endif
        }
        .onDisappear { model.disappear() }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .onChange(of: vm.connectionID) { _, _ in model.configure(vm) }
        .onChange(of: vm.selectedPCID) { _, _ in model.configure(vm) }
        .onChange(of: vm.isDemoMode) { _, _ in model.configure(vm) }
        .onChange(of: vm.metrics.isOnline) { _, online in model.onlineChanged(online) }
        .alert("Set up the webcam on \(pcName)?", isPresented: $confirmsSetup) {
            Button("Set Up") { model.installOnPC() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orbit installs Softcam, a small open-source virtual camera, on the PC. Windows shows one administrator prompt on the PC's screen: choose Yes there. Setup can take up to 2 minutes.")
        }
        .alert("Remove the webcam from \(pcName)?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) { model.removeFromPC() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Windows asks for administrator permission once on the PC. Apps on the PC lose the \"\(model.cameraName)\" camera.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !model.isDemo {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh PC Status", systemImage: "arrow.clockwise")
                    }
                    if model.status?.isSetUp == true || model.status?.installed == true {
                        Button(role: .destructive) {
                            confirmsRemoval = true
                        } label: {
                            Label("Remove Webcam from PC…", systemImage: "trash")
                        }
                        .disabled(model.setupPhase != .idle || model.pcProblem != nil)
                    }
                }
                if model.hasBothCameras {
                    Button {
                        model.switchLens()
                    } label: {
                        Label(model.lens == .front ? "Use Back Camera" : "Use Front Camera", systemImage: "arrow.triangle.2.circlepath.camera")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Webcam Options")
        }
    }

    // MARK: Preview

    private var previewCard: some View {
        ZStack {
            Color.black
            if model.canUseCamera {
                OrbitWebcamPreview(camera: model.camera)
                    .accessibilityElement()
                    .accessibilityLabel("Camera preview")
                    .accessibilityValue(model.lens == .front ? "Front camera, mirrored like a mirror" : "Back camera")
            } else {
                cameraAccessPlaceholder
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        // The picture has a fixed size: its overlays grow with Dynamic Type only up to the point
        // where they would cover each other (VoiceOver still reads them in full).
        .overlay(alignment: .topLeading) {
            previewStatusPill.padding(10)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .overlay(alignment: .topTrailing) {
            if model.hasBothCameras && model.canUseCamera {
                Button {
                    model.switchLens()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.orbitPressable)
                .padding(6)
                .accessibilityLabel(model.lens == .front ? "Switch to the back camera" : "Switch to the front camera")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.phase == .streaming {
                HStack(spacing: 6) {
                    OrbitStatChip(label: "FPS", value: String(format: "%.0f", model.sentFPS))
                    OrbitStatChip(label: "Mbps", value: String(format: "%.1f", model.megabitsPerSecond))
                    if let format = model.streamFormat {
                        OrbitStatChip(label: "Size", value: model.isThermalLimited ? "720p" : "\(format.height)p")
                    }
                }
                .background(.black.opacity(0.35), in: Capsule())
                .padding(10)
                .accessibilityElement(children: .combine)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            } else if model.lens == .front && model.canUseCamera {
                Text("Mirrored preview · the PC gets the true picture")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(10)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityHidden(true) // The preview's VoiceOver value says it.
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(model.phase == .streaming ? Color.red.opacity(0.7) : .white.opacity(0.1), lineWidth: model.phase == .streaming ? 2 : 1)
        )
    }

    @ViewBuilder
    private var previewStatusPill: some View {
        switch model.phase {
        case .streaming:
            OrbitStatusPill(text: model.isDemo ? "LIVE · DEMO" : "LIVE", tint: .red, pulsing: true)
        case .connecting:
            OrbitStatusPill(text: "Connecting…", tint: .yellow, icon: "hourglass")
        case .reconnecting(let attempt):
            OrbitStatusPill(text: "Reconnecting (\(attempt))…", tint: .orange, icon: "arrow.clockwise")
        case .idle:
            if case .interrupted = model.cameraState {
                OrbitStatusPill(text: "Camera paused", tint: .orange, icon: "pause.fill")
            } else if model.canUseCamera {
                OrbitStatusPill(text: "Preview", tint: .white.opacity(0.85), icon: "eye.fill")
            }
        }
    }

    @ViewBuilder
    private var cameraAccessPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            if !model.hasAnyCamera {
                Text("No camera").font(.headline)
                Text("This \(device) has no camera Orbit can use.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if model.cameraAccess == .notDetermined {
                Text("Camera access").font(.headline)
                Button("Allow Camera") { model.requestCameraAccess() }
                    .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent))
            } else {
                Text("Camera access is off").font(.headline)
                Text("Turn on Camera for Orbit in iOS Settings to use this \(device) as a webcam.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent))
            }
        }
        .padding(20)
    }

    // MARK: Start / stop

    private var streamControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.phase.isActive {
                Button {
                    model.stopStreaming()
                } label: {
                    Label(model.phase == .streaming ? "Stop Streaming" : "Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(OrbitProminentButtonStyle(colors: [Color(red: 1, green: 0.32, blue: 0.32), Color(red: 0.86, green: 0.16, blue: 0.24)], foreground: .white))
                .accessibilityHint("Stops sending this \(device)'s camera to \(pcName).")
            } else {
                Button {
                    model.startStreaming()
                } label: {
                    Label("Start Streaming", systemImage: "web.camera.fill")
                }
                .buttonStyle(OrbitProminentButtonStyle(colors: [Color(red: 0.36, green: 0.95, blue: 0.62), Color(red: 0.16, green: 0.78, blue: 0.55)]))
                .disabled(model.startBlocker != nil)
                .accessibilityHint(model.startBlocker ?? "Sends this \(device)'s camera to \(pcName) as the DirectShow Softcam camera.")
                if let blocker = model.startBlocker {
                    Text(blocker)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.phase.isActive {
                appConnectionRow
                HStack(spacing: 10) {
                    Button {
                        model.isDimmed = true
                        OrbitHaptics.tap()
                    } label: {
                        Label("Dim Screen", systemImage: "moon.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OrbitGlassButtonStyle())
                    .disabled(model.phase != .streaming)
                    .accessibilityHint("Darkens this screen while the camera keeps streaming. Tap the screen to bring the controls back.")
                }
                Text("Keep Orbit open: the screen stays on while streaming, and the camera stops if you leave Orbit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, tint: model.phase.isActive ? .red : .green)
    }

    private var appConnectionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            OrbitIconBadge(systemName: model.appConnected ? "video.fill" : "video.badge.ellipsis", tint: model.appConnected ? .mint : .secondary, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                if model.isDemo {
                    Text("Demo mode").font(.subheadline.weight(.semibold))
                    Text("The camera and the encoder run, but nothing is sent to a PC.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.phase != .streaming {
                    Text(model.phase == .connecting ? "Connecting to \(pcName)…" : "Reconnecting to \(pcName)…")
                        .font(.subheadline.weight(.semibold))
                    Text("Apps that use the camera keep it while Orbit reconnects.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.appConnected {
                    Text("An app on \(pcName) opened the camera").font(.subheadline.weight(.semibold))
                    Text("Your picture is live in apps that use \"\(model.cameraName)\".")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Waiting for an app on \(pcName)").font(.subheadline.weight(.semibold))
                    Text("In Zoom, Teams, Discord, OBS or your browser, choose \"\(model.cameraName)\" as the camera.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Notes

    @ViewBuilder
    private var notes: some View {
        if let note = model.streamNote {
            noteCard(title: note.title, message: note.message, icon: note.icon, tint: tint(for: note.kind))
        }
        if case .interrupted(let message) = model.cameraState {
            noteCard(title: "Camera paused", message: message + (model.phase == .streaming ? " \(pcName) shows the last picture until the camera is back." : ""),
                     icon: "pause.circle.fill", tint: .orange)
        }
        if case .failed(let message) = model.cameraState {
            noteCard(title: "Camera unavailable", message: message, icon: "video.slash.fill", tint: .orange)
        }
        if model.isThermalLimited {
            noteCard(title: "Running cooler", message: "Your \(device) is hot, so Orbit sends 720p at 15 fps until it cools down. Apps on the PC keep the camera.",
                     icon: "thermometer.sun.fill", tint: .orange)
        }
        // While streaming, the status row under Stop already says it.
        if model.isDemo && !model.phase.isActive {
            noteCard(title: "Demo mode", message: "The preview and the encoder work, but nothing is sent to a PC. Pair your PC to use this \(device) as its webcam.",
                     icon: "sparkles", tint: .orange)
        }
    }

    private func tint(for kind: OrbitWebcamModel.Note.Kind) -> Color {
        switch kind {
        case .info: return .cyan
        case .warning: return .orange
        case .error: return .red
        }
    }

    /// Like `OrbitNotice`, but the whole message is always shown (PC sentences can be long).
    private func noteCard(title: String, message: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OrbitIconBadge(systemName: icon, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, tint: tint)
        .accessibilityElement(children: .combine)
    }

    // MARK: PC

    private var pcCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: "desktopcomputer", tint: theme.accent, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pcName).font(.headline.weight(.bold)).lineLimit(1)
                    pcStatusPill
                }
                Spacer(minLength: 0)
                if model.isLoadingStatus && model.status == nil { ProgressView() }
            }
            .accessibilityElement(children: .combine)

            if let problem = model.pcProblem {
                pcDetail(problem.message, icon: problem.icon, tint: .orange)
            } else if let error = model.featuresError {
                pcDetail("Couldn't reach \(pcName). \(error)", icon: "exclamationmark.triangle.fill", tint: .orange)
            } else if let status = model.status {
                statusDetails(status)
            } else if let error = model.statusError {
                pcDetail("Couldn't read the webcam status. \(error)", icon: "exclamationmark.triangle.fill", tint: .orange)
            } else if !model.isDemo {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading the webcam status of \(pcName)…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let message = model.setupMessage {
                pcDetail(message, icon: "checkmark.circle.fill", tint: .mint)
            }
            // The PC's reason already says it (a missing Visual C++ runtime): show it once.
            if let error = model.setupError, error != model.status?.reason {
                pcDetail(error, icon: "exclamationmark.triangle.fill", tint: .red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 20, tint: theme.accent)
    }

    @ViewBuilder
    private var pcStatusPill: some View {
        if model.isDemo {
            OrbitStatusPill(text: "Demo", tint: .orange)
        } else if model.pcProblem != nil {
            OrbitStatusPill(text: "Not available", tint: .orange)
        } else if model.setupPhase == .installing || model.status?.installing == true {
            OrbitStatusPill(text: "Setting up…", tint: .yellow, icon: "hourglass")
        } else if model.setupPhase == .removing || model.status?.uninstalling == true {
            OrbitStatusPill(text: "Removing…", tint: .yellow, icon: "hourglass")
        } else if let status = model.status {
            if status.isReady {
                OrbitStatusPill(text: model.otherDeviceStreaming ? "In use by another device" : "Webcam ready", tint: .mint)
            } else if status.isUnsupportedPC {
                OrbitStatusPill(text: "Not supported", tint: .orange)
            } else if status.isSetUp {
                OrbitStatusPill(text: "Set up", tint: .yellow)
            } else {
                OrbitStatusPill(text: "Not set up", tint: .orange)
            }
        } else {
            OrbitStatusPill(text: "Checking…", tint: .secondary)
        }
    }

    @ViewBuilder
    private func statusDetails(_ status: OrbitWebcamPCStatus) -> some View {
        let busy = model.setupPhase != .idle || status.isBusy
        if busy {
            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                Text(stageText(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else if let reason = status.reason, !status.isSetUp || status.runtimeMissing || !model.phase.isActive {
            pcDetail(reason, icon: status.isSetUp ? "info.circle.fill" : "exclamationmark.circle.fill", tint: status.isSetUp ? .cyan : .orange)
        }

        if !busy, model.otherDeviceStreaming {
            pcDetail("Another iPhone or iPad is streaming to this PC's webcam right now. Starting here takes over the camera.",
                     icon: "person.2.fill", tint: .yellow)
        }

        if status.isSetUp {
            LabeledContent("Camera on the PC", value: "\(status.cameraName ?? model.cameraName)\(status.softcamVersion.map { " \($0)" } ?? "")")
                .font(.caption)
        }
        if let runtime = status.runtime {
            LabeledContent("Visual C++ runtime", value: runtimeSummary(runtime))
                .font(.caption)
            if runtime.ok == false, let commands = runtime.commands, !commands.isEmpty, !busy {
                runtimeCommands(commands)
            }
        }

        if !status.isSetUp && !busy && !model.isDemo && !status.isUnsupportedPC {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    confirmsSetup = true
                } label: {
                    Label("Set Up on PC", systemImage: "arrow.down.app.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent))
                .disabled(model.pcProblem != nil || status.runtimeMissing)
                Text("Orbit installs Softcam, a small open-source virtual camera, on \(pcName). Windows asks for administrator permission once: a prompt appears on the PC's screen (it may only flash in the taskbar). Choose Yes there. The PC needs the Microsoft Visual C++ 2015–2022 Redistributable (x64 and x86); Orbit checks it first.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stageText(_ status: OrbitWebcamPCStatus) -> String {
        if model.setupPhase == .removing || status.uninstalling == true {
            return status.installStage == "waitingForApproval"
                ? "Approve the Windows prompt on \(pcName): choose Yes to remove the webcam. No prompt on screen? Click the flashing shield in the taskbar."
                : "Removing the webcam from \(pcName)…"
        }
        switch status.installStage {
        case "waitingForApproval":
            return "Approve the Windows prompt on \(pcName): choose Yes to finish the setup. No prompt on screen? Click the flashing shield in the taskbar."
        case "verifying":
            return "Checking that Windows lists the camera…"
        default:
            return "Getting the webcam ready on \(pcName)…"
        }
    }

    private func runtimeSummary(_ runtime: OrbitWebcamPCStatus.Runtime) -> String {
        var parts: [String] = []
        for arch in ["x64", "x86"] {
            let version = arch == "x64" ? runtime.x64 : runtime.x86
            let missing = runtime.missing?.contains(arch) == true
            if version == nil && !missing { continue } // 32-bit Windows reports no x64 entry.
            parts.append(version.map { "\(arch) \($0)" + (missing ? " (too old)" : "") } ?? "\(arch) missing")
        }
        return parts.isEmpty ? (runtime.ok == true ? "OK" : "Missing") : parts.joined(separator: " · ")
    }

    private func runtimeCommands(_ commands: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run on the PC (Terminal):")
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(commands, id: \.self) { command in
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { runtimeButtons }
                VStack(alignment: .leading, spacing: 8) { runtimeButtons }
            }
            if let message = model.clipboardMessage {
                Text(message).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var runtimeButtons: some View {
        Button {
            model.sendRuntimeCommandsToPC()
        } label: {
            Label("Copy to PC Clipboard", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent))
        Button {
            model.copyRuntimeCommands()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(OrbitGlassButtonStyle())
    }

    private func pcDetail(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: Quality

    private var qualityCard: some View {
        let locked = model.phase.isActive
        return VStack(alignment: .leading, spacing: 12) {
            OrbitSectionHeader("Picture", icon: "camera.aperture")
            VStack(alignment: .leading, spacing: 6) {
                Text("Resolution").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Resolution", selection: $model.resolution) {
                    ForEach(OrbitWebcamResolution.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(locked)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Frame rate").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Frame rate", selection: $model.frameRate) {
                    Text("30 fps").tag(30)
                    Text("15 fps").tag(15)
                }
                .pickerStyle(.segmented)
                .disabled(locked)
            }
            if model.hasBothCameras {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Camera").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Camera", selection: $model.lens) {
                        ForEach(OrbitWebcamLens.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            Text(locked
                 ? "Stop streaming to change the resolution or frame rate. Apps on the PC then need to reopen the camera."
                 : "720p at 30 fps works well on most Wi-Fi networks. 1080p looks sharper and needs a strong connection. Hold the \(device) sideways for a full 16:9 picture.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 20, tint: .cyan)
    }

    // MARK: Compatibility

    private var compatibilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OrbitSectionHeader("Works with", icon: "checkmark.seal.fill")
                Text("LABS · BETA")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.yellow, in: Capsule())
                    .padding(.top, 6)
                    .accessibilityLabel("Labs feature, beta")
            }
            FlowChips(items: ["Chrome", "Edge", "Teams", "Discord", "Zoom", "OBS"])
            Text("Apps that use DirectShow cameras see your \(device) as \"\(model.cameraName)\". Choose it in the app's camera settings. The Windows Camera app and Microsoft Store apps can't see it. Video only: keep using the PC's microphone. Apps that were open during setup need a restart to find the camera.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The picture travels only over your local network, encrypted, straight to your PC.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 20, tint: .green)
    }

    // MARK: Dimmed screen

    private var dimmedOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "web.camera.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.8))
                Text(model.phase == .streaming ? "Streaming to \(pcName)" : "Webcam paused")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
                Text(model.phase == .streaming ? String(format: "%.0f fps · %@", model.sentFPS, model.appConnected ? "in use on the PC" : "waiting for an app") : "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                Text("Tap to show the controls")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 8)
            }
            .multilineTextAlignment(.center)
            .padding(24)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.isDimmed = false }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Screen dimmed. Streaming to \(pcName).")
        .accessibilityHint("Double-tap to show the controls.")
        .accessibilityAction { model.isDimmed = false }
        .onChange(of: model.phase) { _, phase in if phase == .idle { model.isDimmed = false } }
    }
}

/// App names as small chips that wrap onto more lines.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        OrbitWebcamFlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OrbitWebcamFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
