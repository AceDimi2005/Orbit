import asyncio
import ctypes
import io
from types import SimpleNamespace
from pathlib import Path
import tempfile
import threading
import time
import zipfile
import unittest
from unittest.mock import patch

from fastapi import FastAPI, HTTPException, Request
from fastapi.testclient import TestClient

import orbit_files as files


def authorized(request: Request):
    if request.headers.get("authorization") != "Bearer control":
        raise HTTPException(401, "Control token required")


class FileAPITests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name).resolve()
        app = FastAPI()
        app.include_router(files.create_files_router(authorized))
        self.client = TestClient(app, base_url="https://test", headers={"Authorization": "Bearer control"})

    def tearDown(self):
        self.folder.cleanup()

    def test_all_routes_require_control_token_and_https(self):
        routes = [("GET", "/roots", None), ("GET", "/list", None), ("GET", "/download", None),
                  ("POST", "/upload", None), ("POST", "/mkdir", {}), ("POST", "/rename", {}),
                  ("POST", "/move", {}), ("POST", "/trash", {}),
                  ("POST", "/archive", {}), ("GET", "/archive/" + "a" * 32, None),
                  ("GET", "/archive/" + "a" * 32 + "/download", None),
                  ("DELETE", "/archive/" + "a" * 32, None)]
        for method, route, body in routes:
            with self.subTest(route=route):
                response = self.client.request(method, "/api/files" + route, json=body, headers={"Authorization": "Bearer readonly"})
                self.assertEqual(response.status_code, 401)
                response = self.client.request(method, "http://test/api/files" + route, json=body)
                self.assertEqual(response.status_code, 426)

    def test_listing_hides_secrets_links_and_returns_sorted_pages(self):
        (self.root / "Beta").mkdir()
        (self.root / "alpha.txt").write_bytes(b"123")
        (self.root / "zeta.txt").write_bytes(b"12345")
        (self.root / ".orbit-token").write_text("secret")
        (self.root / "alias").symlink_to(self.root / "alpha.txt")
        response = self.client.get("/api/files/list", params={"path": str(self.root), "limit": 2})
        self.assertEqual(response.status_code, 200)
        value = response.json()
        self.assertEqual(value["total"], 3)
        self.assertEqual([row["name"] for row in value["entries"]], ["Beta", "alpha.txt"])
        self.assertEqual(value["entries"][1]["sizeBytes"], 3)
        self.assertTrue(value["entries"][1]["canPreview"])
        response = self.client.get("/api/files/list", params={"path": str(self.root), "sort": "size", "offset": 1})
        self.assertEqual([row["name"] for row in response.json()["entries"]], ["zeta.txt", "alpha.txt"])
        response = self.client.get("/api/files/list", params={"path": str(self.root), "search": "ALPHA"})
        self.assertEqual(response.json()["total"], 1)

    def test_preview_metadata_bound_does_not_restrict_regular_download(self):
        for name, size in (("small.txt", 3), ("boundary.pdf", files.MAX_PREVIEW_BYTES),
                           ("large.pdf", files.MAX_PREVIEW_BYTES + 1), ("unknown.bin", 3)):
            with (self.root / name).open("wb") as stream:
                stream.truncate(size)  # Sparse files avoid allocating large payloads.
        result = self.client.get("/api/files/list", params={"path": str(self.root)})
        self.assertEqual(result.status_code, 200)
        preview = {entry["name"]: entry["canPreview"] for entry in result.json()["entries"]}
        self.assertEqual(preview, {"small.txt": True, "boundary.pdf": True, "large.pdf": False, "unknown.bin": False})
        result = self.client.get("/api/files/download", params={"path": str(self.root / "large.pdf")}, headers={"Range": "bytes=0-2"})
        self.assertEqual(result.status_code, 206)
        self.assertEqual(result.content, b"\x00\x00\x00")
        self.assertEqual(result.headers["content-range"], f"bytes 0-2/{files.MAX_PREVIEW_BYTES + 1}")

    def test_download_streams_and_supports_byte_ranges(self):
        path = self.root / "file.txt"
        path.write_bytes(b"abcdefghij")
        for header, expected in [("bytes=2-5", b"cdef"), ("bytes=-3", b"hij"), ("bytes=6-", b"ghij")]:
            result = self.client.get("/api/files/download", params={"path": str(path)}, headers={"Range": header})
            self.assertEqual(result.status_code, 206)
            self.assertEqual(result.content, expected)
            self.assertEqual(int(result.headers["content-length"]), len(expected))
            self.assertEqual(result.headers["cache-control"], "no-store")
        result = self.client.get("/api/files/download", params={"path": str(path)}, headers={"Range": "bytes=50-100"})
        self.assertEqual(result.status_code, 416)
        self.assertEqual(self.client.get("/api/files/download", params={"path": str(path)}).content, b"abcdefghij")

    def test_upload_installs_atomically_does_not_overwrite_and_cleans_temporary(self):
        params = {"directory": str(self.root), "name": "uploaded.txt"}
        response = self.client.post("/api/files/upload", params=params, content=b"payload")
        self.assertEqual(response.status_code, 200)
        self.assertEqual((self.root / "uploaded.txt").read_bytes(), b"payload")
        response = self.client.post("/api/files/upload", params=params, content=b"replacement")
        self.assertEqual(response.status_code, 409)
        self.assertEqual((self.root / "uploaded.txt").read_bytes(), b"payload")
        self.assertEqual(len(list(self.root.iterdir())), 1)

    def test_upload_cap_and_incomplete_cleanup(self):
        params = {"directory": str(self.root), "name": "upload.bin"}
        with patch.object(files, "MAX_UPLOAD_BYTES", 3):
            response = self.client.post("/api/files/upload", params=params, content=b"1234")
            self.assertEqual(response.status_code, 413)
        response = self.client.post("/api/files/upload", params=params, content=b"1234", headers={"Content-Length": "5"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_cancelled_upload_removes_partial_file(self):
        class CancelledRequest:
            headers = {}
            async def stream(self):
                yield b"partial"
                raise asyncio.CancelledError()
        with self.assertRaises(asyncio.CancelledError):
            asyncio.run(files.receive_upload(CancelledRequest(), str(self.root), "cancelled.bin"))
        self.assertEqual(list(self.root.iterdir()), [])

    def test_upload_racing_destination_does_not_replace_other_file(self):
        def racing_link(temporary, destination):
            Path(destination).write_bytes(b"other process")
            raise FileExistsError("created concurrently")
        with patch.object(files.os, "link", racing_link):
            response = self.client.post("/api/files/upload", params={"directory": str(self.root), "name": "race.bin"}, content=b"our upload")
        self.assertEqual(response.status_code, 409)
        self.assertEqual((self.root / "race.bin").read_bytes(), b"other process")
        self.assertEqual([p.name for p in self.root.iterdir()], ["race.bin"])

    def test_streamed_upload_cap_cleans_partial_even_without_length(self):
        class StreamRequest:
            headers = {}
            async def stream(self):
                yield b"123"
                yield b"456"
        with patch.object(files, "MAX_UPLOAD_BYTES", 4):
            with self.assertRaises(HTTPException) as result:
                asyncio.run(files.receive_upload(StreamRequest(), str(self.root), "stream.bin"))
        self.assertEqual(result.exception.status_code, 413)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_renaming_ancestor_of_private_store_is_rejected(self):
        with patch.dict(files.os.environ, {"LOCALAPPDATA": str(self.root / "account")}):
            (self.root / "account" / "Orbit").mkdir(parents=True)
            response = self.client.post("/api/files/rename", json={"path": str(self.root / "account"), "name": "other"})
        self.assertEqual(response.status_code, 403)
        self.assertTrue((self.root / "account" / "Orbit").exists())

    def test_inflight_upload_write_finishes_before_cancel_cleanup(self):
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()
        opened = []
        original_fdopen = files.os.fdopen
        class SlowFile:
            def __init__(self, stream): self.stream = stream
            def __enter__(self): return self
            def __exit__(self, *_): self.stream.close()
            def write(self, data):
                entered.set()
                if not release.wait(3): raise TimeoutError("test did not release the write")
                result = self.stream.write(data)
                finished.set()
                return result
            def flush(self): return self.stream.flush()
            def fileno(self): return self.stream.fileno()
        def fdopen(*args):
            stream = SlowFile(original_fdopen(*args))
            opened.append(stream)
            return stream
        class Request:
            headers = {}
            async def stream(self): yield b"partial"
        async def cancel_while_writing():
            upload = asyncio.create_task(files.receive_upload(Request(), str(self.root), "slow.bin"))
            try:
                self.assertTrue(await asyncio.to_thread(entered.wait, 2))
                upload.cancel()
                await asyncio.sleep(0)
                upload.cancel()  # Repeated cancellations must not cancel the worker.
                await asyncio.sleep(0)
                self.assertFalse(opened[0].stream.closed)
                self.assertFalse(upload.done())
            finally:
                release.set()
            with self.assertRaises(asyncio.CancelledError): await upload
        with patch.object(files.os, "fdopen", fdopen):
            asyncio.run(cancel_while_writing())
        self.assertTrue(finished.is_set())
        self.assertTrue(opened[0].stream.closed)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_download_closes_file_when_response_start_fails(self):
        path = self.root / "file.txt"
        path.write_bytes(b"payload")
        response = files.download_response(str(path), SimpleNamespace(headers={}))
        self.assertFalse(response._file_stream.closed)
        async def receive(): return {"type": "http.disconnect"}
        async def send(_): raise OSError("client disconnected before body")
        async def fail_before_body():
            with self.assertRaises(Exception):
                await response({"type": "http", "asgi": {"spec_version": "2.4"}}, receive, send)
        asyncio.run(fail_before_body())
        self.assertTrue(response._file_stream.closed)

    def test_actual_fallback_private_store_is_not_browsable(self):
        home = self.root / "home"
        private = home / ".local" / "share" / "Orbit"
        private.mkdir(parents=True)
        (private / "history.sqlite3").write_bytes(b"private")
        with patch.dict(files.os.environ, {"LOCALAPPDATA": "", "XDG_DATA_HOME": "", "ORBIT_HISTORY_FILE": ""}), patch.object(files.Path, "home", return_value=home):
            result = self.client.get("/api/files/list", params={"path": str(private)})
            self.assertEqual(result.status_code, 403)
            result = self.client.get("/api/files/list", params={"path": str(private.parent)})
            self.assertEqual(result.json()["total"], 0)
            result = self.client.post("/api/files/rename", json={"path": str(private), "name": "moved"})
            self.assertEqual(result.status_code, 403)

    def test_custom_history_database_and_journals_are_hidden_and_immutable(self):
        history = self.root / "my-recordings.db"
        for suffix in ("", "-wal", "-shm", "-journal"):
            Path(str(history) + suffix).write_bytes(b"private")
        (self.root / "document.txt").write_text("allowed")
        with patch.dict(files.os.environ, {"ORBIT_HISTORY_FILE": str(history)}):
            result = self.client.get("/api/files/list", params={"path": str(self.root)})
            self.assertEqual([entry["name"] for entry in result.json()["entries"]], ["document.txt"])
            for suffix in ("", "-wal", "-shm", "-journal"):
                path = str(history) + suffix
                self.assertEqual(self.client.get("/api/files/download", params={"path": path}).status_code, 403)
                self.assertEqual(self.client.post("/api/files/rename", json={"path": path, "name": "renamed.db"}).status_code, 403)

    def test_create_rename_move_without_overwrite(self):
        response = self.client.post("/api/files/mkdir", json={"parent": str(self.root), "name": "folder"})
        self.assertEqual(response.status_code, 200)
        path = self.root / "first.txt"
        path.write_text("first")
        response = self.client.post("/api/files/rename", json={"path": str(path), "name": "next.txt"})
        self.assertEqual(response.status_code, 200)
        renamed = self.root / "next.txt"
        self.assertTrue(renamed.exists())
        response = self.client.post("/api/files/move", json={"path": str(renamed), "destinationDirectory": str(self.root / "folder")})
        self.assertEqual(response.status_code, 200)
        self.assertEqual((self.root / "folder" / "next.txt").read_text(), "first")
        renamed.write_text("second")
        response = self.client.post("/api/files/move", json={"path": str(renamed), "destinationDirectory": str(self.root / "folder")})
        self.assertEqual(response.status_code, 409)
        self.assertEqual(renamed.read_text(), "second")

    def test_rejects_reserved_names_ads_and_traversal(self):
        for name in ("../outside", "file:secret", "CON.txt", "NUL", "file.", "file ", ".orbit-token", "a\\b", "LPT9", ".orbit-upload-secret"):
            response = self.client.post("/api/files/mkdir", json={"parent": str(self.root), "name": name})
            self.assertIn(response.status_code, (403, 422), name)
        for path in ("relative.txt", str(self.root) + "/../secret", str(self.root / ".orbit-token")):
            response = self.client.get("/api/files/download", params={"path": path})
            self.assertIn(response.status_code, (403, 422), path)

    def test_private_orbit_store_and_custom_token_path_are_protected(self):
        with patch.dict(files.os.environ, {"LOCALAPPDATA": str(self.root)}):
            private = self.root / "Orbit"
            private.mkdir()
            (private / "server-key.pem").write_text("private")
            response = self.client.get("/api/files/list", params={"path": str(private)})
            self.assertEqual(response.status_code, 403)
        token = self.root / "special-token.dat"
        token.write_text("secret")
        with patch.dict(files.os.environ, {"ORBIT_TOKEN_PATH": str(token)}):
            response = self.client.get("/api/files/download", params={"path": str(token)})
            self.assertEqual(response.status_code, 403)

    def test_symlink_and_hardlink_cannot_expose_credentials(self):
        token = self.root / ".orbit-token"
        token.write_text("secret")
        link = self.root / "link.txt"
        link.symlink_to(token)
        hard = self.root / "hard.txt"
        files.os.link(token, hard)
        for path in (link, hard):
            result = self.client.get("/api/files/download", params={"path": str(path)})
            self.assertEqual(result.status_code, 403)

    def test_windows_drive_inventory_uses_wide_64_bit_safe_signatures(self):
        class Function:
            def __init__(self, result):
                self.result = result
                self.calls = []
            def __call__(self, *args):
                self.calls.append(args)
                self_test.assertIsNotNone(self.argtypes)
                return self.result
        self_test = self
        kernel = SimpleNamespace(GetLogicalDrives=Function((1 << 2) | (1 << 3)), GetDriveTypeW=Function(3))
        with patch.object(files.os, "name", "nt"), patch.object(files.ctypes, "windll", SimpleNamespace(kernel32=kernel), create=True), patch.object(files, "_known_folder", return_value=None):
            result = files.file_roots()
        self.assertEqual([row["name"] for row in result["roots"]], ["C:", "D:"])
        self.assertEqual(kernel.GetDriveTypeW.argtypes, [ctypes.c_wchar_p])
        self.assertEqual(kernel.GetDriveTypeW.restype, ctypes.c_uint32)

    def test_windows_recycle_only_com_flags_and_aborted_operation(self):
        path = self.root / "keep.txt"
        path.write_text("keep")
        for abort in (0, 1):
            calls = []
            callbacks = []
            table = (ctypes.c_void_p * 23)()
            def install(index, args, callback):
                native = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_void_p, *args)(callback)
                callbacks.append(native)
                table[index] = ctypes.cast(native, ctypes.c_void_p).value
            install(2, [], lambda _: 0)
            install(5, [ctypes.c_uint32], lambda _, flags: calls.append(("flags", flags)) or 0)
            install(18, [ctypes.c_void_p, ctypes.c_void_p], lambda *_: calls.append(("delete",)) or 0)
            install(21, [], lambda _: calls.append(("perform",)) or 0)
            def aborted(_, pointer):
                pointer[0] = abort
                return 0
            install(22, [ctypes.POINTER(ctypes.c_int)], aborted)
            operation = (ctypes.c_void_p * 1)(ctypes.addressof(table))
            item = (ctypes.c_void_p * 1)(ctypes.addressof(table))
            class Function:
                def __init__(self, callback): self.callback = callback
                def __call__(self, *args): return self.callback(*args)
            def assign(pointer, value):
                ctypes.cast(pointer, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.addressof(value)
                return 0
            ole = SimpleNamespace(CoInitializeEx=Function(lambda *_: 0), CoUninitialize=Function(lambda: None),
                CoCreateInstance=Function(lambda *args: assign(args[4], operation)))
            shell = SimpleNamespace(SHCreateItemFromParsingName=Function(lambda *args: assign(args[3], item)))
            with patch.object(files.os, "name", "nt"), patch.object(files, "checked_path", return_value=path), patch.object(files, "_mutation_target"), patch.object(files.ctypes, "OleDLL", lambda name: ole if name == "ole32" else shell, create=True), patch.object(files.ctypes, "WINFUNCTYPE", ctypes.CFUNCTYPE, create=True):
                if abort:
                    with self.assertRaises(HTTPException) as result:
                        files.recycle_path(str(path))
                    self.assertEqual(result.exception.status_code, 409)
                else:
                    self.assertTrue(files.recycle_path(str(path))["ok"])
            self.assertTrue(calls[0][1] & 0x00080000)
            self.assertEqual(calls[1:], [("delete",), ("perform",)])
            self.assertEqual(path.read_text(), "keep")
            self.assertEqual(ole.CoCreateInstance.restype, ctypes.c_long)
            self.assertEqual(shell.SHCreateItemFromParsingName.argtypes[0], ctypes.c_wchar_p)

    def test_recycle_has_no_posix_delete_fallback(self):
        path = self.root / "keep.txt"
        path.write_text("keep")
        response = self.client.post("/api/files/trash", json={"path": str(path)})
        self.assertEqual(response.status_code, 503)
        self.assertEqual(path.read_text(), "keep")

    def test_reject_move_folder_into_itself(self):
        parent = self.root / "folder"
        parent.mkdir()
        child = parent / "child"
        child.mkdir()
        response = self.client.post("/api/files/move", json={"path": str(parent), "destinationDirectory": str(child)})
        self.assertEqual(response.status_code, 422)
        self.assertTrue(parent.exists())

    def test_empty_download_and_missing_file(self):
        empty = self.root / "empty.txt"
        empty.touch()
        response = self.client.get("/api/files/download", params={"path": str(empty)})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b"")
        response = self.client.get("/api/files/download", params={"path": str(self.root / "missing.txt")})
        self.assertEqual(response.status_code, 404)


class FolderArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "Proiecte și poze"
        self.source.mkdir()
        self.archive_root = self.root / "private-output"
        self.archive_directory = patch.object(files, "_archive_directory", return_value=self.archive_root)
        self.archive_directory.start()
        self.manager = files.ArchiveManager()
        app = FastAPI()
        app.include_router(files.create_files_router(authorized, archive_manager=self.manager))
        self.client = TestClient(app, base_url="https://test", headers={"Authorization": "Bearer control"})

    def tearDown(self):
        with self.manager.lock:
            jobs = list(self.manager.jobs.values())
            for job in jobs: job.cancelled.set()
        deadline = time.monotonic() + 3
        while any(not job.worker_finished for job in jobs) and time.monotonic() < deadline:
            time.sleep(0.005)
        with self.manager.lock:
            for job in jobs: self.manager._remove_locked(job)
        self.archive_directory.stop()
        self.temporary.cleanup()

    def create(self):
        result = self.client.post("/api/files/archive", json={"path": str(self.source)})
        self.assertEqual(result.status_code, 202, result.text)
        return result.json()["id"]

    def settled(self, identifier):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            result = self.client.get("/api/files/archive/" + identifier)
            self.assertEqual(result.status_code, 200, result.text)
            value = result.json()
            if value["status"] in ("ready", "failed"): return value
            time.sleep(0.005)
        self.fail("archive worker did not settle")

    def assert_failed_without_partial_zip(self, identifier, message):
        value = self.settled(identifier)
        self.assertEqual(value["status"], "failed", value)
        self.assertIn(message, value["error"])
        self.assertEqual(self.client.get(f"/api/files/archive/{identifier}/download").status_code, 409)
        deadline = time.monotonic() + 2
        while any(self.archive_root.glob("archive-*")) and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertEqual(list(self.archive_root.glob("archive-*")), [])

    def test_folder_zip_preserves_unicode_structure_empty_directories_and_contents(self):
        (self.source / "poze goale").mkdir()
        (self.source / "subfolder").mkdir()
        (self.source / "subfolder" / "mâine.txt").write_text("Salut 🌍", encoding="utf-8")
        (self.source / "empty.txt").touch()
        identifier = self.create()
        status = self.settled(identifier)
        self.assertEqual(status["status"], "ready", status)
        self.assertEqual(status["totalEntries"], 5)
        self.assertEqual(status["totalBytes"], len("Salut 🌍".encode()))
        self.assertEqual(status["progress"], 1)
        self.assertNotIn(str(self.root), str(status))
        response = self.client.get(f"/api/files/archive/{identifier}/download")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["content-type"], "application/zip")
        self.assertEqual(len(response.content), status["archiveBytes"])
        with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
            root = self.source.name + "/"
            self.assertEqual(set(archive.namelist()), {root, root + "poze goale/", root + "subfolder/", root + "subfolder/mâine.txt", root + "empty.txt"})
            self.assertEqual(archive.read(root + "subfolder/mâine.txt").decode(), "Salut 🌍")
            self.assertEqual(archive.read(root + "empty.txt"), b"")
        self.assertEqual((self.source / "subfolder" / "mâine.txt").read_text(), "Salut 🌍")
        response = self.client.get(f"/api/files/archive/{identifier}/download", headers={"Range": "bytes=0-3"})
        self.assertEqual(response.status_code, 206)
        self.assertEqual(response.content, b"PK\x03\x04")
        self.assertEqual(self.client.delete(f"/api/files/archive/{identifier}").status_code, 200)
        self.assertEqual(self.client.get(f"/api/files/archive/{identifier}").status_code, 404)
        self.assertEqual(list(self.archive_root.glob("archive-*")), [])

    def test_archive_of_empty_folder_is_valid(self):
        identifier = self.create()
        self.assertEqual(self.settled(identifier)["status"], "ready")
        response = self.client.get(f"/api/files/archive/{identifier}/download")
        with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
            self.assertEqual(archive.namelist(), [self.source.name + "/"])

    def test_protected_nested_file_fails_entire_archive_instead_of_skipping(self):
        (self.source / "safe.txt").write_text("allowed")
        private = self.source / "nested"
        private.mkdir()
        (private / ".orbit-token").write_text("never export")
        self.assert_failed_without_partial_zip(self.create(), "protected")

    def test_junction_or_symbolic_link_fails_entire_archive(self):
        outside = self.root / "outside.txt"
        outside.write_text("outside")
        (self.source / "link.txt").symlink_to(outside)
        self.assert_failed_without_partial_zip(self.create(), "Links")

    def test_hard_link_fails_entire_archive(self):
        outside = self.root / "outside.txt"
        outside.write_text("outside")
        files.os.link(outside, self.source / "alias.txt")
        self.assert_failed_without_partial_zip(self.create(), "hard links")

    def test_nested_private_history_store_is_not_exported(self):
        private = self.source / "AppData" / "Orbit"
        private.mkdir(parents=True)
        (private / "history.sqlite3").write_text("private")
        with patch.dict(files.os.environ, {"LOCALAPPDATA": str(private.parent)}):
            self.assert_failed_without_partial_zip(self.create(), "private")

    def test_source_size_entry_count_and_depth_limits(self):
        path = self.source / "file.bin"
        path.write_bytes(b"12345")
        with patch.object(files, "MAX_ARCHIVE_SOURCE_BYTES", 4):
            self.assert_failed_without_partial_zip(self.create(), "2 GB")
        self.client.delete("/api/files/archive/" + next(iter(self.manager.jobs)))
        with patch.object(files, "MAX_ARCHIVE_ENTRIES", 1):
            self.assert_failed_without_partial_zip(self.create(), "10,000")
        self.client.delete("/api/files/archive/" + next(iter(self.manager.jobs)))
        (self.source / "first" / "second").mkdir(parents=True)
        with patch.object(files, "MAX_ARCHIVE_DEPTH", 1):
            self.assert_failed_without_partial_zip(self.create(), "32-level")

    def test_archive_disk_size_cap_and_insufficient_free_space_are_cleaned(self):
        (self.source / "text.txt").write_text("x" * 512)
        with patch.object(files, "MAX_ARCHIVE_BYTES", 80):
            self.assert_failed_without_partial_zip(self.create(), "ZIP archive exceeds")
        self.client.delete("/api/files/archive/" + next(iter(self.manager.jobs)))
        with patch.object(files.shutil, "disk_usage", return_value=SimpleNamespace(free=0)):
            self.assert_failed_without_partial_zip(self.create(), "free space")

    def test_cancellation_while_building_cleans_temporary_and_preserves_source(self):
        (self.source / "text.txt").write_text("important")
        entered, release = threading.Event(), threading.Event()
        original_write = files._BoundedArchiveFile.write
        def slow_write(instance, data):
            entered.set()
            if not release.wait(3): raise TimeoutError("test release missing")
            return original_write(instance, data)
        with patch.object(files._BoundedArchiveFile, "write", slow_write):
            identifier = self.create()
            try:
                self.assertTrue(entered.wait(2))
                result = self.client.delete(f"/api/files/archive/{identifier}")
                self.assertEqual(result.status_code, 200)
            finally:
                release.set()
            deadline = time.monotonic() + 2
            while identifier in self.manager.jobs and time.monotonic() < deadline: time.sleep(0.005)
        self.assertNotIn(identifier, self.manager.jobs)
        self.assertEqual(list(self.archive_root.glob("archive-*")), [])
        self.assertEqual((self.source / "text.txt").read_text(), "important")

    def test_file_change_after_scan_fails_instead_of_returning_incomplete_folder(self):
        path = self.source / "text.txt"
        path.write_text("original")
        original_scan = files._archive_scan
        def changed(job):
            result = original_scan(job)
            path.write_text("modified larger payload")
            return result
        with patch.object(files, "_archive_scan", changed):
            self.assert_failed_without_partial_zip(self.create(), "changed")

    def test_unreadable_nested_folder_fails_without_a_partial_archive(self):
        restricted = self.source / "restricted"
        restricted.mkdir()
        original = files.os.scandir
        def denied(path):
            if Path(path) == restricted: raise PermissionError("simulated Windows permission denial")
            return original(path)
        with patch.object(files.os, "scandir", denied):
            self.assert_failed_without_partial_zip(self.create(), "denied access")

    def test_preparation_timeout_leaves_no_zip(self):
        with patch.object(files, "MAX_ARCHIVE_SECONDS", 0):
            self.assert_failed_without_partial_zip(self.create(), "two minutes")

    def test_cancelling_active_download_waits_for_reader_close_before_cleanup(self):
        (self.source / "text.txt").write_text("keep source")
        identifier = self.create()
        self.assertEqual(self.settled(identifier)["status"], "ready")
        response = self.manager.download(identifier, SimpleNamespace(headers={}))
        directory = self.manager.jobs[identifier].directory
        self.assertEqual(self.client.delete(f"/api/files/archive/{identifier}").status_code, 200)
        self.assertTrue(directory.exists())
        self.assertEqual(self.manager.jobs[identifier].readers, 1)
        response._file_stream.close()
        self.assertNotIn(identifier, self.manager.jobs)
        self.assertFalse(directory.exists())
        self.assertEqual((self.source / "text.txt").read_text(), "keep source")

    def test_abandoned_old_zip_cleanup_keeps_fresh_folders_and_links(self):
        stale = self.archive_root / "archive-old"
        fresh = self.archive_root / "archive-fresh"
        stale.mkdir(parents=True); fresh.mkdir()
        (stale / "download.zip").write_bytes(b"abandoned")
        old = time.time() - files.ARCHIVE_TTL_SECONDS - 1
        files.os.utime(stale, (old, old))
        outside = self.root / "outside"
        outside.mkdir(); (outside / "keep.txt").write_text("keep")
        (self.archive_root / "archive-link").symlink_to(outside, target_is_directory=True)
        self.manager._stale_directories()
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.exists())
        self.assertEqual((outside / "keep.txt").read_text(), "keep")

    def test_archive_slots_expiry_and_identifier_validation(self):
        first, second = self.create(), self.create()
        self.settled(first); self.settled(second)
        self.assertEqual(self.client.post("/api/files/archive", json={"path": str(self.source)}).status_code, 429)
        self.assertEqual(self.client.get("/api/files/archive/../../anything").status_code, 404)
        self.assertEqual(self.client.get("/api/files/archive/invalid").status_code, 422)
        with self.manager.lock: self.manager.jobs[first].created -= files.ARCHIVE_TTL_SECONDS + 1
        self.assertEqual(self.client.get(f"/api/files/archive/{first}").status_code, 404)
        third = self.create()
        self.assertEqual(self.settled(third)["status"], "ready")

    def test_download_start_failure_releases_reader_and_allows_delete(self):
        identifier = self.create()
        self.assertEqual(self.settled(identifier)["status"], "ready")
        response = self.manager.download(identifier, SimpleNamespace(headers={}))
        self.assertEqual(self.manager.jobs[identifier].readers, 1)
        async def receive(): return {"type": "http.disconnect"}
        async def send(_): raise OSError("disconnected")
        async def fail():
            with self.assertRaises(Exception): await response({"type": "http", "asgi": {"spec_version": "2.4"}}, receive, send)
        asyncio.run(fail())
        self.assertEqual(self.manager.jobs[identifier].readers, 0)
        self.client.delete(f"/api/files/archive/{identifier}")
        self.assertEqual(list(self.archive_root.glob("archive-*")), [])


class SunshineLoginProtectionTests(unittest.TestCase):
    """The saved Sunshine web UI login (.orbit-sunshine-login) is a credential like the tokens."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        app = FastAPI()
        app.include_router(files.create_files_router(authorized))
        self.client = TestClient(app, base_url="https://test", headers={"Authorization": "Bearer control"})
        self.addCleanup(self.client.close)

    def test_login_file_is_hidden_unreadable_and_cannot_be_created_or_renamed_to(self):
        login = self.root / ".orbit-sunshine-login"
        login.write_text('{"username": "admin", "password": "s3cret"}')
        (self.root / "notes.txt").write_text("fine")
        listing = self.client.get("/api/files/list", params={"path": str(self.root)}).json()
        self.assertEqual([entry["name"] for entry in listing["entries"]], ["notes.txt"])
        for variant in (".orbit-sunshine-login", ".ORBIT-SUNSHINE-LOGIN"):
            with self.subTest(variant=variant):
                response = self.client.get("/api/files/download", params={"path": str(self.root / variant)})
                self.assertEqual(response.status_code, 403)
                self.assertNotIn("s3cret", response.text)
                response = self.client.post("/api/files/upload", params={"directory": str(self.root), "name": variant}, content=b"x")
                self.assertEqual(response.status_code, 403)
                response = self.client.post("/api/files/rename", json={"path": str(self.root / "notes.txt"), "name": variant})
                self.assertEqual(response.status_code, 403)
        self.assertEqual(self.client.post("/api/files/trash", json={"path": str(login)}).status_code, 403)
        self.assertEqual(self.client.post("/api/files/archive", json={"path": str(login)}).status_code, 403)
        self.assertEqual(login.read_text(), '{"username": "admin", "password": "s3cret"}')

    def test_custom_login_path_from_the_environment_is_protected(self):
        login = self.root / "sunshine-web-login.json"
        login.write_text('{"username": "admin", "password": "s3cret"}')
        with patch.dict(files.os.environ, {"ORBIT_SUNSHINE_LOGIN_FILE": str(login)}):
            self.assertIn(login.absolute(), files._protected_paths())
            self.assertEqual(self.client.get("/api/files/download", params={"path": str(login)}).status_code, 403)
            listing = self.client.get("/api/files/list", params={"path": str(self.root)}).json()
            self.assertEqual(listing["entries"], [])

    def test_agent_folder_login_path_is_protected(self):
        self.assertIn(files.AGENT_DIRECTORY / ".orbit-sunshine-login", files._protected_paths())
        self.assertIn(".orbit-sunshine-login", files.SECRET_NAMES)

    def test_ignore_files_exclude_the_login(self):
        agent_folder = Path(files.__file__).resolve().parent
        for ignore in (agent_folder / ".gitignore", agent_folder.parent / ".gitignore"):
            with self.subTest(file=str(ignore)):
                self.assertIn(".orbit-sunshine-login", ignore.read_text(encoding="utf-8").split())

    def test_updater_never_replaces_the_login(self):
        import orbit_updater
        self.assertIn(".orbit-sunshine-login", orbit_updater.PRESERVED_FILENAMES)


class FakeTimer:
    created = []

    def __init__(self, delay, function):
        self.delay, self.function = delay, function
        self.cancelled = False
        self.daemon = False
        FakeTimer.created.append(self)

    def start(self):
        pass

    def cancel(self):
        self.cancelled = True


class UploadToastTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        (self.root / "Downloads").mkdir()
        self.now = [100.0]
        FakeTimer.created = []
        self.toaster = files.UploadToaster(timer_factory=FakeTimer, clock=lambda: self.now[0])
        for patcher in (patch.object(files, "UPLOAD_TOASTS", self.toaster),
                        patch.object(files.orbit_notify, "has_notifier", return_value=True)):
            patcher.start()
            self.addCleanup(patcher.stop)
        notify = patch.object(files.orbit_notify, "notify", return_value=True)
        self.notify = notify.start()
        self.addCleanup(notify.stop)
        app = FastAPI()
        app.include_router(files.create_files_router(authorized))
        self.client = TestClient(app, base_url="https://test", headers={"Authorization": "Bearer control"})
        self.addCleanup(self.client.close)

    def upload(self, name, content, folder="Downloads"):
        return self.client.post("/api/files/upload", params={"directory": str(self.root / folder), "name": name}, content=content)

    def test_sizes_read_like_windows_explorer(self):
        self.assertEqual([files.format_size(value) for value in (0, 1, 512, 1023, 1024, 1536, 2_516_582, 12 * 1024 ** 2,
                                                                  1024 ** 3 * 3 // 2, 5 * 1024 ** 4)],
                         ["0 bytes", "1 byte", "512 bytes", "1023 bytes", "1.0 KB", "1.5 KB", "2.4 MB", "12 MB", "1.5 GB", "5.0 TB"])

    def test_one_upload_gives_the_designed_toast_after_a_quiet_moment(self):
        response = self.upload("photo.jpg", b"x" * 2_516_582)
        self.assertEqual(response.status_code, 200)
        self.notify.assert_not_called()
        self.assertEqual(len(FakeTimer.created), 1)
        self.assertEqual(FakeTimer.created[0].delay, files.UPLOAD_TOAST_QUIET_SECONDS)
        self.assertTrue(FakeTimer.created[0].daemon)
        FakeTimer.created[0].function()
        self.notify.assert_called_once_with("File received", "Received photo.jpg (2.4 MB) in Downloads")
        self.assertFalse(self.toaster.flush())

    def test_a_batch_of_uploads_gives_one_toast(self):
        for index in range(20):
            self.now[0] += 0.2
            self.assertEqual(self.upload(f"IMG_{index:04}.HEIC", b"x" * 1024).status_code, 200)
        self.assertTrue(all(timer.cancelled for timer in FakeTimer.created[:-1]))
        FakeTimer.created[-1].function()
        self.notify.assert_called_once_with("Files received", "Received 20 files (20 KB) in Downloads")

    def test_toast_waits_at_most_the_maximum_delay_after_the_first_upload(self):
        self.upload("a.txt", b"a")
        self.now[0] += files.UPLOAD_TOAST_MAX_DELAY_SECONDS - 0.5
        self.upload("b.txt", b"b")
        self.assertAlmostEqual(FakeTimer.created[-1].delay, 0.5)
        self.now[0] += 5
        self.upload("c.txt", b"c")
        self.assertEqual(FakeTimer.created[-1].delay, 0.0)

    def test_uploads_to_different_folders_say_how_many_folders(self):
        (self.root / "Desktop").mkdir()
        self.upload("a.txt", b"a" * 10)
        self.upload("b.txt", b"b" * 10, folder="Desktop")
        self.toaster.flush()
        self.notify.assert_called_once_with("Files received", "Received 2 files (20 bytes) in 2 folders")

    def test_failed_uploads_do_not_toast(self):
        self.upload("taken.txt", b"first")
        self.toaster.flush()
        self.notify.reset_mock()
        FakeTimer.created = []
        self.assertEqual(self.upload("taken.txt", b"second").status_code, 409)
        self.assertEqual(self.upload(".orbit-token", b"x").status_code, 403)
        self.assertEqual(FakeTimer.created, [])
        self.assertFalse(self.toaster.flush())
        self.notify.assert_not_called()

    def test_nothing_is_collected_without_a_notifier(self):
        with patch.object(files.orbit_notify, "has_notifier", return_value=False):
            self.assertEqual(self.upload("quiet.txt", b"x").status_code, 200)
        self.assertEqual(FakeTimer.created, [])
        self.assertFalse(self.toaster.flush())

    def test_a_broken_toast_never_fails_the_upload(self):
        def broken_timer(delay, function):
            raise RuntimeError("cannot start thread")
        self.toaster._timer_factory = broken_timer
        response = self.upload("still-fine.txt", b"x")
        self.assertEqual(response.status_code, 200)
        self.assertEqual((self.root / "Downloads" / "still-fine.txt").read_bytes(), b"x")

    def test_real_timer_shows_the_toast(self):
        shown = threading.Event()
        self.notify.side_effect = lambda title, message: shown.set() or True
        toaster = files.UploadToaster(quiet=0.01, max_delay=1)
        toaster.received("song.mp3", 4_000_000, self.root / "Downloads")
        self.assertTrue(shown.wait(5))
        self.notify.assert_called_once_with("File received", "Received song.mp3 (3.8 MB) in Downloads")


if __name__ == "__main__":
    unittest.main()
