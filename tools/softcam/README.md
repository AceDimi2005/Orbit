# Softcam DLLs for the iPhone webcam

Orbit's iPhone webcam feature on Windows uses [Softcam](https://github.com/tshino/softcam) (MIT, by
tshino), a DirectShow filter that apps using DirectShow cameras see as a webcam (Chrome, Edge, Teams,
Discord, Zoom, OBS; not the Windows Camera app). The DLLs are not built on a developer PC. The GitHub Actions workflow
[`.github/workflows/softcam.yml`](../../.github/workflows/softcam.yml) builds them on `windows-latest`:

1. It checks out `tshino/softcam` at the pinned commit (`SOFTCAM_COMMIT` in the workflow, tag `v1.8.1`)
   and checks that the commit and the project layout are what the workflow expects. softcam has no git
   submodules: the DirectShow BaseClasses are vendored in `src/baseclasses` and linked statically into
   `softcam.dll`. They are Microsoft's code from
   [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/Win7Samples/multimedia/directshow/baseclasses)
   under Microsoft's own MIT license, so that notice ships with the DLLs too.
2. It runs `nuget restore softcam.sln`, then `msbuild softcam.sln /p:Configuration=Release` for
   `/p:Platform=x64` and `/p:Platform=Win32`, with softcam's own project settings (toolset v143).
3. It runs softcam's `core_tests.exe` and `dll_tests.exe` for both platforms.
4. `softcam_artifact.py package` builds the **`orbit-softcam`** artifact:

| File | Content |
|---|---|
| `softcam64.dll` | `dist/bin/x64/softcam.dll`, checked to be a 64-bit DLL |
| `softcam32.dll` | `dist/bin/Win32/softcam.dll`, checked to be a 32-bit DLL |
| `LICENSE` | softcam's MIT license (LF line endings, as upstream) |
| `LICENSE-BaseClasses` | Microsoft's MIT license for the DirectShow BaseClasses, from [`LICENSE-BaseClasses`](LICENSE-BaseClasses) here (copied unchanged from Windows-classic-samples at a pinned commit) |
| `UPSTREAM_COMMIT` | the exact upstream commit, one line |
| `BUILD-INFO.txt` | tag, toolset, MSVC tools version, minimum Visual C++ runtime, Visual Studio, runner image, Orbit commit, run URL, linker version, exports and imports of each DLL |
| `SHA256SUMS` | SHA-256 of every file above, `sha256sum -c` format |

The PDB files go in a separate artifact, `orbit-softcam-symbols`, for crash reports.

The workflow runs on demand (**Actions → Softcam DLLs → Run workflow**) and on pushes to `main` that
change the workflow or this folder. Artifacts are kept for 90 days.

## Taking a build into the agent

```sh
gh run list --workflow softcam.yml --limit 5
gh run download <run-id> --name orbit-softcam --dir /tmp/orbit-softcam
python3 tools/softcam/softcam_artifact.py verify /tmp/orbit-softcam --commit afb424c2415b04da627fa1a7b4706575c2ba3010
```

`verify` checks every checksum, that `softcam64.dll` is x64 and `softcam32.dll` is x86, that both
export the sender API (`scCreateCamera`, `scDeleteCamera`, `scSendFrame`, `scWaitForConnection`,
`scIsConnected`) and the COM entry points used by `regsvr32`, and that both licenses are present. It
prints the SHA-256 values and the minimum Visual C++ runtime to pin in the agent. Finder's `.DS_Store`
(and `Thumbs.db`, `desktop.ini`, `._*` files) are ignored; any other extra file fails the check.

Then copy `softcam64.dll`, `softcam32.dll`, `LICENSE` and `LICENSE-BaseClasses` to
`Orbit-Windows-Agent/webcam/`, and list both components in `THIRD_PARTY_NOTICES.md`: **Softcam**
(tshino, MIT) and **DirectShow BaseClasses** (Microsoft, MIT). The DLLs contain both, and MIT needs
each copyright notice to travel with them.

Things the agent has to handle:

- **Visual C++ runtime.** The Release DLLs link the runtime dynamically (`/MD`; `BUILD-INFO.txt`
  lists the imports, such as `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll` or `MSVCP140.dll`). Microsoft
  supports a Redistributable only when it is at least as new as the build tools. That version is the
  `Minimum Visual C++ runtime` line in `BUILD-INFO.txt`, which `verify` also prints: 14.44 for the
  default v143 toolset on today's `windows-latest` (MSVC 14.44.35207), 14.50 or later with a v145
  override. It comes from the linker version stamped in the DLLs, and `MSVC tools` records the full
  tools version. The PC needs the Visual C++ v14 Redistributable at or above that version for **both**
  x64 and x86. Before running `regsvr32`, the agent reads
  `HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64` and `...\Runtimes\x86`. It requires
  `Installed` = 1 and (`Major`, `Minor`) at least the pinned minimum (`Bld` and the `Version` string,
  e.g. `v14.44.35211.00`, are informational). It looks in both registry views, because the installers
  usually write under `WOW6432Node`. If the runtime is missing or older, the agent sends the user to the
  [latest supported Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)
  (x64 and x86) instead of letting `regsvr32` fail to load the DLL. A presence-only check is not enough,
  because an old 14.2x runtime would pass it.
- **Both bitnesses.** DirectShow filters load inside each camera app, so the 64-bit DLL is registered
  with `%SystemRoot%\System32\regsvr32.exe` and the 32-bit one with `%SystemRoot%\SysWOW64\regsvr32.exe`.
  Registration writes the DLL's absolute path, so copy the DLLs to their final folder first.
- **Name and identity.** Upstream softcam appears as "DirectShow Softcam" with a fixed CLSID
  (`{AEF3B972-5FA5-4647-9571-358EB472BC9E}`, `src/softcam/softcam.cpp`) and fixed shared-memory and mutex
  names (`src/softcamcore/FrameBuffer.cpp`). Another app built on unmodified softcam uses the same ones.
- **Unsigned.** The DLLs are not code-signed; SmartScreen, Smart App Control or antivirus can object.

## Updating softcam

Pick the new tag, get its commit with `gh api repos/tshino/softcam/git/ref/tags/<tag>` (for an annotated
tag, follow `object.url` to the commit), update `SOFTCAM_TAG` and `SOFTCAM_COMMIT` in the workflow,
read upstream's `CHANGELOG.md` for API changes (the next release changes what `scIsConnected` and
`scWaitForConnection` report after a disconnect), and run the workflow. Also read upstream's README
"License" section. If softcam picks up other third-party code, or the BaseClasses license changes, add
or refresh the license files here. `test_softcam_artifact.py` checks that the text under the line in
`LICENSE-BaseClasses` is still byte-for-byte the upstream file (git blob
`02a131eabfe560723b3a70efc5ac2a150eac967a`).

Tests for the packaging script (no Windows needed):

```sh
python3 -m unittest discover -s tools/softcam -p 'test_*.py' -v
```
