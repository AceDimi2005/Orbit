# Softcam DLLs for the iPhone webcam

Orbit's iPhone webcam feature on Windows uses [Softcam](https://github.com/tshino/softcam) (MIT, by
tshino), a DirectShow filter that apps using DirectShow cameras see as a webcam (Chrome, Edge, Teams,
Discord, Zoom, OBS; not the Windows Camera app). The DLLs are not built on a developer PC. The GitHub Actions workflow
[`.github/workflows/softcam.yml`](../../.github/workflows/softcam.yml) builds them on `windows-latest`:

1. It checks out `tshino/softcam` at the pinned commit (`SOFTCAM_COMMIT` in the workflow, tag `v1.8.1`)
   and checks that the commit and the project layout are what the workflow expects. softcam has no git
   submodules: the DirectShow base classes are vendored in `src/baseclasses`.
2. It runs `nuget restore softcam.sln`, then `msbuild softcam.sln /p:Configuration=Release` for
   `/p:Platform=x64` and `/p:Platform=Win32`, with softcam's own project settings (toolset v143).
3. It runs softcam's `core_tests.exe` and `dll_tests.exe` for both platforms.
4. `softcam_artifact.py package` builds the **`orbit-softcam`** artifact:

| File | Content |
|---|---|
| `softcam64.dll` | `dist/bin/x64/softcam.dll`, checked to be a 64-bit DLL |
| `softcam32.dll` | `dist/bin/Win32/softcam.dll`, checked to be a 32-bit DLL |
| `LICENSE` | softcam's MIT license (LF line endings, as upstream) |
| `UPSTREAM_COMMIT` | the exact upstream commit, one line |
| `BUILD-INFO.txt` | tag, toolset, Visual Studio, runner image, Orbit commit, run URL, exports and imports of each DLL |
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

`verify` checks every checksum, that `softcam64.dll` is x64 and `softcam32.dll` is x86, and that both
export the sender API (`scCreateCamera`, `scDeleteCamera`, `scSendFrame`, `scWaitForConnection`,
`scIsConnected`) and the COM entry points used by `regsvr32`. It prints the SHA-256 values to pin in
the agent. Then copy the two DLLs and `LICENSE` to `Orbit-Windows-Agent/webcam/` and list Softcam in
`THIRD_PARTY_NOTICES.md`.

Things the agent has to handle:

- **Visual C++ runtime.** The Release DLLs link the runtime dynamically (`/MD`); `BUILD-INFO.txt`
  lists the imported DLLs (`VCRUNTIME140.dll`, and `MSVCP140.dll` when listed). The PC needs the Visual
  C++ 2015–2022 Redistributable for x64 and for x86, or `regsvr32` fails to load the DLL.
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
`scWaitForConnection` report after a disconnect), and run the workflow.

Tests for the packaging script (no Windows needed):

```sh
python3 -m unittest discover -s tools/softcam -p 'test_*.py' -v
```
