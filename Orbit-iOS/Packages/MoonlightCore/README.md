# MoonlightCore

Local Swift package that gives Orbit in-app game streaming from a Sunshine host.

| Part | What it is | License |
| --- | --- | --- |
| `Sources/CMoonlight/src`, `include/Limelight.h` | [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) at the revision in `VENDORED_REVISION.txt`: RTSP handshake, video/audio/control/input streams, FEC. `PlatformCrypto.c` is replaced by the Swift hooks below. | GPL-3.0 (`LICENSE.txt`) |
| `Sources/CMoonlight/enet` | Moonlight's fork of ENet (reliable UDP for the control stream) | MIT (`enet/LICENSE.txt`) |
| `Sources/CMoonlight/nanors` | nanors Reed-Solomon codec used for FEC | MIT (`nanors/LICENSE.txt`) |
| `Sources/MoonlightCore` | Orbit's Swift layer: `PlatformCrypto.swift` (AES-GCM/CBC hooks on CryptoKit/CommonCrypto), `VideoRenderer.swift` (VideoToolbox through `AVSampleBufferDisplayLayer`), `AudioRenderer.swift` (Opus → `AVAudioEngine`), `ControllerBridge.swift` (GameController + rumble), `StreamSession.swift` (connection lifecycle, statistics, input), `StreamSurface.swift` (touch/mouse/keyboard views), `StreamSettings.swift` | Same as the app |
| `Copus` dependency | libopus packaged by [alta/swift-opus](https://github.com/alta/swift-opus) | BSD-3-Clause |

Because moonlight-common-c is GPL-3.0, any Orbit binary that links this package must be
distributed under GPL-3.0-compatible terms (source available, same license for the combined
work). The rest of the repository stays MIT; the obligation attaches to the shipped app.

## Build and test

```bash
cd Orbit-iOS/Packages/MoonlightCore
swift build
swift test            # crypto hooks vs. CommonCrypto/CryptoKit references, bitrate curve, key maps
xcodebuild -scheme MoonlightCore -destination 'generic/platform=tvOS Simulator' build
```

The library is a process-wide singleton: one `MoonlightStreamSession` streams at a time and its
C callbacks reach the active session through `MoonlightSessionCore.current`.
