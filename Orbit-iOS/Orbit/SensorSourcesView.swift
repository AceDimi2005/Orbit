import SwiftUI

/// Where each reading comes from on the PC, and what to do when one is missing.
struct MonitoringSourcesView: View {
    @ObservedObject var vm: OrbitViewModel

    private var m: PCMetrics { vm.metrics }
    private var connected: Bool { m.isOnline && !vm.isDemoMode }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                    Text(subline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }

            Section {
                LabeledContent("Status") {
                    OrbitStatusLabel(text: statusText, color: statusColor, pulsing: connected)
                }
                LabeledContent("Version", value: m.agentVersion ?? "Unknown")
                Button("Check Again") { Task { await vm.refreshMetrics() } }
                    .disabled(vm.isDemoMode)
            } header: {
                Text("Orbit Companion")
            }

            Section {
                LabeledContent("Processor Sensor", value: m.sensorSource ?? "None found")
                LabeledContent("Graphics Sensor", value: m.gpuSource ?? "None found")
                LabeledContent("Processor Temperature", value: temperature(m.cpuTemp))
                LabeledContent("Graphics Temperature", value: temperature(m.gpuTemp))
                if let coolant = m.liquidTemp {
                    LabeledContent("Coolant", value: temperature(coolant))
                }
            } header: {
                Text("Temperatures")
            } footer: {
                Text(m.sensorStatus ?? "Orbit Companion reads temperatures from the PC's sensors. Without a sensor source, temperatures stay hidden instead of being guessed.")
            }

            Section {
                LabeledContent("Game", value: m.activeGameProcess ?? m.activeGame ?? "None running")
                LabeledContent("Frame Rate", value: m.fps.map { "\(Int($0.rounded())) fps" } ?? "Not reported")
                if let source = m.fpsSource {
                    LabeledContent("Source", value: source)
                }
                NavigationLink("Set Up the Frame Rate Counter") { FPSSetupView(vm: vm) }
            } header: {
                Text("Frame Rate")
            } footer: {
                if m.fps == nil, let reason = m.fpsUnavailableReason {
                    Text(reason)
                }
            }

            Section("Network") {
                LabeledContent("Adapter", value: m.networkInterface ?? "Automatic")
                LabeledContent("Receiving", value: OrbitFormat.rate(m.networkDownloadMBps) ?? "Not reported")
                LabeledContent("Sending", value: OrbitFormat.rate(m.networkUploadMBps) ?? "Not reported")
            }
        }
        .orbitListBackground()
        .navigationTitle("Sensor Sources")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.refreshMetrics() }
    }

    private var headline: String {
        if vm.isDemoMode { return "Sample readings" }
        if !m.isOnline { return "Not connected" }
        if m.telemetryAvailable == false { return "Waiting for the first readings" }
        if m.cpuTemp == nil && m.gpuTemp == nil { return "Temperatures are missing" }
        if m.fps == nil && m.activeGame != nil { return "Frame rate is missing" }
        return "Every sensor is reporting"
    }

    private var subline: String {
        if vm.isDemoMode { return "Demo mode shows made-up numbers. Nothing comes from a PC." }
        if !m.isOnline { return "Connect to your PC to see where its readings come from." }
        if m.telemetryAvailable == false { return "Orbit Companion is starting its sensors. This takes a few seconds." }
        if m.cpuTemp == nil && m.gpuTemp == nil { return "Install LibreHardwareMonitor or MSI Afterburner on the PC so Orbit Companion can read them." }
        if m.fps == nil && m.activeGame != nil { return "Set up the frame rate counter to see it while you play." }
        return "Readings come straight from the PC's sensors."
    }

    private var statusText: String {
        if vm.isDemoMode { return "Sample data" }
        if !m.isOnline { return "Not connected" }
        return m.telemetryAvailable == false ? "Starting" : "Connected"
    }

    private var statusColor: Color {
        if vm.isDemoMode { return .secondary }
        if !m.isOnline { return OrbitPalette.warm }
        return m.telemetryAvailable == false ? OrbitPalette.caution : OrbitPalette.online
    }

    private func temperature(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Not reported" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))°C"
    }
}

/// How to get the frame rate while a game runs: RivaTuner through MSI Afterburner, or
/// PresentMon when anti-cheat blocks it.
struct FPSSetupView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var copied: String?
    @State private var showsReadings = false

    private var processName: String {
        let name = vm.metrics.activeGameProcess ?? "game.exe"
        return String(name.filter { !$0.isNewline && !$0.isASCIIControl }.prefix(120))
    }

    private var quotedProcessName: String { "'" + processName.replacingOccurrences(of: "'", with: "''") + "'" }

    private var captureCommand: String {
        "New-Item -ItemType Directory -Force 'C:\\Orbit' | Out-Null\n.\\PresentMon.exe --process_name \(quotedProcessName) --output_file 'C:\\Orbit\\presentmon.csv' --v1_metrics --no_console_stats"
    }

    private var agentCommand: String {
        "$env:ORBIT_PRESENTMON_CSV = 'C:\\Orbit\\presentmon.csv'\n$env:ORBIT_GAME_PROCESSES = \(quotedProcessName)\n.\\start_agent.bat"
    }

    var body: some View {
        OrbitPage {
            status

            VStack(alignment: .leading, spacing: 22) {
                OrbitSectionHeader("Set It Up")
                OrbitStepRow(number: 1, title: "Install MSI Afterburner",
                             text: "It comes with RivaTuner Statistics Server, which counts the frames of the game in front.") {
                    Link(destination: URL(string: "https://www.msi.com/Landing/afterburner/graphics-cards")!) {
                        Label("Download MSI Afterburner", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                OrbitStepRow(number: 2, title: "Turn on monitoring",
                             text: "In Afterburner, open Settings, then Monitoring, and turn on Framerate and the CPU and GPU temperatures.")
                OrbitStepRow(number: 3, title: "Keep RivaTuner running",
                             text: "Leave it in the Windows system tray, with Application detection level set to Low.")
                OrbitStepRow(number: 4, title: "Show it on the PC tab",
                             text: "Add Frame Rate to Right Now to see it at a glance.") {
                    Button("Edit Readings") { showsReadings = true }
                        .font(.subheadline.weight(.semibold))
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                OrbitSectionHeader("If Anti-Cheat Blocks RivaTuner")
                VStack(alignment: .leading, spacing: 14) {
                    Text("Count frames with PresentMon instead. In PowerShell on the PC, in the folder with PresentMon, start the capture, then start Orbit Companion with it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    command(captureCommand, title: "Start the Capture")
                    command(agentCommand, title: "Start Orbit Companion")
                    Link(destination: URL(string: "https://github.com/GameTechDev/PresentMon/releases")!) {
                        Label("Download PresentMon", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .orbitSurface()
            }
        }
        .navigationTitle("Frame Rate Counter")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsReadings) { DashboardCustomizationView(vm: vm) }
    }

    @ViewBuilder
    private var status: some View {
        if let fps = vm.metrics.fps, fps.isFinite {
            OrbitReading(label: vm.metrics.activeGame ?? "Frame rate", value: String(Int(fps.rounded())), unit: "fps",
                         detail: vm.metrics.fpsSource.map { "From \($0)" }, valueSize: 48)
                .orbitSurface()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("No frame rate yet")
                    .font(.title3.weight(.semibold))
                Text(vm.metrics.fpsUnavailableReason ?? "Orbit shows it while a game runs, once the counter below is set up.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        }
    }

    private func command(_ text: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    OrbitHaptics.success()
                    withAnimation(OrbitMotion.quick) { copied = title }
                } label: {
                    Label(copied == title ? "Copied" : "Copy", systemImage: copied == title ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OrbitPalette.well, in: RoundedRectangle(cornerRadius: OrbitMetrics.controlRadius - 4, style: .continuous))
        }
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
