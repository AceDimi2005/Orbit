# MoonlightCore

Local Swift package that gives Orbit in-app game streaming from a Sunshine host.

| Part | What it is | License |
| --- | --- | --- |
| `Sources/CMoonlight/src`, `include/Limelight.h` | [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) at the revision in `VENDORED_REVISION.txt`: RTSP handshake, video/audio/control/input streams, FEC. `PlatformCrypto.c` is replaced by the Swift hooks below. | GPL-3.0 (`LICENSE.txt`) |
| `Sources/CMoonlight/enet` | Moonlight's fork of ENet (reliable UDP for the control stream) | MIT (`enet/LICENSE.txt`) |
| `Sources/CMoonlight/nanors` | nanors Reed-Solomon codec used for FEC | MIT (`nanors/LICENSE.txt`) |
| `Sources/MoonlightCore` | Orbit's Swift layer: `PlatformCrypto.swift` (AES-GCM/CBC hooks on CryptoKit/CommonCrypto), `VideoRenderer.swift` (VideoToolbox through `AVSampleBufferDisplayLayer`), `AudioRenderer.swift` (Opus → `AVAudioEngine`), `ControllerBridge.swift` (GameController + rumble), `StreamSession.swift` (connection lifecycle, statistics, input), `StreamSurface.swift` (touch/mouse/keyboard views), `StreamSettings.swift` | Same as the app |
| `Copus` dependency | libopus packaged by [alta/swift-opus](https://github.com/alta/swift-opus) | BSD-3-Clause |

## Local changes to the vendored code

- 2026-10-22, macOS only (`LC_CONNECTED_UDP_SOCKETS` in `src/PlatformSockets.h`): the video,
  audio and control (ENet) sockets are `connect()`ed to their port on the host instead of being
  bound to a local address. The Mac App Sandbox refuses `bind()` and datagrams on unconnected UDP
  sockets unless the app has `com.apple.security.network.server`, which App Review rejects for an
  app that runs no server. Touched files: `src/PlatformSockets.{c,h}`, `src/VideoStream.c`,
  `src/AudioStream.c`, `src/ControlStream.c`, `src/RtspConnection.c`, and in ENet
  `enet_host_connect_socket()` (`host.c`, `enet.h`), `protocol.c` (no destination address on a
  connected socket) and `unix.c` (`ECONNREFUSED` from an ICMP port unreachable is transient).
  iOS and tvOS keep upstream behaviour.

Because moonlight-common-c is GPL-3.0, any Orbit binary that links this package must be
distributed under GPL-3.0-compatible terms (source available, same license for the combined
work). The rest of the repository stays MIT; the obligation attaches to the shipped app.

## Build and test

```bash
cd Orbit-iOS/Packages/MoonlightCore
swift build
swift test            # crypto hooks vs. CommonCrypto/CryptoKit references, bitrate curve, key maps,
                      # stream sizes (16:9 / Fill Screen, H.264 4096 cap), Mac keep-awake assertion
xcodebuild -scheme MoonlightCore -destination 'generic/platform=tvOS Simulator' build
```

The library is a process-wide singleton: one `MoonlightStreamSession` streams at a time and its
C callbacks reach the active session through `MoonlightSessionCore.current`.
