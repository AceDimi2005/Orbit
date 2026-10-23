# Third-party notices

Orbit's Apple apps (iOS, iPadOS, watchOS, tvOS, macOS) include or depend on the following open-source software. The binaries distributed through the App Store are licensed under the GNU GPLv3 with the App Store Distribution Exception (see `LICENSE`); the complete source code is published at https://github.com/AceDimi2005/Orbit.

| Component | Author | License | Role |
|---|---|---|---|
| [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | Cameron Gutman and the Moonlight Game Streaming Project | GPLv3 with App Store Distribution Exception | Streaming engine for Sunshine / GameStream (video, audio, input), vendored in `Orbit-iOS/Packages/MoonlightCore/Sources/CMoonlight` |
| [ENet](http://enet.bespin.org) (Moonlight fork) | Lee Salzman | MIT | Reliable UDP control channel used by the streaming engine |
| [nanors](https://github.com/sleepybishop/nanors) | Joseph Calderon | MIT | Reed–Solomon forward error correction for the video stream |
| [swift-opus / Copus](https://github.com/alta/swift-opus) | Alta Software | BSD-3-Clause | Swift package wrapping the Opus codec |
| [Opus](https://opus-codec.org) | Xiph.Org Foundation | BSD-3-Clause | Audio decoding for the stream |

Not included in the apps, but used by them:

- [Sunshine](https://github.com/LizardByte/Sunshine) by LizardByte (GPLv3) runs on the Windows PC and provides the game stream. Download: https://app.lizardbyte.dev/Sunshine/
- [Moonlight](https://moonlight-stream.org) by the Moonlight Game Streaming Project (GPLv3) is the reference client; Orbit can hand a stream over to it on macOS.
- Orbit Windows Agent (this repository, `Orbit-Windows-Agent/`, Python) is the telemetry and control companion.
- The agent's iPhone webcam uses [Softcam](https://github.com/tshino/softcam) by tshino (MIT), which links Microsoft's DirectShow BaseClasses (MIT). Both run only on the PC; their notices are in `Orbit-Windows-Agent/THIRD_PARTY_NOTICES.md`.

Orbit, Sunshine and Moonlight are independent projects; Orbit is not affiliated with or endorsed by the Moonlight project, LizardByte, NVIDIA or Apple.

## App Store Distribution Exception (moonlight-common-c)

App Store Distribution Exception

As additional permission under section 7, you are allowed to distribute the
software through an app store, even if that store has restrictive terms and
conditions that are incompatible with the GPL, provided that the source is
also available under the GPL with or without this permission through a channel
without those restrictive terms and conditions.
