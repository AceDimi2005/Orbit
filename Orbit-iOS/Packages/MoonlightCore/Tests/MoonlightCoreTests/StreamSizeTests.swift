import CoreGraphics
import Foundation
import XCTest
@testable import MoonlightCore
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// The Picture setting (16:9 or this screen's shape), the size rules behind it and the codec caps.
final class StreamSizeTests: XCTestCase {
    private typealias Settings = MoonlightStreamSettings
    private let iPhone = CGSize(width: 2556, height: 1179)       // iPhone 15 Pro, 19.5:9
    private let iPad = CGSize(width: 2732, height: 2048)         // iPad Pro 12.9", 4:3
    private let macBook = CGSize(width: 3024, height: 1890)      // MacBook Pro 14" full-screen area below the notch, 16:10
    private let studioDisplay = CGSize(width: 5120, height: 2880)

    private func size(_ resolution: Settings.Resolution, _ aspect: Settings.AspectMode, _ native: CGSize, h264: Bool = false) -> MoonlightStreamSize {
        Settings.streamSize(resolution: resolution, aspect: aspect, native: native, limitToH264: h264)
    }

    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    // MARK: Saved settings

    func testAspectDefaultsToWidescreen() throws {
        XCTAssertEqual(Settings().aspect, .widescreen)
        XCTAssertEqual(try decode("{}").aspect, .widescreen)
        XCTAssertEqual(try decode(#"{"resolution":"hd1080","frameRate":120}"#).aspect, .widescreen)
    }

    func testSettingsSavedWithNativeBeforeThePictureOptionKeepFillingTheScreen() throws {
        // Before this option, Native meant every pixel of the screen: an update must not change that stream.
        let old = try decode(#"{"resolution":"native","frameRate":60,"codec":"hevc"}"#)
        XCTAssertEqual(old.aspect, .native)
        XCTAssertEqual(old.codec, .hevc)
        XCTAssertEqual(try decode(#"{"resolution":"native","aspect":"widescreen"}"#).aspect, .widescreen)
    }

    func testUnknownAspectFallsBackWithoutLosingTheOtherSettings() throws {
        let settings = try decode(#"{"resolution":"qhd1440","aspect":"ultrawide","frameRate":90,"hdr":true}"#)
        XCTAssertEqual(settings.aspect, .widescreen)
        XCTAssertEqual(settings.resolution, .qhd1440)
        XCTAssertEqual(settings.frameRate, 90)
        XCTAssertTrue(settings.hdr)
    }

    func testAspectSurvivesARoundTrip() throws {
        var settings = Settings()
        settings.resolution = .hd720
        settings.aspect = .native
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertTrue(json.contains(#""aspect":"native""#), json)
    }

    // MARK: 16:9

    func testWidescreenPresetsAreSixteenByNineOnEveryScreen() {
        for screen in [iPhone, iPad, macBook, studioDisplay, .zero] {
            XCTAssertEqual(size(.hd720, .widescreen, screen), MoonlightStreamSize(width: 1280, height: 720))
            XCTAssertEqual(size(.hd1080, .widescreen, screen), MoonlightStreamSize(width: 1920, height: 1080))
            XCTAssertEqual(size(.qhd1440, .widescreen, screen), MoonlightStreamSize(width: 2560, height: 1440))
            XCTAssertEqual(size(.uhd2160, .widescreen, screen), MoonlightStreamSize(width: 3840, height: 2160))
        }
    }

    func testWidescreenNativeIsTheLargestSixteenByNineFrameThatFits() {
        // Wider than 16:9: the height decides.
        XCTAssertEqual(size(.native, .widescreen, iPhone), MoonlightStreamSize(width: 2094, height: 1178))
        // Narrower than 16:9: the width decides.
        XCTAssertEqual(size(.native, .widescreen, iPad), MoonlightStreamSize(width: 2732, height: 1536))
        XCTAssertEqual(size(.native, .widescreen, macBook), MoonlightStreamSize(width: 3024, height: 1700))
        // Already 16:9.
        XCTAssertEqual(size(.native, .widescreen, studioDisplay), MoonlightStreamSize(width: 5120, height: 2880))
        for screen in [iPhone, iPad, macBook, studioDisplay] {
            XCTAssertTrue(size(.native, .widescreen, screen).isWidescreen, "\(screen)")
        }
    }

    // MARK: Fill Screen

    func testFillScreenPresetsKeepTheirHeightAndTakeTheScreensShape() {
        XCTAssertEqual(size(.hd720, .native, iPhone), MoonlightStreamSize(width: 1560, height: 720))
        XCTAssertEqual(size(.hd1080, .native, iPhone), MoonlightStreamSize(width: 2342, height: 1080))
        XCTAssertEqual(size(.hd1080, .native, iPad), MoonlightStreamSize(width: 1440, height: 1080))
        XCTAssertEqual(size(.hd1080, .native, macBook), MoonlightStreamSize(width: 1728, height: 1080))
        XCTAssertEqual(size(.qhd1440, .native, macBook), MoonlightStreamSize(width: 2304, height: 1440))
        // A 16:9 screen gives the usual sizes.
        XCTAssertEqual(size(.hd1080, .native, studioDisplay), MoonlightStreamSize(width: 1920, height: 1080))
    }

    func testFillScreenNativeIsEveryPixelOfTheScreenInLandscape() {
        XCTAssertEqual(size(.native, .native, iPhone), MoonlightStreamSize(width: 2556, height: 1178))   // odd height rounded down
        XCTAssertEqual(size(.native, .native, CGSize(width: 1179, height: 2556)), MoonlightStreamSize(width: 2556, height: 1178))
        XCTAssertEqual(size(.native, .native, iPad), MoonlightStreamSize(width: 2732, height: 2048))
        XCTAssertEqual(size(.native, .native, macBook), MoonlightStreamSize(width: 3024, height: 1890))
    }

    func testEverySizeIsEvenAndLandscape() {
        let screens = [iPhone, iPad, macBook, studioDisplay, CGSize(width: 1366, height: 1025), CGSize(width: 3441, height: 1441), CGSize(width: 1001, height: 1999)]
        for screen in screens {
            for resolution in Settings.Resolution.allCases {
                for aspect in Settings.AspectMode.allCases {
                    for h264 in [false, true] {
                        let result = size(resolution, aspect, screen, h264: h264)
                        XCTAssertEqual(result.width % 2, 0, "\(resolution) \(aspect) \(screen)")
                        XCTAssertEqual(result.height % 2, 0, "\(resolution) \(aspect) \(screen)")
                        XCTAssertGreaterThanOrEqual(result.width, result.height, "\(resolution) \(aspect) \(screen)")
                        XCTAssertLessThanOrEqual(result.width, h264 ? 4096 : 8192)
                    }
                }
            }
        }
    }

    func testScreensWithoutASizeFallBackTo1080p() {
        for aspect in Settings.AspectMode.allCases {
            XCTAssertEqual(size(.native, aspect, .zero), .fallback)
            XCTAssertEqual(size(.hd1080, aspect, .zero), MoonlightStreamSize(width: 1920, height: 1080))
            XCTAssertEqual(size(.native, aspect, CGSize(width: CGFloat.nan, height: 900)), .fallback)
        }
    }

    // MARK: Codec limits

    func testH264CapsTheWidthAt4096AndKeepsTheShape() {
        // 4K with Fill Screen on an iPhone.
        XCTAssertEqual(size(.uhd2160, .native, iPhone), MoonlightStreamSize(width: 4682, height: 2160))
        XCTAssertEqual(size(.uhd2160, .native, iPhone, h264: true), MoonlightStreamSize(width: 4096, height: 1888))
        // Native on a 5K and a 6K display.
        XCTAssertEqual(size(.native, .widescreen, studioDisplay, h264: true), MoonlightStreamSize(width: 4096, height: 2304))
        XCTAssertEqual(size(.native, .native, CGSize(width: 6016, height: 3384), h264: true), MoonlightStreamSize(width: 4096, height: 2304))
        XCTAssertEqual(size(.native, .native, CGSize(width: 6016, height: 3384)), MoonlightStreamSize(width: 6016, height: 3384))
        // Sizes within the limit are untouched.
        XCTAssertEqual(size(.uhd2160, .widescreen, studioDisplay, h264: true), MoonlightStreamSize(width: 3840, height: 2160))
        XCTAssertEqual(size(.native, .native, macBook, h264: true), MoonlightStreamSize(width: 3024, height: 1890))
    }

    func testNothingGoesBeyond8K() {
        XCTAssertEqual(size(.native, .native, CGSize(width: 10_240, height: 4320)), MoonlightStreamSize(width: 8192, height: 3456))
        XCTAssertEqual(MoonlightStreamSize(width: 3000, height: 2000).limited(to: 8192), MoonlightStreamSize(width: 3000, height: 2000))
    }

    func testH264LimitAppliesWheneverTheStreamCouldEndUpH264() {
        var settings = Settings()
        settings.codec = .auto
        XCTAssertFalse(settings.mayUseH264(hostSupportsHEVC: true, deviceSupportsHEVC: true))
        XCTAssertTrue(settings.mayUseH264(hostSupportsHEVC: false, deviceSupportsHEVC: true))
        XCTAssertTrue(settings.mayUseH264(hostSupportsHEVC: nil, deviceSupportsHEVC: true), "an unknown host may only have H.264")
        XCTAssertTrue(settings.mayUseH264(hostSupportsHEVC: true, deviceSupportsHEVC: false))
        settings.codec = .hevc
        XCTAssertFalse(settings.mayUseH264(hostSupportsHEVC: true, deviceSupportsHEVC: true))
        settings.codec = .h264
        XCTAssertTrue(settings.mayUseH264(hostSupportsHEVC: true, deviceSupportsHEVC: true))
    }

    func testInstanceSizeUsesTheSettingsAndTheHostsCodecs() {
        var settings = Settings()
        settings.resolution = .uhd2160
        settings.aspect = .native
        settings.codec = .h264
        XCTAssertEqual(settings.streamSize(native: iPhone, hostSupportsHEVC: true), MoonlightStreamSize(width: 4096, height: 1888))
        settings.codec = .hevc
        let expected = MoonlightDeviceCapabilities.supportsHEVC ? MoonlightStreamSize(width: 4682, height: 2160) : MoonlightStreamSize(width: 4096, height: 1888)
        XCTAssertEqual(settings.streamSize(native: iPhone, hostSupportsHEVC: true), expected)
        XCTAssertEqual(settings.streamSize(native: iPhone, hostSupportsHEVC: nil), MoonlightStreamSize(width: 4096, height: 1888))
        settings.aspect = .widescreen
        XCTAssertEqual(settings.streamSize(native: iPhone, hostSupportsHEVC: nil), MoonlightStreamSize(width: 3840, height: 2160))
    }

    // MARK: Labels and bitrate

    func testShortTitlesReadCorrectlyForNativeSizes() {
        XCTAssertEqual(MoonlightStreamSize(width: 1920, height: 1080).shortTitle, "1080p")
        XCTAssertEqual(MoonlightStreamSize(width: 1280, height: 720).shortTitle, "720p")
        XCTAssertEqual(MoonlightStreamSize(width: 3840, height: 2160).shortTitle, "2160p")
        XCTAssertEqual(MoonlightStreamSize(width: 2342, height: 1080).shortTitle, "2342 × 1080")
        XCTAssertEqual(MoonlightStreamSize(width: 1440, height: 1080).shortTitle, "1440 × 1080")
        XCTAssertEqual(MoonlightStreamSize(width: 2094, height: 1178).shortTitle, "2094 × 1178")
        XCTAssertEqual(MoonlightStreamSize(width: 4096, height: 2304).shortTitle, "4096 × 2304")
        XCTAssertTrue(MoonlightStreamSize(width: 4096, height: 2302).isWidescreen)
        XCTAssertFalse(MoonlightStreamSize(width: 3024, height: 1890).isWidescreen)
    }

    func testBitrateFollowsTheStreamsOwnSize() {
        var settings = Settings()
        settings.frameRate = 60
        XCTAssertEqual(settings.bitrateKbps(for: MoonlightStreamSize(width: 1920, height: 1080)), 20_000)
        XCTAssertEqual(settings.bitrateKbps(for: MoonlightStreamSize(width: 3840, height: 2160)), 80_000)
        XCTAssertEqual(settings.recommendedBitrateKbps(for: MoonlightStreamSize(width: 2342, height: 1080)),
                       Settings.recommendedBitrateKbps(width: 2342, height: 1080, fps: 60))
        settings.usesRecommendedBitrate = false
        settings.customBitrateKbps = 12_000
        XCTAssertEqual(settings.bitrateKbps(for: MoonlightStreamSize(width: 3840, height: 2160)), 12_000)
        settings.customBitrateKbps = 900_000
        XCTAssertEqual(settings.bitrateKbps(for: MoonlightStreamSize(width: 1280, height: 720)), 150_000)
    }

    func testConnectionParametersCarryTheLaunchSize() {
        let launched = MoonlightStreamSize(width: 2342, height: 1080)
        let parameters = MoonlightConnectionParameters(address: "192.0.2.10", appVersion: "7.1.431.-1", serverCodecModeSupport: 0x301,
                                                       remoteInputKey: Data(count: 16), remoteInputKeyID: 7, appName: "Desktop", hostName: "PC",
                                                       streamSize: launched)
        XCTAssertEqual(parameters.streamSize, launched)
    }

    func testAppleTVHasNoPictureChoice() {
        var settings = Settings()
        settings.aspect = .native
        #if os(tvOS)
        XCTAssertFalse(MoonlightDeviceCapabilities.offersAspectChoice)
        XCTAssertEqual(settings.effectiveAspect, .widescreen)
        #else
        XCTAssertTrue(MoonlightDeviceCapabilities.offersAspectChoice)
        XCTAssertEqual(settings.effectiveAspect, .native)
        #endif
    }

    // MARK: Mac screens

    #if os(macOS)
    func testMacPixelsPerPointIsThePanelsRealDensity() {
        let panel14 = (width: 3024, height: 1964)
        // Default mode: backing store and panel agree.
        XCTAssertEqual(MoonlightDeviceCapabilities.pixelsPerPoint(points: CGSize(width: 1512, height: 982), panel: panel14, backingScale: 2), 2, accuracy: 0.0001)
        // "More Space": a 3600-pixel backing store is shrunk onto the 3024-pixel panel.
        XCTAssertEqual(MoonlightDeviceCapabilities.pixelsPerPoint(points: CGSize(width: 1800, height: 1169), panel: panel14, backingScale: 2), 1.68, accuracy: 0.001)
        // MacBook Air M1 default: 1440 × 900 points on a 2560 × 1600 panel.
        XCTAssertEqual(MoonlightDeviceCapabilities.pixelsPerPoint(points: CGSize(width: 1440, height: 900), panel: (2560, 1600), backingScale: 2), 2560.0 / 1440, accuracy: 0.0001)
        // A low-resolution mode on a 4K panel: the 1× backing store is the limit.
        XCTAssertEqual(MoonlightDeviceCapabilities.pixelsPerPoint(points: CGSize(width: 1920, height: 1080), panel: (3840, 2160), backingScale: 1), 1, accuracy: 0.0001)
        // A display rotated to portrait.
        XCTAssertEqual(MoonlightDeviceCapabilities.pixelsPerPoint(points: CGSize(width: 1080, height: 1920), panel: (3840, 2160), backingScale: 2), 2, accuracy: 0.0001)
        // Nonsense falls back to the backing scale.
        XCTAssertEqual(MoonlightDeviceCapabilities.pixelsPerPoint(points: .zero, panel: (3840, 2160), backingScale: 2), 2)
        XCTAssertEqual(MoonlightDeviceCapabilities.pixelsPerPoint(points: CGSize(width: 1920, height: 1080), panel: (0, 0), backingScale: 2), 2)
    }

    @MainActor
    func testMacNativeSizeOfARealScreenIsUsable() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No display attached") }
        let native = MoonlightDeviceCapabilities.nativePixelSize(of: screen)
        for each in NSScreen.screens {
            print("Display \(MoonlightDeviceCapabilities.displayID(of: each).map(String.init) ?? "?"): \(each.frame.size) pt × \(each.backingScaleFactor), notch \(each.safeAreaInsets.top) pt → full screen \(MoonlightDeviceCapabilities.nativePixelSize(of: each)) px")
        }
        XCTAssertGreaterThan(native.width, 0)
        XCTAssertGreaterThan(native.height, 0)
        // Never more than the backing store, never more than the whole screen.
        XCTAssertLessThanOrEqual(native.width, (screen.frame.width * screen.backingScaleFactor).rounded())
        XCTAssertLessThanOrEqual(native.height, (screen.frame.height * screen.backingScaleFactor).rounded())
        XCTAssertNotNil(MoonlightDeviceCapabilities.displayID(of: screen))
    }

    private func ownAssertionNames() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess, let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        return (byProcess[pid] ?? []).compactMap { $0[kIOPMAssertionNameKey] as? String }
    }

    @MainActor
    func testMacKeepAwakeHoldsAPowerAssertionUntilReleased() throws {
        let reason = "Orbit stream test \(UUID().uuidString)"
        let hold = MoonlightKeepAwake(reason: reason)
        guard hold.holdsPowerAssertion else { throw XCTSkip("Power assertions are not available here") }
        XCTAssertTrue(ownAssertionNames().contains(reason))
        hold.release()
        XCTAssertFalse(hold.holdsPowerAssertion)
        XCTAssertFalse(ownAssertionNames().contains(reason))
        hold.release()   // a second release is harmless
    }

    @MainActor
    func testMacKeepAwakeIsReleasedWhenTheHoldGoesAway() throws {
        let reason = "Orbit stream test \(UUID().uuidString)"
        var hold: MoonlightKeepAwake? = MoonlightKeepAwake(reason: reason)
        guard hold?.holdsPowerAssertion == true else { throw XCTSkip("Power assertions are not available here") }
        XCTAssertTrue(ownAssertionNames().contains(reason))
        hold = nil
        XCTAssertNil(hold)
        XCTAssertFalse(ownAssertionNames().contains(reason))
    }
    #endif
}
