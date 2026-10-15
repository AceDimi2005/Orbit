import asyncio
import ctypes
from types import SimpleNamespace
from pathlib import Path
import tempfile
import threading
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
                  ("POST", "/move", {}), ("POST", "/trash", {})]
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


if __name__ == "__main__":
    unittest.main()
