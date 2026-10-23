import AVFoundation
import Combine
import Foundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Everything the user can tune for a stream. Mirrors Moonlight's settings; persisted as JSON.
public struct MoonlightStreamSettings: Codable, Equatable, Sendable {
    public enum Resolution: String, Codable, CaseIterable, Identifiable, Sendable {
        case hd720, hd1080, qhd1440, uhd2160, native
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .hd720: return "720p"
            case .hd1080: return "1080p"
            case .qhd1440: return "1440p"
            case .uhd2160: return "4K"
            case .native: return "Native"
            }
        }
        public var detail: String {
            switch self {
            case .hd720: return "1280 × 720"
            case .hd1080: return "1920 × 1080"
            case .qhd1440: return "2560 × 1440"
            case .uhd2160: return "3840 × 2160"
            // With Picture 16:9 Native is the largest 16:9 frame that fits the screen, with Fill Screen every pixel
            // of it (see `pixelSize(aspect:native:)`), so the text promises neither.
            case .native: return "Sized to this screen"
            }
        }
        /// Height of the preset in pixels; nil for Native, where the screen decides.
        public var presetHeight: Int? {
            switch self {
            case .hd720: return 720
            case .hd1080: return 1080
            case .qhd1440: return 1440
            case .uhd2160: return 2160
            case .native: return nil
            }
        }

        /// The frame for a screen of `native` pixels, before any codec limit.
        /// - `.widescreen`: presets are their 16:9 size; Native is the largest 16:9 frame that fits the screen.
        /// - `.native`: presets keep their height and take the screen's shape; Native is every pixel of the screen.
        public func pixelSize(aspect: AspectMode, native: CGSize) -> MoonlightStreamSize {
            let screen = MoonlightStreamSize.landscape(native)
            switch (presetHeight, aspect) {
            case (nil, .native):
                return screen
            case (nil, .widescreen):
                return screen.largestWidescreenFit
            case (let height?, .widescreen):
                return MoonlightStreamSize(width: height * 16 / 9, height: height)
            case (let height?, .native):
                let ratio = MoonlightStreamSize.aspectRatio(of: native) ?? Double(screen.width) / Double(screen.height)
                return MoonlightStreamSize(width: MoonlightStreamSize.nearestEven(Double(height) * ratio), height: height)
            }
        }
    }

    /// The shape of the picture the PC is asked for.
    public enum AspectMode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// 16:9, the shape of a PC monitor: the whole PC picture shows, with black bars where the screen differs.
        case widescreen
        /// This screen's own shape. It fills the screen edge to edge only when the PC can output that shape.
        case native
        public var id: String { rawValue }
        public var title: String { self == .widescreen ? "16:9" : "Fill Screen" }
    }

    public enum Codec: String, Codable, CaseIterable, Identifiable, Sendable {
        case auto, h264, hevc
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .auto: return "Automatic"
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            }
        }
    }

    public enum AudioLayout: String, Codable, CaseIterable, Identifiable, Sendable {
        case stereo, surround51, surround71
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .stereo: return "Stereo"
            case .surround51: return "5.1 Surround"
            case .surround71: return "7.1 Surround"
            }
        }
        /// The AUDIO_CONFIGURATION_* value from Limelight.h.
        public var configuration: Int32 {
            switch self {
            case .stereo: return (0x3 << 16) | (2 << 8) | 0xCA
            case .surround51: return (0x3F << 16) | (6 << 8) | 0xCA
            case .surround71: return (0x63F << 16) | (8 << 8) | 0xCA
            }
        }
        public var channelCount: Int {
            switch self {
            case .stereo: return 2
            case .surround51: return 6
            case .surround71: return 8
            }
        }
    }

    public enum TouchMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case trackpad, touchscreen
        public var id: String { rawValue }
        public var title: String { self == .trackpad ? "Trackpad" : "Touchscreen" }
    }

    public enum PacketSize: String, Codable, CaseIterable, Identifiable, Sendable {
        case auto, remote
        public var id: String { rawValue }
        public var title: String { self == .auto ? "Automatic (1392)" : "Remote network (1024)" }
        public var bytes: Int32 { self == .auto ? 1392 : 1024 }
    }

    public var resolution: Resolution = .hd1080
    /// 16:9 or this screen's shape. Apple TV always streams 16:9 (see `effectiveAspect`).
    public var aspect: AspectMode = .widescreen
    public var frameRate: Int = 60
    /// Only used when `usesRecommendedBitrate` is off.
    public var customBitrateKbps: Int = 20_000
    public var usesRecommendedBitrate = true
    public var codec: Codec = .auto
    public var hdr = false
    public var audio: AudioLayout = .stereo
    public var playAudioOnHost = false
    /// Sunshine "optimize game settings" (SOPS): asks the host to apply the stream resolution.
    public var optimizeGameSettings = true
    /// Smooth presentation at the cost of up to one frame of latency.
    public var framePacing = false
    public var quitAppOnDisconnect = false
    public var showStatistics = false
    public var touchMode: TouchMode = .trackpad
    public var packetSize: PacketSize = .auto
    public var trackpadSensitivity: Double = 1.0

    public static let frameRateOptions = [30, 60, 90, 120]
    public static let bitrateRangeKbps = 500...150_000
    /// H.264 encoders (NVENC, AMF, Quick Sync) stop at 4096 pixels per side; moonlight-common-c warns above it.
    public static let h264MaxDimension = 4096
    /// Nothing streams beyond 8K, whatever the codec.
    public static let maxDimension = 8192

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case resolution, aspect, frameRate, customBitrateKbps, usesRecommendedBitrate, codec, hdr, audio, playAudioOnHost,
             optimizeGameSettings, framePacing, quitAppOnDisconnect, showStatistics, touchMode, packetSize, trackpadSensitivity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MoonlightStreamSettings()
        resolution = try values.decodeIfPresent(Resolution.self, forKey: .resolution) ?? defaults.resolution
        if let saved = try? values.decodeIfPresent(AspectMode.self, forKey: .aspect) {
            aspect = saved
        } else {
            // Saved before the Picture option existed (or by a newer build with a shape this one does not know).
            // Native used to mean every pixel of the screen, so it keeps doing that.
            aspect = resolution == .native ? .native : defaults.aspect
        }
        frameRate = try values.decodeIfPresent(Int.self, forKey: .frameRate) ?? defaults.frameRate
        customBitrateKbps = try values.decodeIfPresent(Int.self, forKey: .customBitrateKbps) ?? defaults.customBitrateKbps
        usesRecommendedBitrate = try values.decodeIfPresent(Bool.self, forKey: .usesRecommendedBitrate) ?? defaults.usesRecommendedBitrate
        codec = try values.decodeIfPresent(Codec.self, forKey: .codec) ?? defaults.codec
        hdr = try values.decodeIfPresent(Bool.self, forKey: .hdr) ?? defaults.hdr
        audio = try values.decodeIfPresent(AudioLayout.self, forKey: .audio) ?? defaults.audio
        playAudioOnHost = try values.decodeIfPresent(Bool.self, forKey: .playAudioOnHost) ?? defaults.playAudioOnHost
        optimizeGameSettings = try values.decodeIfPresent(Bool.self, forKey: .optimizeGameSettings) ?? defaults.optimizeGameSettings
        framePacing = try values.decodeIfPresent(Bool.self, forKey: .framePacing) ?? defaults.framePacing
        quitAppOnDisconnect = try values.decodeIfPresent(Bool.self, forKey: .quitAppOnDisconnect) ?? defaults.quitAppOnDisconnect
        showStatistics = try values.decodeIfPresent(Bool.self, forKey: .showStatistics) ?? defaults.showStatistics
        touchMode = try values.decodeIfPresent(TouchMode.self, forKey: .touchMode) ?? defaults.touchMode
        packetSize = try values.decodeIfPresent(PacketSize.self, forKey: .packetSize) ?? defaults.packetSize
        trackpadSensitivity = try values.decodeIfPresent(Double.self, forKey: .trackpadSensitivity) ?? defaults.trackpadSensitivity
    }

    /// The shape actually streamed: Apple TV only offers 16:9.
    public var effectiveAspect: AspectMode { MoonlightDeviceCapabilities.offersAspectChoice ? aspect : .widescreen }

    /// The frame to request for `resolution` and `aspect` on a screen of `native` pixels, within the codec's limits.
    /// `limitToH264` caps both sides at 4096 (keeping the shape) because the stream may end up H.264.
    public static func streamSize(resolution: Resolution, aspect: AspectMode, native: CGSize, limitToH264: Bool) -> MoonlightStreamSize {
        resolution.pixelSize(aspect: aspect, native: native).limited(to: limitToH264 ? h264MaxDimension : maxDimension)
    }

    /// True when the stream could end up H.264: chosen explicitly, no HEVC decoder on this device, or a host
    /// whose encoder has no HEVC (`nil`, not known yet, counts as "could").
    public func mayUseH264(hostSupportsHEVC: Bool?, deviceSupportsHEVC: Bool = MoonlightDeviceCapabilities.supportsHEVC) -> Bool {
        codec == .h264 || !deviceSupportsHEVC || hostSupportsHEVC != true
    }

    /// `size` kept within what the host can encode: a host without HEVC streams H.264, which ends at 4096
    /// pixels per side. Applied again at launch with the host's fresh answer, since the size was chosen earlier.
    public static func size(_ size: MoonlightStreamSize, forHostSupportingHEVC hostSupportsHEVC: Bool) -> MoonlightStreamSize {
        hostSupportsHEVC ? size : size.limited(to: h264MaxDimension)
    }

    /// The frame to request on a screen of `native` pixels.
    public func streamSize(native: CGSize, hostSupportsHEVC: Bool?) -> MoonlightStreamSize {
        Self.streamSize(resolution: resolution, aspect: effectiveAspect, native: native, limitToH264: mayUseH264(hostSupportsHEVC: hostSupportsHEVC))
    }

    /// Stream dimensions on this device's main screen (the Mac: the full-screen area of the screen in front).
    /// A stream decides its size once when it starts; this is the estimate for settings and summaries.
    public func pixelSize(hostSupportsHEVC: Bool?) -> MoonlightStreamSize {
        streamSize(native: MoonlightDeviceCapabilities.nativePixelSize, hostSupportsHEVC: hostSupportsHEVC)
    }

    /// `pixelSize(hostSupportsHEVC:)` for a host whose codecs are not known.
    public var pixelSize: MoonlightStreamSize { pixelSize(hostSupportsHEVC: nil) }

    /// Moonlight's default bitrate curve (moonlight-qt `getDefaultBitrate`): linear in pixels
    /// between the well-known resolutions, scaled by frame rate with a square-root taper above 60.
    public static func recommendedBitrateKbps(width: Int, height: Int, fps: Int) -> Int {
        let frameRateFactor = (fps <= 60 ? Double(fps) : (Double(fps) / 60).squareRoot() * 60) / 30
        let table: [(pixels: Double, factor: Double)] = [
            (640 * 360, 1), (854 * 480, 2), (1280 * 720, 5), (1920 * 1080, 10), (2560 * 1440, 20), (3840 * 2160, 40)
        ]
        let pixels = Double(width * height)
        var resolutionFactor = table.last!.factor
        for (index, entry) in table.enumerated() {
            if pixels == entry.pixels { resolutionFactor = entry.factor; break }
            if pixels < entry.pixels {
                if index == 0 { resolutionFactor = entry.factor } else {
                    let previous = table[index - 1]
                    resolutionFactor = (pixels - previous.pixels) / (entry.pixels - previous.pixels) * (entry.factor - previous.factor) + previous.factor
                }
                break
            }
        }
        return Int((resolutionFactor * frameRateFactor).rounded()) * 1000
    }

    public func recommendedBitrateKbps(for size: MoonlightStreamSize) -> Int {
        Self.recommendedBitrateKbps(width: size.width, height: size.height, fps: frameRate)
    }

    /// The bitrate a stream of `size` uses: Moonlight's recommendation for it, or the manual value.
    public func bitrateKbps(for size: MoonlightStreamSize) -> Int {
        usesRecommendedBitrate ? recommendedBitrateKbps(for: size) : min(max(customBitrateKbps, Self.bitrateRangeKbps.lowerBound), Self.bitrateRangeKbps.upperBound)
    }

    public var recommendedBitrateKbps: Int { recommendedBitrateKbps(for: pixelSize) }

    public var bitrateKbps: Int { bitrateKbps(for: pixelSize) }

    /// VIDEO_FORMAT_* mask handed to the library. H.264 is always a fallback.
    public var supportedVideoFormats: Int32 {
        var formats: Int32 = 0x0001 // VIDEO_FORMAT_H264
        let hevc = MoonlightDeviceCapabilities.supportsHEVC
        switch codec {
        case .h264: break
        case .hevc, .auto:
            if hevc {
                formats |= 0x0100 // VIDEO_FORMAT_H265
                if hdr && MoonlightDeviceCapabilities.supportsHDR { formats |= 0x0200 } // VIDEO_FORMAT_H265_MAIN10
            }
        }
        return formats
    }

    public var requestsHDR: Bool { supportedVideoFormats & 0x0200 != 0 }
}

/// Width × height of a stream in pixels, landscape (width ≥ height) and even on both sides.
public struct MoonlightStreamSize: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// The frame used when a screen reports no usable size.
    public static let fallback = MoonlightStreamSize(width: 1920, height: 1080)

    /// `size` in landscape order, rounded down to even numbers (encoders need even sides).
    public static func landscape(_ size: CGSize) -> MoonlightStreamSize {
        let width = evenDown(Double(max(size.width, size.height)))
        let height = evenDown(Double(min(size.width, size.height)))
        return width >= 2 && height >= 2 ? MoonlightStreamSize(width: width, height: height) : fallback
    }

    /// Long side over short side of a screen, or nil when it reports no usable size.
    static func aspectRatio(of size: CGSize) -> Double? {
        let long = Double(max(size.width, size.height)), short = Double(min(size.width, size.height))
        guard long.isFinite, short.isFinite, short >= 1 else { return nil }
        return long / short
    }

    static func evenDown(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let whole = Int(min(value, 1_000_000).rounded(.down))
        return whole - whole % 2
    }

    static func nearestEven(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 2 }
        return max(2, Int((min(value, 1_000_000) / 2).rounded()) * 2)
    }

    /// The largest 16:9 frame that fits inside this one.
    public var largestWidescreenFit: MoonlightStreamSize {
        if width * 9 >= height * 16 {
            return MoonlightStreamSize(width: max(2, Self.evenDown(Double(height) * 16 / 9)), height: height)
        }
        return MoonlightStreamSize(width: width, height: max(2, Self.evenDown(Double(width) * 9 / 16)))
    }

    /// Scaled down, keeping the shape, so neither side exceeds `maximum`.
    public func limited(to maximum: Int) -> MoonlightStreamSize {
        let longest = max(width, height)
        guard longest > maximum, longest > 0 else { return self }
        // Multiply before dividing so exact ratios (6016 × 3384 → 4096 × 2304) stay exact.
        func scaled(_ side: Int) -> Int { min(maximum, max(2, Self.evenDown(Double(side) * Double(maximum) / Double(longest)))) }
        return MoonlightStreamSize(width: scaled(width), height: scaled(height))
    }

    /// 16:9 within the rounding to even pixels.
    public var isWidescreen: Bool {
        guard width > 0, height > 0 else { return false }
        return abs(Double(width) / Double(height) - 16.0 / 9.0) < 0.005
    }

    /// Short label for summaries: "1080p" for the usual 16:9 sizes, otherwise both sides ("2556 × 1178").
    public var shortTitle: String {
        isWidescreen && [720, 1080, 1440, 2160].contains(height) ? "\(height)p" : description
    }

    public var description: String { "\(width) × \(height)" }
}

/// What this device can decode and display.
public enum MoonlightDeviceCapabilities {
    public static var supportsHEVC: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) }
    public static var supportsAV1: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }

    public static var supportsHDR: Bool {
        guard supportsHEVC else { return false }
        #if os(macOS)
        return (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        #else
        return AVPlayer.availableHDRModes.contains(.hdr10)
        #endif
    }

    public static var maximumFrameRate: Int {
        #if os(macOS)
        return max(60, NSScreen.main?.maximumFramesPerSecond ?? 60)
        #else
        return max(60, UIScreen.main.maximumFramesPerSecond)
        #endif
    }

    /// Apple TV always streams 16:9 (its output mode has a TV's shape), so it does not offer the Picture choice.
    public static var offersAspectChoice: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    /// Physical pixels of the main screen in landscape. On the Mac: what a full-screen window covers on the
    /// screen in front (see `nativePixelSize(of:)`).
    public static var nativePixelSize: CGSize {
        #if os(macOS)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return CGSize(width: 1920, height: 1080) }
        return nativePixelSize(of: screen)
        #else
        let bounds = UIScreen.main.nativeBounds.size
        return CGSize(width: max(bounds.width, bounds.height), height: min(bounds.width, bounds.height))
        #endif
    }

    #if os(macOS)
    /// What a full-screen window covers on `screen`, in the panel's physical pixels: the whole display
    /// minus the camera housing strip (full-screen windows sit below the notch on MacBooks that have one).
    public static func nativePixelSize(of screen: NSScreen) -> CGSize {
        let frame = screen.frame.size
        let notch = max(0, screen.safeAreaInsets.top)
        let scale = pixelsPerPoint(of: screen)
        return CGSize(width: (frame.width * scale).rounded(), height: (max(0, frame.height - notch) * scale).rounded())
    }

    /// Pixels the eye actually gets per point. Scaled ("More Space") modes draw a backing store larger than
    /// the panel and shrink it, so the panel's native mode is the limit; low-resolution modes are limited by
    /// the backing store instead.
    public static func pixelsPerPoint(of screen: NSScreen) -> CGFloat {
        let backing = screen.backingScaleFactor
        let points = screen.frame.size
        guard let displayID = displayID(of: screen), points.width > 0, points.height > 0,
              let panel = panelPixelSize(displayID: displayID) else { return backing }
        return pixelsPerPoint(points: points, panel: panel, backingScale: backing)
    }

    /// `pixelsPerPoint(of:)` without the screen lookups, for tests.
    static func pixelsPerPoint(points: CGSize, panel: (width: Int, height: Int), backingScale: CGFloat) -> CGFloat {
        var panelWidth = CGFloat(panel.width), panelHeight = CGFloat(panel.height)
        guard points.width > 0, points.height > 0, panelWidth > 0, panelHeight > 0 else { return backingScale }
        if (panelWidth > panelHeight) != (points.width > points.height) { swap(&panelWidth, &panelHeight) }   // rotated display
        let physical = min(panelWidth / points.width, panelHeight / points.height)
        guard physical.isFinite, physical > 0 else { return backingScale }
        return min(physical, backingScale)
    }

    /// The Core Graphics display behind `screen`.
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The panel's own resolution: the display mode macOS flags as native (`kDisplayModeNativeFlag`).
    static func panelPixelSize(displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let nativeFlag: UInt32 = 0x0200_0000   // kDisplayModeNativeFlag, IOKit/graphics/IOGraphicsTypes.h
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return nil }
        let native = modes.filter { $0.ioFlags & nativeFlag != 0 && $0.pixelWidth > 0 && $0.pixelHeight > 0 }
            .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
        return native.map { ($0.pixelWidth, $0.pixelHeight) }
    }
    #endif

    public static var frameRateOptions: [Int] {
        MoonlightStreamSettings.frameRateOptions.filter { $0 <= maximumFrameRate || $0 == 60 }
    }

    public static var hasTouchScreen: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}

/// Persists settings in UserDefaults and publishes changes to the UI.
@MainActor
public final class MoonlightStreamSettingsStore: ObservableObject {
    public static let shared = MoonlightStreamSettingsStore()
    private static let key = "orbit.stream.settings"

    @Published public var settings: MoonlightStreamSettings {
        didSet { persist() }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(MoonlightStreamSettings.self, from: data) {
            settings = decoded
        } else {
            settings = MoonlightStreamSettings()
        }
    }

    private let defaults: UserDefaults

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }

    public func resetToDefaults() { settings = MoonlightStreamSettings() }
}
