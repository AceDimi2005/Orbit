"""Package and verify the Softcam DLLs that Orbit's iPhone-webcam feature ships.

The GitHub Actions workflow `.github/workflows/softcam.yml` builds tshino/softcam (MIT) at a
pinned commit and calls `package`; whoever commits the DLLs to `Orbit-Windows-Agent/webcam/`
runs `verify` on the downloaded artifact first. Standard library only, so it runs the same on
the Windows runner and on a Mac.

    python tools/softcam/softcam_artifact.py package --source <softcam checkout> --out <folder>
        --repository tshino/softcam --tag v1.8.1 --commit <40-hex SHA> [--info "Key: value" ...]
    python tools/softcam/softcam_artifact.py verify <folder> [--commit <40-hex SHA>]

`verify` checks SHA256SUMS against every file, that softcam64.dll is a 64-bit (x64) DLL and
softcam32.dll a 32-bit (x86) DLL, that both export the Softcam sender API plus the COM
registration entry points, and that both licenses are there (softcam's, and Microsoft's for the
DirectShow BaseClasses linked into the DLLs). It prints the SHA-256 values to pin in the agent and
the oldest Visual C++ runtime the DLLs need. Finder/Explorer metadata such as .DS_Store is ignored.
"""

import argparse
import hashlib
import re
import shutil
import struct
import sys
from pathlib import Path

DLL64 = "softcam64.dll"
DLL32 = "softcam32.dll"
LICENSE = "LICENSE"
BASECLASSES_LICENSE = "LICENSE-BaseClasses"
COMMIT_FILE = "UPSTREAM_COMMIT"
INFO_FILE = "BUILD-INFO.txt"
SUMS_FILE = "SHA256SUMS"
CONTENT_FILES = (DLL64, DLL32, LICENSE, BASECLASSES_LICENSE, COMMIT_FILE, INFO_FILE)

# softcam.dll statically links the DirectShow BaseClasses that softcam vendors in src/baseclasses.
# They are Microsoft's (Windows-classic-samples, MIT), so their notice ships next to softcam's.
# The text lives next to this script, copied unchanged from a pinned upstream commit.
BASECLASSES_LICENSE_SOURCE = Path(__file__).resolve().parent / BASECLASSES_LICENSE
BASECLASSES_NOTICE = b"Copyright (c) Microsoft Corporation"
MIT_MARKER = b"MIT License"

# What Finder, Explorer and macOS file copies drop into a folder someone opened; never part of
# the artifact, so verify() looks past them instead of calling the download tampered.
OS_METADATA = frozenset({".ds_store", "thumbs.db", "ehthumbs.db", "desktop.ini"})

# A DLL importing one of these needs the Visual C++ v14 Redistributable (it was built with /MD).
RUNTIME_IMPORT = re.compile(r"(vcruntime|msvcp)140(_\w+)?\.dll", re.IGNORECASE)

# From src/softcam/softcam.def at the pinned commit. The sc* functions are the sender API the
# agent calls through ctypes; the Dll* functions are what regsvr32 and COM need.
REQUIRED_EXPORTS = (
    "DllCanUnloadNow",
    "DllGetClassObject",
    "DllRegisterServer",
    "DllUnregisterServer",
    "scCreateCamera",
    "scDeleteCamera",
    "scIsConnected",
    "scSendFrame",
    "scWaitForConnection",
)

MACHINE_X64 = 0x8664
MACHINE_X86 = 0x014C
MAGIC_PE32 = 0x10B
MAGIC_PE32_PLUS = 0x20B
IMAGE_FILE_DLL = 0x2000

# (published name, build output under the softcam checkout, machine, optional-header magic)
BUILDS = (
    (DLL64, ("dist", "bin", "x64", "softcam.dll"), MACHINE_X64, MAGIC_PE32_PLUS),
    (DLL32, ("dist", "bin", "Win32", "softcam.dll"), MACHINE_X86, MAGIC_PE32),
)
ARCHITECTURES = {MACHINE_X64: "x64 (PE32+)", MACHINE_X86: "x86 (PE32)"}
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")


class ArtifactError(Exception):
    """The build output or the artifact is not what Orbit expects."""


class PortableExecutable:
    """The few PE/COFF facts we check: machine, DLL flag, exported and imported names."""

    def __init__(self, data):
        self.data = data
        if self._unpack("<2s", 0)[0] != b"MZ":
            raise ArtifactError("not a Windows executable (no MZ header)")
        header = self._unpack("<I", 0x3C)[0]
        if self._unpack("<4s", header)[0] != b"PE\0\0":
            raise ArtifactError("not a Windows executable (no PE signature)")
        (self.machine, sections, _, _, _, optional_size,
         self.characteristics) = self._unpack("<HHIIIHH", header + 4)
        optional = header + 24
        self.magic = self._unpack("<H", optional)[0]
        # MajorLinkerVersion.MinorLinkerVersion: the MSVC version of link.exe, e.g. 14.44.
        self.linker_version = self._unpack("<BB", optional + 2)
        if self.magic == MAGIC_PE32:
            count_offset, directories = optional + 92, optional + 96
        elif self.magic == MAGIC_PE32_PLUS:
            count_offset, directories = optional + 108, optional + 112
        else:
            raise ArtifactError(f"unknown optional header magic 0x{self.magic:x}")
        self.directory_count = self._unpack("<I", count_offset)[0]
        self.directories = directories
        if directories - optional > optional_size:
            raise ArtifactError("optional header is truncated")
        table = optional + optional_size
        self.sections = []
        for index in range(sections):
            (_, virtual_size, address, raw_size,
             raw_pointer) = self._unpack("<8sIIII", table + index * 40)
            self.sections.append((address, max(virtual_size, raw_size), raw_pointer, raw_size))

    @property
    def is_dll(self):
        return bool(self.characteristics & IMAGE_FILE_DLL)

    def _unpack(self, layout, offset):
        size = struct.calcsize(layout)
        if offset < 0 or offset + size > len(self.data):
            raise ArtifactError("file is truncated")
        return struct.unpack_from(layout, self.data, offset)

    def _directory(self, index):
        if index >= self.directory_count:
            return 0, 0
        return self._unpack("<II", self.directories + index * 8)

    def _offset(self, rva):
        for address, span, raw_pointer, raw_size in self.sections:
            if address <= rva < address + span:
                delta = rva - address
                if delta >= raw_size:
                    raise ArtifactError("address points outside the file data")
                return raw_pointer + delta
        raise ArtifactError(f"address 0x{rva:x} is not inside any section")

    def _string(self, rva):
        start = self._offset(rva)
        end = self.data.find(b"\0", start, start + 512)
        if end < 0:
            raise ArtifactError("unterminated name")
        return self.data[start:end].decode("ascii")

    def exports(self):
        rva, size = self._directory(0)
        if not rva or not size:
            return []
        directory = self._offset(rva)
        count, names = self._unpack("<II", directory + 24)[0], self._unpack("<I", directory + 32)[0]
        if count > 65536:
            raise ArtifactError("implausible export count")
        table = self._offset(names) if count else 0
        return sorted(self._string(self._unpack("<I", table + index * 4)[0]) for index in range(count))

    def imports(self):
        rva, size = self._directory(1)
        if not rva or not size:
            return []
        position = self._offset(rva)
        result = []
        for _ in range(4096):
            descriptor = self._unpack("<IIIII", position)
            if not any(descriptor):
                return result
            result.append(self._string(descriptor[3]))
            position += 20
        raise ArtifactError("import table is not terminated")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_dll(path, machine, magic):
    """Return a one-line description of a DLL after checking it is the expected build."""
    image = PortableExecutable(Path(path).read_bytes())
    name = Path(path).name
    if image.machine != machine or image.magic != magic:
        found = ARCHITECTURES.get(image.machine, f"machine 0x{image.machine:x}")
        raise ArtifactError(f"{name} is {found}, expected {ARCHITECTURES[machine]}")
    if not image.is_dll:
        raise ArtifactError(f"{name} is not a DLL")
    exports = image.exports()
    missing = [symbol for symbol in REQUIRED_EXPORTS if symbol not in exports]
    if missing:
        raise ArtifactError(f"{name} does not export {', '.join(missing)}")
    linker = "{}.{}".format(*image.linker_version)
    return (f"{name}: {ARCHITECTURES[machine]} DLL; linker {linker}; exports {', '.join(exports)}; "
            f"imports {', '.join(image.imports()) or 'nothing'}")


def runtime_minimum(paths):
    """The oldest Visual C++ v14 Redistributable the DLLs support, as "14.44", or None.

    Microsoft supports a Redistributable only if it is at least as new as the build tools that
    produced the binary, and link.exe stamps its MSVC version into every image it writes. None
    means no DLL imports VCRUNTIME140/MSVCP140 (static runtime, nothing to install).
    """
    versions = []
    for path in paths:
        image = PortableExecutable(Path(path).read_bytes())
        if any(RUNTIME_IMPORT.fullmatch(name) for name in image.imports()):
            versions.append(tuple(image.linker_version))
    if not versions:
        return None
    return "{}.{}".format(*max(versions))


def runtime_line(minimum):
    if minimum is None:
        return "Visual C++ runtime: linked statically, no Redistributable needed"
    return (f"Minimum Visual C++ runtime: {minimum} (x64 and x86 Visual C++ v14 Redistributable "
            f"at least this version; the MSVC linker version stamped in the DLLs)")


def is_os_metadata(name):
    # "._name" files are macOS AppleDouble companions written on non-Apple volumes.
    return name.lower() in OS_METADATA or name.startswith("._")


def read_license(path, label, *markers):
    """A license file's bytes with LF endings (a Windows checkout may hold CRLF; upstream uses LF)."""
    path = Path(path)
    if not path.is_file():
        raise ArtifactError(f"{label} was not found at {path}")
    data = path.read_bytes().replace(b"\r\n", b"\n")
    if not all(marker in data for marker in markers):
        raise ArtifactError(f"{path} is not {label}")
    return data


def write_text(path, text):
    # LF endings on every platform so `sha256sum -c` / `shasum -a 256 -c` read SHA256SUMS anywhere.
    Path(path).write_bytes(text.encode("utf-8"))


def package(source, out, repository, tag, commit, info=(),
            baseclasses_license=BASECLASSES_LICENSE_SOURCE):
    source, out = Path(source), Path(out)
    if not COMMIT_PATTERN.fullmatch(commit):
        raise ArtifactError("the upstream commit must be a full 40-character lowercase SHA")
    if out.exists() and any(out.iterdir()):
        raise ArtifactError(f"{out} is not empty")
    out.mkdir(parents=True, exist_ok=True)
    descriptions = []
    for published, build_path, machine, magic in BUILDS:
        built = source.joinpath(*build_path)
        if not built.is_file():
            raise ArtifactError(f"missing build output {built}")
        shutil.copyfile(built, out / published)
        descriptions.append(inspect_dll(out / published, machine, magic))
    (out / LICENSE).write_bytes(read_license(source / "LICENSE", "softcam's MIT LICENSE", MIT_MARKER))
    (out / BASECLASSES_LICENSE).write_bytes(read_license(
        baseclasses_license, "the DirectShow BaseClasses MIT license", MIT_MARKER, BASECLASSES_NOTICE))
    write_text(out / COMMIT_FILE, commit + "\n")
    lines = [
        "Softcam (DirectShow virtual camera) built for Orbit's iPhone webcam",
        f"Upstream: https://github.com/{repository}",
        f"Tag: {tag}",
        f"Commit: {commit}",
        "License: MIT, softcam (see LICENSE)",
        "License: MIT, DirectShow BaseClasses by Microsoft, linked into the DLLs "
        "(see LICENSE-BaseClasses)",
        "Build: msbuild softcam.sln /p:Configuration=Release for /p:Platform=x64 and /p:Platform=Win32",
        runtime_line(runtime_minimum(out / published for published, *_ in BUILDS)),
        *info,
        "",
        *descriptions,
    ]
    write_text(out / INFO_FILE, "\n".join(lines) + "\n")
    write_text(out / SUMS_FILE, "".join(f"{sha256(out / name)}  {name}\n" for name in CONTENT_FILES))
    return verify(out, commit)


def read_sums(path):
    sums = {}
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64}) [ *](\S+)", line)
        if not match or match.group(2) in sums:
            raise ArtifactError(f"{SUMS_FILE} line {number} is malformed or repeated")
        sums[match.group(2)] = match.group(1)
    return sums


def verify(folder, commit=None):
    """Check a packaged folder; return {file name: SHA-256} for the DLLs."""
    folder = Path(folder)
    if not (folder / SUMS_FILE).is_file():
        raise ArtifactError(f"{SUMS_FILE} is missing in {folder}")
    sums = read_sums(folder / SUMS_FILE)
    if set(sums) != set(CONTENT_FILES):
        raise ArtifactError(f"{SUMS_FILE} must list exactly {', '.join(CONTENT_FILES)}")
    present = {path.name for path in folder.iterdir() if not is_os_metadata(path.name)}
    unexpected = sorted(present - set(CONTENT_FILES) - {SUMS_FILE})
    if unexpected:
        raise ArtifactError(f"unexpected files: {', '.join(unexpected)}")
    for name, expected in sums.items():
        if not (folder / name).is_file():
            raise ArtifactError(f"{name} is missing")
        if sha256(folder / name) != expected:
            raise ArtifactError(f"{name} does not match {SUMS_FILE}")
    recorded = (folder / COMMIT_FILE).read_text(encoding="utf-8").strip()
    if not COMMIT_PATTERN.fullmatch(recorded):
        raise ArtifactError(f"{COMMIT_FILE} does not hold a full commit SHA")
    if commit is not None and recorded != commit:
        raise ArtifactError(f"{COMMIT_FILE} is {recorded}, expected {commit}")
    if MIT_MARKER not in (folder / LICENSE).read_bytes():
        raise ArtifactError("LICENSE is not softcam's MIT license")
    notice = (folder / BASECLASSES_LICENSE).read_bytes()
    if MIT_MARKER not in notice or BASECLASSES_NOTICE not in notice:
        raise ArtifactError(f"{BASECLASSES_LICENSE} is not Microsoft's MIT license for the BaseClasses")
    for published, _, machine, magic in BUILDS:
        inspect_dll(folder / published, machine, magic)
    return {published: sums[published] for published, *_ in BUILDS}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("package", help="copy, check and checksum a fresh build")
    build.add_argument("--source", required=True, help="the built softcam checkout")
    build.add_argument("--out", required=True, help="empty folder for the artifact")
    build.add_argument("--repository", default="tshino/softcam")
    build.add_argument("--tag", required=True)
    build.add_argument("--commit", required=True)
    build.add_argument("--info", action="append", default=[], help='extra "Key: value" line for BUILD-INFO.txt')
    build.add_argument("--baseclasses-license", default=str(BASECLASSES_LICENSE_SOURCE),
                       help="Microsoft's MIT license for the DirectShow BaseClasses "
                            "(default: the copy next to this script)")
    check = commands.add_parser("verify", help="check a downloaded orbit-softcam artifact")
    check.add_argument("folder")
    check.add_argument("--commit", help="fail unless UPSTREAM_COMMIT matches")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "package":
            folder = Path(arguments.out)
            digests = package(arguments.source, folder, arguments.repository, arguments.tag,
                              arguments.commit, arguments.info, arguments.baseclasses_license)
        else:
            folder = Path(arguments.folder)
            digests = verify(folder, arguments.commit)
        minimum = runtime_minimum(folder / published for published, *_ in BUILDS)
    except (ArtifactError, OSError, UnicodeError) as error:
        print(f"softcam artifact: {error}", file=sys.stderr)
        return 1
    for name, digest in digests.items():
        print(f"{name} sha256 {digest}")
    print(f"minimum VC++ runtime {minimum}" if minimum else "VC++ runtime linked statically")
    return 0


if __name__ == "__main__":
    sys.exit(main())
