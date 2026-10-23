# Third-party notices

## EarTrumpet audio policy interface definitions

Orbit's independently written Python audio policy adapter references the factual
GUIDs and interface layout from the original EarTrumpet project:
https://github.com/File-New-Project/EarTrumpet

Original source paths:

- `EarTrumpet/Interop/MMDeviceAPI/IAudioPolicyConfigFactoryVariantFor21H2.cs`
- `EarTrumpet/Interop/MMDeviceAPI/IAudioPolicyConfigFactoryVariantForDownlevel.cs`
- `EarTrumpet/DataModel/WindowsAudio/Internal/AudioPolicyConfigService.cs`

The original project's license is reproduced below in full. It includes explicit
excluded entities in addition to the MIT terms.

The following legal persons or entities (collectively, the "Excluded Entities") are
expressly excluded from the licensing terms set forth below and, as such, do not
have the right to reproduce, distribute, or create derivative works from the
software or associated documentation files:

    Yellow Elephant Productions
    Tidal Media Inc.
    Articent Group LLC

The Excluded Entities may not exercise any of the rights granted to other users
under these licensing terms.

---

The MIT License (MIT)

Copyright (c) 2015

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Softcam (iPhone webcam)

`webcam/softcam64.dll` and `webcam/softcam32.dll` are unmodified builds of Softcam, a DirectShow
virtual camera by tshino: https://github.com/tshino/softcam (tag v1.8.1, commit
afb424c2415b04da627fa1a7b4706575c2ba3010), built by this repository's
`.github/workflows/softcam.yml`. Orbit PC Companion copies them to
`%ProgramFiles%\Orbit\Webcam\` and registers them when you set up the iPhone webcam (and
unregisters and deletes them when you remove it). The license also ships as
`webcam/LICENSE-softcam.txt`.

MIT License

Copyright (c) 2020 tshino

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## DirectShow BaseClasses (inside the Softcam DLLs)

The Softcam DLLs statically link Microsoft's DirectShow BaseClasses, which Softcam vendors in
`src/baseclasses`. They come from Microsoft's Windows-classic-samples repository
(`Samples/Win7Samples/multimedia/directshow/baseclasses`,
https://github.com/microsoft/Windows-classic-samples). The license also ships as
`webcam/LICENSE-BaseClasses.txt`.

The MIT License (MIT)

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
