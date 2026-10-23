import MoonlightCore
import SwiftUI

#if os(tvOS)
/// tvOS version of the stream settings: every choice is a focusable row that opens a list of
/// options (the Form pickers used on iOS render as an empty panel on tvOS 26), toggles stay inline,
/// and the bitrate is picked from Moonlight's presets or kept at the recommended value.
struct MoonlightStreamSettingsView: View {
    @ObservedObject var store: MoonlightStreamSettingsStore
    var accent: Color
    var hostSupportsHEVC: Bool? = nil
    var onDone: () -> Void

    private static let bitratePresetsKbps = [2_000, 5_000, 8_000, 10_000, 15_000, 20_000, 25_000, 30_000, 40_000, 50_000, 60_000, 80_000, 100_000, 120_000, 150_000]

    enum Setting: String, Hashable, CaseIterable {
        case resolution, frameRate, bitrate, codec, audio, packetSize
    }
    @State private var path: [Setting] = []

    private var settings: Binding<MoonlightStreamSettings> { $store.settings }
    /// Apple TV streams 16:9 at its output mode; there is no Picture choice here.
    private var pixelSize: MoonlightStreamSize { store.settings.pixelSize(hostSupportsHEVC: hostSupportsHEVC) }
    private var recommendedBitrateKbps: Int { store.settings.recommendedBitrateKbps(for: pixelSize) }

    /// 0 stands for "recommended"; any other value is a manual bitrate in kbps.
    private var bitrateSelection: Binding<Int> {
        Binding(get: { store.settings.usesRecommendedBitrate ? 0 : store.settings.customBitrateKbps },
                set: { value in
                    if value == 0 { store.settings.usesRecommendedBitrate = true } else { store.settings.usesRecommendedBitrate = false; store.settings.customBitrateKbps = value }
                })
    }

    private var bitrateOptions: [TVStreamOption<Int>] {
        var options = [TVStreamOption(value: 0, title: "Recommended", detail: "\(bitrateText(recommendedBitrateKbps)) for \(pixelSize.width)×\(pixelSize.height) at \(store.settings.frameRate) fps")]
        var presets = Self.bitratePresetsKbps
        if !store.settings.usesRecommendedBitrate, !presets.contains(store.settings.customBitrateKbps) { presets.append(store.settings.customBitrateKbps); presets.sort() }
        options += presets.map { TVStreamOption(value: $0, title: bitrateText($0), detail: nil) }
        return options
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    optionRow("Resolution", value: resolutionText(store.settings.resolution), setting: .resolution)
                    optionRow("Frame rate", value: "\(store.settings.frameRate) fps", setting: .frameRate)
                    optionRow("Bitrate", value: store.settings.usesRecommendedBitrate ? "Recommended · \(bitrateText(recommendedBitrateKbps))" : bitrateText(store.settings.customBitrateKbps),
                              setting: .bitrate)
                } header: {
                    Text("Video")
                } footer: {
                    Text("Moonlight recommends \(bitrateText(recommendedBitrateKbps)) for \(pixelSize.width)×\(pixelSize.height) at \(store.settings.frameRate) fps. Lower it on Wi-Fi or away from home if the picture breaks up.")
                }

                Section {
                    optionRow("Codec", value: store.settings.codec.title, setting: .codec)
                    Toggle("HDR (HEVC Main 10)", isOn: settings.hdr)
                        .disabled(!MoonlightDeviceCapabilities.supportsHDR || store.settings.codec == .h264)
                    Toggle("Frame pacing", isOn: settings.framePacing)
                } header: {
                    Text("Codec & presentation")
                } footer: {
                    Text(codecFootnote)
                }

                Section {
                    optionRow("Layout", value: store.settings.audio.title, setting: .audio)
                    Toggle("Keep playing audio on the PC", isOn: settings.playAudioOnHost)
                } header: {
                    Text("Audio")
                }

                Section {
                    Toggle("Optimize game settings", isOn: settings.optimizeGameSettings)
                    Toggle("Quit app when the stream ends", isOn: settings.quitAppOnDisconnect)
                } header: {
                    Text("Host")
                } footer: {
                    Text("Optimize asks Sunshine to switch the PC to the stream resolution while streaming. Quitting on disconnect closes the app on the PC instead of leaving it running for a later resume.")
                }

                Section {
                    Toggle("Show statistics overlay", isOn: settings.showStatistics)
                } header: {
                    Text("Overlay")
                } footer: {
                    Text("Game controllers paired with Apple TV are forwarded; the Siri Remote acts as a trackpad. Press Menu during a stream to show the controls.")
                }

                Section {
                    optionRow("Packet size", value: store.settings.packetSize.title, setting: .packetSize)
                } header: {
                    Text("Network")
                } footer: {
                    Text("Choose Remote network when you stream from outside your home network; smaller packets avoid fragmentation.")
                }

                Section {
                    Button("Reset to Moonlight defaults", role: .destructive) { store.resetToDefaults() }
                    Button("Done") { onDone() }
                }
            }
            .navigationTitle("Stream Settings")
            .navigationDestination(for: Setting.self) { setting in optionList(for: setting) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onDone() } }
            }
        }
        .tint(accent)
        .onAppear {
            #if DEBUG
            // `xcrun simctl launch <udid> com.dimitrie.orbit -orbitStreamSettings resolution` opens a list straight away (screenshots).
            if path.isEmpty, let raw = UserDefaults.standard.string(forKey: "orbitStreamSettings"), let setting = Setting(rawValue: raw) { path = [setting] }
            #endif
        }
    }

    private func optionRow(_ title: String, value: String, setting: Setting) -> some View {
        NavigationLink(value: setting) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func optionList(for setting: Setting) -> some View {
        switch setting {
        case .resolution:
            TVStreamOptionList(title: "Resolution", options: MoonlightStreamSettings.Resolution.allCases.map { TVStreamOption(value: $0, title: $0.title, detail: resolutionText($0)) },
                               selection: settings.resolution, accent: accent)
        case .frameRate:
            TVStreamOptionList(title: "Frame rate", options: MoonlightDeviceCapabilities.frameRateOptions.map { TVStreamOption(value: $0, title: fps($0), detail: nil) },
                               selection: settings.frameRate, accent: accent)
        case .bitrate:
            TVStreamOptionList(title: "Bitrate", options: bitrateOptions, selection: bitrateSelection, accent: accent)
        case .codec:
            TVStreamOptionList(title: "Codec", options: MoonlightStreamSettings.Codec.allCases.map { TVStreamOption(value: $0, title: $0.title, detail: nil) },
                               selection: settings.codec, accent: accent)
        case .audio:
            TVStreamOptionList(title: "Audio layout", options: MoonlightStreamSettings.AudioLayout.allCases.map { TVStreamOption(value: $0, title: $0.title, detail: nil) },
                               selection: settings.audio, accent: accent)
        case .packetSize:
            TVStreamOptionList(title: "Packet size", options: MoonlightStreamSettings.PacketSize.allCases.map { TVStreamOption(value: $0, title: $0.title, detail: nil) },
                               selection: settings.packetSize, accent: accent)
        }
    }

    private var codecFootnote: String {
        var notes: [String] = []
        notes.append(MoonlightDeviceCapabilities.supportsHEVC ? "This Apple TV decodes HEVC in hardware; Automatic prefers it and falls back to H.264." : "This Apple TV has no HEVC hardware decoder, so H.264 is used.")
        if let hostSupportsHEVC, !hostSupportsHEVC { notes.append("The PC's encoder reports no HEVC support.") }
        notes.append(MoonlightDeviceCapabilities.supportsHDR ? "HDR needs an HDR-capable PC display and Sunshine's HDR option." : "This TV cannot show HDR.")
        notes.append("Frame pacing holds one frame to smooth jitter at the cost of a little latency. AV1 is not available in Orbit yet.")
        return notes.joined(separator: " ")
    }

    private func resolutionText(_ resolution: MoonlightStreamSettings.Resolution) -> String {
        var candidate = store.settings
        candidate.resolution = resolution
        return "\(resolution.title) · \(candidate.pixelSize(hostSupportsHEVC: hostSupportsHEVC))"
    }

    private func fps(_ value: Int) -> String { "\(value) fps" }

    private func bitrateText(_ kbps: Int) -> String {
        kbps % 1000 == 0 ? "\(kbps / 1000) Mbps" : String(format: "%.1f Mbps", Double(kbps) / 1000)
    }
}

struct TVStreamOption<Value: Hashable>: Identifiable {
    var value: Value
    var title: String
    var detail: String?
    var id: Value { value }
}

/// One choice per row, the current one ticked; selecting returns to the settings list.
struct TVStreamOptionList<Value: Hashable>: View {
    let title: String
    let options: [TVStreamOption<Value>]
    @Binding var selection: Value
    var accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(options) { option in
                Button {
                    selection = option.value
                    dismiss()
                } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title)
                            if let detail = option.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if option.value == selection {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}
#else
/// Every Moonlight stream setting: resolution, frame rate, bitrate, codec, HDR, audio, host and input.
struct MoonlightStreamSettingsView: View {
    @ObservedObject var store: MoonlightStreamSettingsStore
    var accent: Color
    var hostSupportsHEVC: Bool? = nil
    var onDone: () -> Void

    private var settings: Binding<MoonlightStreamSettings> { $store.settings }
    private var pixelSize: MoonlightStreamSize { store.settings.pixelSize(hostSupportsHEVC: hostSupportsHEVC) }
    private var recommendedBitrateKbps: Int { store.settings.recommendedBitrateKbps(for: pixelSize) }
    private var bitrateMbps: Binding<Double> {
        Binding(get: { Double(store.settings.customBitrateKbps) / 1000 }, set: { store.settings.customBitrateKbps = Int(($0 * 1000).rounded()) })
    }

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                if MoonlightDeviceCapabilities.offersAspectChoice { pictureSection }
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
                    Text("\(resolution.title) · \(pixelSizeText(resolution))").tag(resolution)
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
            Text("Moonlight recommends \(bitrateText(recommendedBitrateKbps)) for \(pixelSize.width)×\(pixelSize.height) at \(store.settings.frameRate) fps. Lower it on Wi-Fi or away from home if the picture breaks up.")
        }
    }

    private var pictureSection: some View {
        Section {
            Picker("Picture", selection: settings.aspect) {
                ForEach(MoonlightStreamSettings.AspectMode.allCases) { aspect in Text(aspect.title).tag(aspect) }
            }
            .pickerStyle(.segmented)
            if store.settings.aspect == .native {
                NavigationLink {
                    MoonlightFillScreenHelpView(size: pixelSize, optimizeGameSettings: store.settings.optimizeGameSettings, accent: accent)
                } label: {
                    Label("Set up the PC to fill the screen", systemImage: "questionmark.circle")
                }
            }
        } header: {
            Text("Picture")
        } footer: {
            Text(pictureFootnote)
        }
    }

    private var pictureFootnote: String {
        switch store.settings.aspect {
        case .widescreen:
            return "16:9 is the shape of a PC monitor: you see the whole PC picture, with black bars where this screen's shape differs."
        case .native:
            #if os(macOS)
            let screen = "the shape of this display in full screen (\(pixelSize), measured on the display a stream opens on)"
            #else
            let screen = "this screen's shape (\(pixelSize))"
            #endif
            var text = "Fill Screen asks the PC for \(screen). It only fills the screen edge to edge when the PC can output that shape, which usually needs a virtual display set up for Sunshine. Until then the PC adds the black bars itself."
            if !store.settings.optimizeGameSettings { text += " Turn on Optimize game settings below: without it Sunshine cannot switch the PC's display to this shape." }
            return text
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
            Text("Click the video to capture the mouse and keyboard; press Control-Option-Shift-Z to release, Control-Option-Shift-F to switch full screen on or off, Control-Option-Shift-Q to end the stream. Game controllers are forwarded automatically.")
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
            Text("Choose Remote network when you stream from outside your home network; smaller packets avoid fragmentation.")
        }
    }

    /// The frame `resolution` gives with the current Picture choice and codec limits.
    private func pixelSizeText(_ resolution: MoonlightStreamSettings.Resolution) -> String {
        var candidate = store.settings
        candidate.resolution = resolution
        return candidate.pixelSize(hostSupportsHEVC: hostSupportsHEVC).description
    }

    private func bitrateText(_ kbps: Int) -> String {
        kbps % 1000 == 0 ? "\(kbps / 1000) Mbps" : String(format: "%.1f Mbps", Double(kbps) / 1000)
    }
}

/// What Fill Screen needs on the PC, in plain steps. Sunshine only fills a non-16:9 screen when one of the
/// PC's displays can switch to that exact size; otherwise it adds the bars itself.
private struct MoonlightFillScreenHelpView: View {
    let size: MoonlightStreamSize
    let optimizeGameSettings: Bool
    let accent: Color

    private static let installCommand = "winget install --id=VirtualDrivers.Virtual-Display-Driver -e"
    private static let driverURL = URL(string: "https://github.com/VirtualDrivers/Virtual-Display-Driver")!

    var body: some View {
        Form {
            Section {
                Text("Orbit asks the PC for a \(size.width) × \(size.height) picture, the shape of this screen. Sunshine can only send a full picture in that shape when one of the PC's displays can switch to exactly that size. A normal monitor cannot, so Sunshine fits the 16:9 desktop into the frame and adds black bars itself. Nothing breaks: you simply still see bars.")
            } header: {
                Text("Why there are black bars")
            }

            Section {
                step(1, "Install a virtual display on the PC, for example the free Virtual Display Driver. In Terminal on the PC:")
                Text(Self.installCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                step(2, "Add \(size.width) × \(size.height) to the virtual display's resolutions, at the frame rate you stream at.")
                step(3, "In Sunshine's web UI, under Audio/Video, choose the virtual display as the display to stream and let Sunshine change its resolution to the one the client asks for.")
                step(4, optimizeGameSettings
                     ? "Keep Optimize game settings on in Stream Settings: it is what lets Sunshine switch the display to this size."
                     : "Turn on Optimize game settings in Stream Settings: without it Sunshine never switches the display to this size.")
                Link(destination: Self.driverURL) {
                    Label("Virtual Display Driver on GitHub", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("Set up the PC")
            } footer: {
                Text("On the PC, the Orbit companion's tray menu (Set up full-screen streaming) walks through the same steps. Change Sunshine's settings between streams: Sunshine restarts to apply them.")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Fill the Screen")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(accent)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(accent)
                .frame(width: 18, alignment: .leading)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#endif
