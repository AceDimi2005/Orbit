# Third-party notices

Orbit's Apple apps (iOS, iPadOS, watchOS, tvOS, macOS) include or depend on the following open-source software. The binaries distributed through the App Store are licensed under the GNU GPLv3 with the App Store Distribution Exception (see `LICENSE`); the complete source code is published at https://github.com/AceDimi2005/Orbit.

| Component | Author | License | Role |
|---|---|---|---|
| [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | Cameron Gutman and the Moonlight Game Streaming Project | GPLv3 with App Store Distribution Exception | Streaming engine for Sunshine / GameStream (video, audio, input), vendored in `Orbit-iOS/Packages/MoonlightCore/Sources/CMoonlight` |
| [ENet](http://enet.bespin.org) (Moonlight fork) | Lee Salzman | MIT | Reliable UDP control channel used by the streaming engine |
| [nanors](https://github.com/sleepybishop/nanors) | Joseph Calderon | MIT | Reed–Solomon forward error correction for the video stream |
| [swift-opus / Copus](https://github.com/alta/swift-opus) | Alta Software | BSD-3-Clause | Swift package wrapping the Opus codec |
| [Opus](https://opus-codec.org) | Xiph.Org Foundation | BSD-3-Clause | Audio decoding for the stream |
| [swift-srp](https://github.com/adam-fowler/swift-srp) | Adam Fowler | Apache-2.0 | SRP-6a password-authenticated key exchange used for 6-digit PIN pairing |
| [big-num](https://github.com/adam-fowler/big-num) | Adam Fowler | MIT | Arbitrary-precision integer arithmetic used by `swift-srp` |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apple Inc. and the SwiftCrypto project authors | Apache-2.0 | Cryptographic primitives used by `swift-srp` (includes derivations from SwiftNIO under Apache-2.0) |
| [swift-asn1](https://github.com/apple/swift-asn1) | Apple Inc. and the SwiftASN1 project authors | Apache-2.0 | ASN.1 parser and serializer used by `swift-crypto` (includes derivations from SwiftNIO under Apache-2.0) |

Not included in the apps, but used by them:

- [Sunshine](https://github.com/LizardByte/Sunshine) by LizardByte (GPLv3) runs on the Windows PC and provides the game stream. Download: https://app.lizardbyte.dev/Sunshine/
- [Moonlight](https://moonlight-stream.org) by the Moonlight Game Streaming Project (GPLv3) is the reference client; Orbit can hand a stream over to it on macOS.
- [Virtual Display Driver (VDD)](https://github.com/VirtualDrivers/Virtual-Display-Driver) by MikeTheTech and VirtualDrivers (MIT) can be installed on the Windows PC for Fill Screen and Second Screen streaming.
- [OBS Studio (`obs-websocket`)](https://obsproject.com) by the OBS Project (GPLv2+) runs on the Windows PC; Orbit's Buttons deck can switch scenes and control recording or streaming over its local WebSocket API.
- Orbit Windows Agent (this repository, `Orbit-Windows-Agent/`, Python) is the telemetry and control companion.
- The agent's iPhone webcam uses [Softcam](https://github.com/tshino/softcam) by tshino (MIT), which links Microsoft's DirectShow BaseClasses (MIT). Both run only on the PC; their notices are in `Orbit-Windows-Agent/THIRD_PARTY_NOTICES.md`.
- The agent's Windows audio controls use [pycaw](https://github.com/AndreMiras/pycaw) by Andre Miras and contributors (MIT) and reference the factual `AudioPolicyConfig` COM GUIDs and interface layout from [EarTrumpet](https://github.com/File-New-Project/EarTrumpet) (MIT with excluded entities; see `Orbit-Windows-Agent/THIRD_PARTY_NOTICES.md`).
- Household electricity tariff estimates use public data from **Eurostat** (dataset `nrg_pc_204`, Decision 2011/833/EU and CC BY 4.0; Orbit keeps the newest all-taxes household price per kWh per country and maps `EL` to `GR`), **Ofgem** (contains public sector information licensed under the Open Government Licence v3.0), the **U.S. Energy Information Administration (EIA)** (Electric Power Monthly, public domain), and **ElCom** (Swiss Federal Electricity Commission); see `Orbit-Windows-Agent/THIRD_PARTY_NOTICES.md`.

Orbit, Sunshine and Moonlight are independent projects; Orbit is not affiliated with or endorsed by the Moonlight project, LizardByte, OBS Project, NVIDIA, Microsoft or Apple.

## App Store Distribution Exception (moonlight-common-c)

App Store Distribution Exception

As additional permission under section 7, you are allowed to distribute the
software through an app store, even if that store has restrictive terms and
conditions that are incompatible with the GPL, provided that the source is
also available under the GPL with or without this permission through a channel
without those restrictive terms and conditions.
