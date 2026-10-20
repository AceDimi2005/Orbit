import MoonlightCore
import SwiftUI

/// Every Moonlight stream setting: resolution, frame rate, bitrate, codec, HDR, audio, host and input.
struct MoonlightStreamSettingsView: View {
    @ObservedObject var store: MoonlightStreamSettingsStore
    var accent: Color
    var hostSupportsHEVC: Bool? = nil
    var onDone: () -> Void

    private var settings: Binding<MoonlightStreamSettings> { $store.settings }
    private var pixelSize: (width: Int, height: Int) { store.settings.pixelSize }
    private var bitrateMbps: Binding<Double> {
        Binding(get: { Double(store.settings.customBitrateKbps) / 1000 }, set: { store.settings.customBitrateKbps = Int(($0 * 1000).rounded()) })
    }

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                codecSection
                audioSection
                hostSection
                inputSection
                networkSection
                Section {
                    Button("Reset to Moonlight defaults", role: .destructive) { store.resetToDefaults() }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Stream Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onDone() } }
            }
        }
        .tint(accent)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
    }

    private var videoSection: some View {
        Section {
            Picker("Resolution", selection: settings.resolution) {
                ForEach(MoonlightStreamSettings.Resolution.allCases) { resolution in
                    Text(resolution == .native ? "Native · \(pixelSizeText(resolution))" : "\(resolution.title) · \(resolution.detail)").tag(resolution)
                }
            }
            Picker("Frame rate", selection: settings.frameRate) {
                ForEach(MoonlightDeviceCapabilities.frameRateOptions, id: \.self) { fps in Text("\(fps) fps").tag(fps) }
            }
            Toggle("Recommended bitrate", isOn: settings.usesRecommendedBitrate)
            if !store.settings.usesRecommendedBitrate {
                #if os(tvOS)
                HStack {
                    Text("Bitrate")
                    Spacer()
                    Button("−") { bitrateMbps.wrappedValue = max(0.5, bitrateMbps.wrappedValue - 1) }
                    Text(bitrateText(store.settings.customBitrateKbps)).monospacedDigit()
                    Button("+") { bitrateMbps.wrappedValue = min(150, bitrateMbps.wrappedValue + 1) }
                }
                #else
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text(bitrateText(store.settings.customBitrateKbps)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: bitrateMbps, in: 0.5...150, step: 0.5)
                }
                #endif
            }
        } header: {
            Text("Video")
        } footer: {
            Text("Moonlight recommends \(bitrateText(store.settings.recommendedBitrateKbps)) for \(pixelSize.width)×\(pixelSize.height) at \(store.settings.frameRate) fps. Lower it on Wi-Fi or over Tailscale if the picture breaks up.")
        }
    }

    private var codecSection: some View {
        Section {
            Picker("Codec", selection: settings.codec) {
                ForEach(MoonlightStreamSettings.Codec.allCases) { codec in Text(codec.title).tag(codec) }
            }
            Toggle("HDR (HEVC Main 10)", isOn: settings.hdr)
                .disabled(!MoonlightDeviceCapabilities.supportsHDR || store.settings.codec == .h264)
            Toggle("Frame pacing", isOn: settings.framePacing)
        } header: {
            Text("Codec & presentation")
        } footer: {
            Text(codecFootnote)
        }
    }

    private var codecFootnote: String {
        var notes: [String] = []
        notes.append(MoonlightDeviceCapabilities.supportsHEVC ? "This device decodes HEVC in hardware; Automatic prefers it and falls back to H.264." : "This device has no HEVC hardware decoder, so H.264 is used.")
        if let hostSupportsHEVC, !hostSupportsHEVC { notes.append("The PC's encoder reports no HEVC support.") }
        notes.append(MoonlightDeviceCapabilities.supportsHDR ? "HDR needs an HDR-capable PC display and Sunshine's HDR option." : "This display cannot show HDR.")
        notes.append("Frame pacing holds one frame to smooth jitter at the cost of a little latency. AV1 is not available in Orbit yet.")
        return notes.joined(separator: " ")
    }

    private var audioSection: some View {
        Section("Audio") {
            Picker("Layout", selection: settings.audio) {
                ForEach(MoonlightStreamSettings.AudioLayout.allCases) { layout in Text(layout.title).tag(layout) }
            }
            Toggle("Keep playing audio on the PC", isOn: settings.playAudioOnHost)
        }
    }

    private var hostSection: some View {
        Section {
            Toggle("Optimize game settings", isOn: settings.optimizeGameSettings)
            Toggle("Quit app when the stream ends", isOn: settings.quitAppOnDisconnect)
        } header: {
            Text("Host")
        } footer: {
            Text("Optimize asks Sunshine to switch the PC to the stream resolution while streaming. Quitting on disconnect closes the app on the PC instead of leaving it running for a later resume.")
        }
    }

    private var inputSection: some View {
        Section {
            #if os(iOS)
            Picker("Touch", selection: settings.touchMode) {
                ForEach(MoonlightStreamSettings.TouchMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            if store.settings.touchMode == .trackpad {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Pointer speed")
                        Spacer()
                        Text(String(format: "%.1f×", store.settings.trackpadSensitivity)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: settings.trackpadSensitivity, in: 0.5...2.5, step: 0.1)
                }
            }
            #endif
            Toggle("Show statistics overlay", isOn: settings.showStatistics)
        } header: {
            Text("Input & overlay")
        } footer: {
            #if os(iOS)
            Text("Trackpad moves the PC pointer relative to your finger; Touchscreen sends taps where you touch. Game controllers and hardware keyboards work in both modes.")
            #elseif os(macOS)
            Text("Click the video to capture the mouse and keyboard; press Control-Option-Shift-Z to release. Game controllers are forwarded automatically.")
            #else
            Text("Game controllers paired with Apple TV are forwarded; the Siri Remote acts as a trackpad.")
            #endif
        }
    }

    private var networkSection: some View {
        Section {
            Picker("Packet size", selection: settings.packetSize) {
                ForEach(MoonlightStreamSettings.PacketSize.allCases) { size in Text(size.title).tag(size) }
            }
        } header: {
            Text("Network")
        } footer: {
            Text("Choose the VPN size when streaming through Tailscale or another tunnel; smaller packets avoid fragmentation.")
        }
    }

    private func pixelSizeText(_ resolution: MoonlightStreamSettings.Resolution) -> String {
        let size = resolution.pixelSize(native: MoonlightDeviceCapabilities.nativePixelSize)
        return "\(size.width) × \(size.height)"
    }

    private func bitrateText(_ kbps: Int) -> String {
        kbps % 1000 == 0 ? "\(kbps / 1000) Mbps" : String(format: "%.1f Mbps", Double(kbps) / 1000)
    }
}
