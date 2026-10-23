"""Tests for softcam_artifact.py with small synthetic PE files (no Windows needed).

    python -m unittest discover -s tools/softcam -p 'test_*.py' -v
"""

import contextlib
import hashlib
import io
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import softcam_artifact as artifact  # noqa: E402

COMMIT = "afb424c2415b04da627fa1a7b4706575c2ba3010"
EXPORTS = ("DllMain",) + artifact.REQUIRED_EXPORTS
IMPORTS = ("WINMM.dll", "KERNEL32.dll", "ole32.dll", "VCRUNTIME140.dll")
MIT = b"MIT License\n\nCopyright (c) 2020 tshino\n"


def build_pe(machine, magic, exports=EXPORTS, imports=IMPORTS, dll=True):
    """A minimal but well-formed PE image: headers plus one section holding the tables."""
    section_rva, raw_offset = 0x1000, 0x400
    body = bytearray()

    def add(blob, align=4):
        while len(body) % align:
            body.append(0)
        offset = len(body)
        body.extend(blob)
        return section_rva + offset

    export_rva = export_size = 0
    if exports:
        names = [add(name.encode() + b"\0", 1) for name in sorted(exports)]
        name_table = add(b"".join(struct.pack("<I", rva) for rva in names))
        ordinals = add(b"".join(struct.pack("<H", index) for index in range(len(names))))
        functions = add(struct.pack("<I", section_rva) * len(names))
        module = add(b"softcam.dll\0", 1)
        directory = struct.pack("<IIHHIIIIIII", 0, 0, 0, 0, module, 1, len(names), len(names),
                                functions, name_table, ordinals)
        export_rva, export_size = add(directory), len(directory)
    plus = magic == artifact.MAGIC_PE32_PLUS
    import_rva = import_size = 0
    if imports:
        thunk = "<Q" if plus else "<I"
        descriptors = b""
        for name in imports:
            module = add(name.encode() + b"\0", 1)
            by_name = add(struct.pack("<H", 0) + b"Function\0", 2)
            lookup = add(struct.pack(thunk, by_name) + struct.pack(thunk, 0), 8)
            bound = add(struct.pack(thunk, by_name) + struct.pack(thunk, 0), 8)
            descriptors += struct.pack("<IIIII", lookup, 0, 0, module, bound)
        table = descriptors + bytes(20)
        import_rva, import_size = add(table), len(table)
    while len(body) % 0x200:
        body.append(0)

    optional_size = 240 if plus else 224
    optional = bytearray(optional_size)
    struct.pack_into("<H", optional, 0, magic)
    struct.pack_into("<II", optional, 32, 0x1000, 0x200)  # section and file alignment
    struct.pack_into("<II", optional, 56, section_rva + len(body), raw_offset)  # image, headers
    struct.pack_into("<H", optional, 68, 2)  # Windows GUI subsystem
    struct.pack_into("<I", optional, 108 if plus else 92, 16)
    directories = 112 if plus else 96
    struct.pack_into("<II", optional, directories, export_rva, export_size)
    struct.pack_into("<II", optional, directories + 8, import_rva, import_size)

    characteristics = 0x0002 | (0x0020 if plus else 0x0100) | (artifact.IMAGE_FILE_DLL if dll else 0)
    coff = struct.pack("<HHIIIHH", machine, 1, 0, 0, 0, optional_size, characteristics)
    section = struct.pack("<8sIIIIIIHHI", b".rdata", len(body), section_rva, len(body), raw_offset,
                          0, 0, 0, 0, 0x40000040)
    dos = bytearray(0x40)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x40)
    headers = bytes(dos) + b"PE\0\0" + coff + bytes(optional) + section
    return headers.ljust(raw_offset, b"\0") + bytes(body)


def dll64(**options):
    return build_pe(artifact.MACHINE_X64, artifact.MAGIC_PE32_PLUS, **options)


def dll32(**options):
    return build_pe(artifact.MACHINE_X86, artifact.MAGIC_PE32, **options)


class PortableExecutableTests(unittest.TestCase):
    def test_reads_machine_exports_and_imports_of_both_architectures(self):
        for data, machine, magic in ((dll64(), artifact.MACHINE_X64, artifact.MAGIC_PE32_PLUS),
                                     (dll32(), artifact.MACHINE_X86, artifact.MAGIC_PE32)):
            image = artifact.PortableExecutable(data)
            self.assertEqual((image.machine, image.magic), (machine, magic))
            self.assertTrue(image.is_dll)
            self.assertEqual(image.exports(), sorted(EXPORTS))
            self.assertEqual(image.imports(), list(IMPORTS))

    def test_image_without_tables_has_no_exports_or_imports(self):
        image = artifact.PortableExecutable(dll64(exports=(), imports=()))
        self.assertEqual((image.exports(), image.imports()), ([], []))

    def test_garbage_and_truncated_files_raise_artifact_errors_only(self):
        good = dll64()
        for data in (b"", b"MZ", b"PK\x03\x04" + bytes(200), good[:0x80], good[:0x410],
                     good[:0x40] + b"NE\0\0" + good[0x44:]):
            with self.assertRaises(artifact.ArtifactError):
                image = artifact.PortableExecutable(data)
                image.exports()
                image.imports()


class InspectTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)

    def tearDown(self):
        self.folder.cleanup()

    def inspect(self, data, machine=artifact.MACHINE_X64, magic=artifact.MAGIC_PE32_PLUS):
        path = self.root / "softcam64.dll"
        path.write_bytes(data)
        return artifact.inspect_dll(path, machine, magic)

    def test_accepts_the_expected_build_and_reports_runtime_imports(self):
        description = self.inspect(dll64())
        self.assertIn("x64 (PE32+) DLL", description)
        self.assertIn("scSendFrame", description)
        self.assertIn("VCRUNTIME140.dll", description)

    def test_rejects_the_other_architecture(self):
        with self.assertRaisesRegex(artifact.ArtifactError, r"is x86 \(PE32\), expected x64"):
            self.inspect(dll32())

    def test_rejects_missing_sender_api_and_executables(self):
        with self.assertRaisesRegex(artifact.ArtifactError, "does not export scSendFrame"):
            self.inspect(dll64(exports=[name for name in EXPORTS if name != "scSendFrame"]))
        with self.assertRaisesRegex(artifact.ArtifactError, "is not a DLL"):
            self.inspect(dll64(dll=False))


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        root = Path(self.folder.name)
        self.source, self.out = root / "softcam", root / "orbit-softcam"
        for platform, data in (("x64", dll64()), ("Win32", dll32())):
            target = self.source / "dist" / "bin" / platform
            target.mkdir(parents=True)
            (target / "softcam.dll").write_bytes(data)
        (self.source / "LICENSE").write_bytes(MIT)

    def tearDown(self):
        self.folder.cleanup()

    def package(self):
        return artifact.package(self.source, self.out, "tshino/softcam", "v1.8.1", COMMIT,
                                ["Orbit commit: 0123456"])

    def test_package_renames_checksums_and_records_the_commit(self):
        digests = self.package()
        self.assertEqual(sorted(path.name for path in self.out.iterdir()),
                         sorted(artifact.CONTENT_FILES + (artifact.SUMS_FILE,)))
        self.assertEqual((self.out / "softcam64.dll").read_bytes(), dll64())
        self.assertEqual((self.out / "softcam32.dll").read_bytes(), dll32())
        self.assertEqual((self.out / "LICENSE").read_bytes(), MIT)
        self.assertEqual((self.out / "UPSTREAM_COMMIT").read_bytes(), (COMMIT + "\n").encode())
        self.assertEqual(digests, {"softcam64.dll": hashlib.sha256(dll64()).hexdigest(),
                                   "softcam32.dll": hashlib.sha256(dll32()).hexdigest()})
        sums = (self.out / "SHA256SUMS").read_bytes()
        self.assertNotIn(b"\r", sums)
        self.assertIn(f"{digests['softcam64.dll']}  softcam64.dll\n".encode(), sums)
        self.assertEqual(len(sums.splitlines()), len(artifact.CONTENT_FILES))
        info = (self.out / "BUILD-INFO.txt").read_text(encoding="utf-8")
        for expected in (f"Commit: {COMMIT}", "Tag: v1.8.1", "https://github.com/tshino/softcam",
                         "Orbit commit: 0123456", "softcam32.dll: x86 (PE32) DLL"):
            self.assertIn(expected, info)
        self.assertEqual(artifact.verify(self.out, COMMIT), digests)

    def test_package_refuses_swapped_or_missing_builds_and_short_commits(self):
        (self.source / "dist" / "bin" / "x64" / "softcam.dll").write_bytes(dll32())
        with self.assertRaisesRegex(artifact.ArtifactError, "expected x64"):
            self.package()
        (self.source / "dist" / "bin" / "x64" / "softcam.dll").unlink()
        with self.assertRaisesRegex(artifact.ArtifactError, "missing build output"):
            artifact.package(self.source, self.out.with_name("other"), "tshino/softcam", "v1.8.1", COMMIT)
        with self.assertRaisesRegex(artifact.ArtifactError, "40-character"):
            artifact.package(self.source, self.out.with_name("third"), "tshino/softcam", "v1.8.1", "afb424c")

    def test_license_from_a_crlf_checkout_is_published_with_upstream_lf_endings(self):
        (self.source / "LICENSE").write_bytes(MIT.replace(b"\n", b"\r\n"))
        self.package()
        self.assertEqual((self.out / "LICENSE").read_bytes(), MIT)

    def test_package_needs_the_mit_license(self):
        (self.source / "LICENSE").unlink()
        with self.assertRaisesRegex(artifact.ArtifactError, "LICENSE"):
            self.package()

    def test_verify_catches_tampering_extra_files_and_the_wrong_commit(self):
        self.package()
        with self.assertRaisesRegex(artifact.ArtifactError, "UPSTREAM_COMMIT is"):
            artifact.verify(self.out, "0" * 40)
        (self.out / "notes.txt").write_text("x", encoding="utf-8")
        with self.assertRaisesRegex(artifact.ArtifactError, "unexpected files: notes.txt"):
            artifact.verify(self.out)
        (self.out / "notes.txt").unlink()
        data = bytearray((self.out / "softcam32.dll").read_bytes())
        data[-1] ^= 1
        (self.out / "softcam32.dll").write_bytes(bytes(data))
        with self.assertRaisesRegex(artifact.ArtifactError, "softcam32.dll does not match"):
            artifact.verify(self.out)

    def test_verify_rejects_a_renamed_pair_even_with_matching_sums(self):
        self.package()
        first, second = self.out / "softcam64.dll", self.out / "softcam32.dll"
        a, b = first.read_bytes(), second.read_bytes()
        first.write_bytes(b)
        second.write_bytes(a)
        sums = "".join(f"{artifact.sha256(self.out / name)}  {name}\n" for name in artifact.CONTENT_FILES)
        (self.out / "SHA256SUMS").write_text(sums, encoding="utf-8")
        with self.assertRaisesRegex(artifact.ArtifactError, "softcam64.dll is x86"):
            artifact.verify(self.out)

    def test_command_line_prints_pins_and_reports_errors(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(artifact.main(["package", "--source", str(self.source), "--out", str(self.out),
                                            "--tag", "v1.8.1", "--commit", COMMIT]), 0)
            self.assertEqual(artifact.main(["verify", str(self.out), "--commit", COMMIT]), 0)
        self.assertEqual(output.getvalue().count("softcam64.dll sha256 "), 2)
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            self.assertEqual(artifact.main(["verify", str(self.source)]), 1)
        self.assertIn("SHA256SUMS is missing", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
