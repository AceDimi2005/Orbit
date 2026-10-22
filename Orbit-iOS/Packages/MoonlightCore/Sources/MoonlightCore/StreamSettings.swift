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
            case .native: return "This screen's pixels"
            }
        }
        public func pixelSize(native: CGSize) -> (width: Int, height: Int) {
            switch self {
            case .hd720: return (1280, 720)
            case .hd1080: return (1920, 1080)
            case .qhd1440: return (2560, 1440)
            case .uhd2160: return (3840, 2160)
            case .native:
                var width = Int(max(native.width, native.height))
                var height = Int(min(native.width, native.height))
                if width <= 0 || height <= 0 { return (1920, 1080) }
                // Encoders want even dimensions; keep the aspect ratio of the panel.
                width -= width % 2
                height -= height % 2
                return (min(width, 8192), min(height, 8192))
            }
        }
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

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case resolution, frameRate, customBitrateKbps, usesRecommendedBitrate, codec, hdr, audio, playAudioOnHost,
             optimizeGameSettings, framePacing, quitAppOnDisconnect, showStatistics, touchMode, packetSize, trackpadSensitivity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MoonlightStreamSettings()
        resolution = try values.decodeIfPresent(Resolution.self, forKey: .resolution) ?? defaults.resolution
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

    /// Stream dimensions for this device.
    public var pixelSize: (width: Int, height: Int) { resolution.pixelSize(native: MoonlightDeviceCapabilities.nativePixelSize) }

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

    public var recommendedBitrateKbps: Int {
        let size = pixelSize
        return Self.recommendedBitrateKbps(width: size.width, height: size.height, fps: frameRate)
    }

    public var bitrateKbps: Int {
        usesRecommendedBitrate ? recommendedBitrateKbps : min(max(customBitrateKbps, Self.bitrateRangeKbps.lowerBound), Self.bitrateRangeKbps.upperBound)
    }

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

    /// Physical pixels of the main screen in landscape.
    public static var nativePixelSize: CGSize {
        #if os(macOS)
        guard let screen = NSScreen.main else { return CGSize(width: 1920, height: 1080) }
        let size = screen.frame.size
        return CGSize(width: size.width * screen.backingScaleFactor, height: size.height * screen.backingScaleFactor)
        #else
        let bounds = UIScreen.main.nativeBounds.size
        return CGSize(width: max(bounds.width, bounds.height), height: min(bounds.width, bounds.height))
        #endif
    }

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
