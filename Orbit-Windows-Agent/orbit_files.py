"""Authenticated HTTPS file access; runs with the Windows user's permissions.

No shell commands, permanent deletion, overwriting, or hidden credential exports.
File transfer is streamed and bounded rather than buffered in agent memory.
"""
import asyncio
import ctypes
import datetime as dt
import errno
import mimetypes
import ntpath
import os
from pathlib import Path
import re
import shutil
import threading
import time
import zipfile
import stat
import tempfile
import uuid

from fastapi import APIRouter, Depends, HTTPException, Path as PathParameter, Query, Request
from pydantic import BaseModel, Field
from starlette.responses import StreamingResponse

MAX_PREVIEW_BYTES = 64 * 1024 ** 2
MAX_UPLOAD_BYTES = 2 * 1024 ** 3
MAX_DOWNLOAD_BYTES = 16 * 1024 ** 3
MAX_DIRECTORY_ENTRIES = 100_000
MAX_ARCHIVE_SOURCE_BYTES = 2 * 1024 ** 3
MAX_ARCHIVE_BYTES = 2 * 1024 ** 3
MAX_ARCHIVE_ENTRIES = 10_000
MAX_ARCHIVE_DEPTH = 32
MAX_ARCHIVE_SECONDS = 120
MAX_ARCHIVE_JOBS = 2
ARCHIVE_TTL_SECONDS = 10 * 60
ARCHIVE_SWEEP_SECONDS = 30
CHUNK_BYTES = 256 * 1024
AGENT_DIRECTORY = Path(__file__).absolute().parent
SECRET_NAMES = frozenset({".orbit-token", ".orbit-widget-token", "server-key.pem", "server-cert.pem", ".orbit-tls-key.pem", ".env"})
RESERVED = re.compile(r"^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)", re.I)
PREVIEW_EXTENSIONS = frozenset({".png", ".jpg", ".jpeg", ".heic", ".gif", ".webp", ".pdf", ".txt", ".md", ".log", ".json", ".csv", ".xml", ".html", ".rtf", ".mp4", ".mov", ".mp3", ".m4a"})


class NameBody(BaseModel):
    parent: str = Field(max_length=32767)
    name: str = Field(min_length=1, max_length=255)


class RenameBody(BaseModel):
    path: str = Field(max_length=32767)
    name: str = Field(min_length=1, max_length=255)


class MoveBody(BaseModel):
    path: str = Field(max_length=32767)
    destinationDirectory: str = Field(max_length=32767)


class PathBody(BaseModel):
    path: str = Field(max_length=32767)


def _fail(status, message):
    raise HTTPException(status, message)


def require_secure(request: Request):
    if request.url.scheme != "https":
        _fail(426, "Files require the trusted HTTPS connection. Pair the secure companion in Orbit settings.")


def _within(path, parent):
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _protected_paths():
    from orbit_tls import data_directory
    from orbit_history import default_history_path
    result = [AGENT_DIRECTORY / ".orbit-token", AGENT_DIRECTORY / ".orbit-widget-token",
              data_directory().absolute()]
    history = default_history_path().expanduser().absolute()
    if not os.environ.get("ORBIT_HISTORY_FILE"):
        result.append(history.parent)
    result.extend(Path(str(history) + suffix) for suffix in ("", "-wal", "-shm", "-journal"))
    for name in ("ORBIT_TOKEN_FILE", "ORBIT_WIDGET_TOKEN_FILE", "ORBIT_TOKEN_PATH", "ORBIT_WIDGET_TOKEN_PATH"):
        if os.environ.get(name):
            result.append(Path(os.environ[name]).absolute())
    return result


def _name(name):
    if (not isinstance(name, str) or not name or name in {".", ".."} or name[-1:] in {".", " "}
            or any(ord(c) < 32 or c in '<>:"/\\|?*' for c in name)
            or RESERVED.match(name.split(".", 1)[0].rstrip(" "))):
        _fail(422, "Choose a valid Windows file name without slashes, reserved device names, or trailing spaces.")
    if name.casefold() in SECRET_NAMES or name.casefold().startswith(".orbit-upload-"):
        _fail(403, "Orbit credentials and internal transfer files are protected.")
    return name


def checked_path(value, *, directory=None, writing=False):
    if not isinstance(value, str) or not value or len(value) > 32767 or "\x00" in value:
        _fail(422, "An absolute file path is required.")
    if os.name == "nt":
        normalized = value.replace("/", "\\")
        drive, tail = ntpath.splitdrive(normalized)
        if (not re.fullmatch(r"[a-zA-Z]:", drive) or not tail.startswith("\\")
                or normalized.startswith("\\\\") or ":" in tail):
            _fail(422, "Use a local drive path such as C:\\Users. Device, network and alternate data stream paths are unavailable.")
        parts = [p for p in tail.split("\\") if p]
    else:
        parts = list(Path(value).parts[1:])
    if any(p in {".", ".."} for p in parts):
        _fail(422, "Relative path components are unavailable.")
    for part in parts:
        _name(part)
    path = Path(value)
    if not path.is_absolute():
        _fail(422, "An absolute file path is required.")
    path = path.absolute()
    for protected in _protected_paths():
        # WindowsPath comparisons are case insensitive on Windows.
        if _within(path, protected.absolute()):
            _fail(403, "Orbit's private settings and credentials are protected.")
    if writing and _within(path, AGENT_DIRECTORY):
        _fail(403, "Changes to the running companion's folder are unavailable.")
    try:
        for ancestor in [*reversed(path.parents), path]:
            try:
                info = ancestor.lstat()
            except FileNotFoundError:
                if ancestor == path:
                    break
                raise
            reparse = getattr(info, "st_file_attributes", 0) & 0x400
            tag = getattr(info, "st_reparse_tag", 0)
            # Cloud placeholders (OneDrive) retain their own identity and are
            # safe to hydrate. Name-surrogate tags redirect to another entity.
            if stat.S_ISLNK(info.st_mode) or (reparse and (not tag or tag & 0x20000000)):
                _fail(403, "Links and Windows junctions are unavailable. Open the original folder directly.")
        if os.name == "nt":
            canonical = path.resolve(strict=False)
            for part in canonical.parts[1:]:
                _name(part)
            if any(_within(canonical, protected.absolute().resolve(strict=False)) for protected in _protected_paths()):
                _fail(403, "Orbit's private settings and credentials are protected.")
            if writing and _within(canonical, AGENT_DIRECTORY.resolve(strict=False)):
                _fail(403, "Changes to the running companion's folder are unavailable.")
            path = canonical
        if path.exists():
            info = path.stat()
            if not stat.S_ISREG(info.st_mode) and not stat.S_ISDIR(info.st_mode):
                _fail(403, "Only regular files and folders are available.")
            if stat.S_ISREG(info.st_mode) and info.st_nlink > 1:
                _fail(403, "Files with multiple hard links are protected.")
            if directory is True and not path.is_dir():
                _fail(422, "Select a folder.")
            if directory is False and not path.is_file():
                _fail(422, "Select a regular file.")
    except HTTPException:
        raise
    except OSError as exc:
        _os_error(exc)
    return path


def _os_error(exc):
    if isinstance(exc, FileNotFoundError):
        _fail(404, "The file or folder no longer exists. Refresh this folder.")
    if isinstance(exc, PermissionError):
        _fail(403, "Windows denied access. Orbit uses the account running the companion.")
    if isinstance(exc, FileExistsError):
        _fail(409, "A file or folder with that name already exists. Choose another name.")
    if getattr(exc, "errno", None) == errno.EXDEV:
        _fail(409, "Moving between drives is unavailable. Download and upload the file to the other drive.")
    if getattr(exc, "errno", None) == errno.ENOSPC:
        _fail(507, "There is not enough space on this drive.")
    _fail(409, "Windows could not complete this operation. The file may be open in another application.")


def _exists(path):
    if not path.exists():
        _fail(404, "The file or folder no longer exists.")
    return path


def _entry(path):
    info = path.stat()
    folder = stat.S_ISDIR(info.st_mode)
    return {"name": path.name, "path": str(path), "isDirectory": folder,
            "sizeBytes": None if folder else info.st_size,
            "modifiedAt": dt.datetime.fromtimestamp(info.st_mtime, dt.timezone.utc).isoformat(),
            "canPreview": not folder and info.st_size <= MAX_PREVIEW_BYTES and path.suffix.casefold() in PREVIEW_EXTENSIONS}


def list_directory(path, search="", sort="name", offset=0, limit=200):
    folder = _exists(checked_path(path, directory=True))
    rows = []
    truncated = False
    try:
        with os.scandir(folder) as iterator:
            for index, item in enumerate(iterator):
                if index >= MAX_DIRECTORY_ENTRIES:
                    truncated = True
                    break
                if search and search.casefold() not in item.name.casefold():
                    continue
                try:
                    candidate = checked_path(item.path)
                    rows.append(_entry(candidate))
                except (OSError, HTTPException):
                    continue
    except OSError as exc:
        _os_error(exc)
    key = {"name": lambda r: (r["name"].casefold(), r["name"]),
           "size": lambda r: (-(r["sizeBytes"] or 0), r["name"].casefold()),
           "modified": lambda r: (str(r["modifiedAt"]), r["name"].casefold())}[sort]
    rows.sort(key=key, reverse=sort == "modified")
    rows.sort(key=lambda r: not r["isDirectory"])
    parent = None if folder.parent == folder else str(folder.parent)
    return {"path": str(folder), "parentPath": parent, "entries": rows[offset:offset + limit],
            "total": len(rows), "offset": offset, "limit": limit, "truncated": truncated}


def _known_folder(identifier):
    class GUID(ctypes.Structure):
        _fields_ = [("data", ctypes.c_ubyte * 16)]
    guid = GUID((ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID(identifier).bytes_le))
    pointer = ctypes.c_wchar_p()
    shell = ctypes.windll.shell32
    shell.SHGetKnownFolderPath.argtypes = [ctypes.POINTER(GUID), ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_wchar_p)]
    shell.SHGetKnownFolderPath.restype = ctypes.c_long
    ole = ctypes.windll.ole32
    ole.CoTaskMemFree.argtypes = [ctypes.c_void_p]
    ole.CoTaskMemFree.restype = None
    if shell.SHGetKnownFolderPath(ctypes.byref(guid), 0, None, ctypes.byref(pointer)) != 0:
        return None
    try:
        return pointer.value
    finally:
        ole.CoTaskMemFree(ctypes.cast(pointer, ctypes.c_void_p))


def file_roots():
    roots, shortcuts = [], []
    if os.name != "nt":
        return {"roots": [{"name": "Local files", "path": str(Path.home()), "kind": "drive"}], "shortcuts": []}
    kernel = ctypes.windll.kernel32
    kernel.GetLogicalDrives.argtypes = []
    kernel.GetLogicalDrives.restype = ctypes.c_uint32
    kernel.GetDriveTypeW.argtypes = [ctypes.c_wchar_p]
    kernel.GetDriveTypeW.restype = ctypes.c_uint32
    mask = kernel.GetLogicalDrives()
    for index in range(26):
        if mask & (1 << index):
            path = f"{chr(65 + index)}:\\"
            drive_type = kernel.GetDriveTypeW(path)
            if drive_type in (2, 3, 5, 6):
                roots.append({"name": f"{chr(65 + index)}:", "path": path,
                              "kind": "external" if drive_type == 2 else "drive"})
    folders = [("Desktop", "b4bfcc3a-db2c-424c-b029-7fe99a87c641"),
               ("Downloads", "374de290-123f-4565-9164-39c4925e467b"),
               ("Documents", "fdd39ad0-238f-46af-adb4-6c85480369c7"),
               ("Pictures", "33e28130-4e1e-4676-835a-98395c3bc3bb"),
               ("Videos", "18989b1d-99b5-455b-841c-ab7c74e4ddfc"),
               ("Music", "4bd8d571-6d19-48d3-be97-422220080e43")]
    for name, identifier in folders:
        try:
            path = _known_folder(identifier)
            if path and checked_path(path, directory=True).is_dir():
                shortcuts.append({"name": name, "path": path, "kind": "shortcut"})
        except (OSError, HTTPException):
            pass
    return {"roots": roots, "shortcuts": shortcuts}


def _range(value, size):
    if not value:
        return 0, size - 1, False
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
    if not match or not any(match.groups()) or size <= 0:
        _fail(416, "The requested byte range is unavailable.")
    first, last = match.groups()
    if not first:
        start, end = max(0, size - int(last)), size - 1
        if int(last) == 0:
            _fail(416, "The requested byte range is unavailable.")
    else:
        start, end = int(first), min(int(last), size - 1) if last else size - 1
    if start > end or start >= size:
        _fail(416, "The requested byte range is unavailable.")
    return start, end, True


async def _file_io(function, *arguments):
    """Cancellation waits for OS I/O before closing/unlinking the file.

    Cancelling asyncio.to_thread cannot cancel its thread. In particular on
    Windows, unlinking a still-open upload can fail and leave partial data.
    """
    operation = asyncio.create_task(asyncio.to_thread(function, *arguments))
    try:
        return await asyncio.shield(operation)
    except asyncio.CancelledError:
        while not operation.done():
            try:
                await asyncio.shield(operation)
            except asyncio.CancelledError:
                continue
            except BaseException:
                break
        # Retrieve a worker exception without replacing the original cancel.
        try:
            operation.result()
        except BaseException:
            pass
        raise


class _ClosingStreamingResponse(StreamingResponse):
    def __init__(self, stream, content, **kwargs):
        super().__init__(content, **kwargs)
        self._file_stream = stream

    async def __call__(self, scope, receive, send):
        try:
            await super().__call__(scope, receive, send)
        finally:
            # This also runs if response-start fails before the body iterator
            # starts (its own finally block would never have been entered).
            self._file_stream.close()


def download_response(path, request):
    target = _exists(checked_path(path, directory=False))
    stream = None
    try:
        descriptor = os.open(target, os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0))
        stream = os.fdopen(descriptor, "rb")
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink > 1:
            _fail(403, "This file is protected.")
        if info.st_size > MAX_DOWNLOAD_BYTES:
            _fail(413, "This file exceeds the 16 GB transfer limit.")
        start, end, partial = _range(request.headers.get("range"), info.st_size)
        stream.seek(start)
    except HTTPException:
        if stream:
            stream.close()
        raise
    except OSError as exc:
        if stream:
            stream.close()
        _os_error(exc)

    async def content():
        remaining = max(0, end - start + 1)
        try:
            while remaining:
                data = await _file_io(stream.read, min(CHUNK_BYTES, remaining))
                if not data:
                    break
                remaining -= len(data)
                yield data
        finally:
            stream.close()
    from urllib.parse import quote
    headers = {"Content-Length": str(max(0, end - start + 1)), "Accept-Ranges": "bytes",
               "Content-Disposition": f"attachment; filename*=UTF-8''{quote(target.name)}",
               "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"}
    if partial:
        headers["Content-Range"] = f"bytes {start}-{end}/{info.st_size}"
    return _ClosingStreamingResponse(stream, content(), status_code=206 if partial else 200,
                             media_type=mimetypes.guess_type(target.name)[0] or "application/octet-stream", headers=headers)


async def receive_upload(request, directory, name):
    parent = _exists(checked_path(directory, directory=True, writing=True))
    destination = checked_path(str(parent / _name(name)), writing=True)
    if destination.exists():
        _fail(409, "A file with that name already exists. Choose another name.")
    declared = request.headers.get("content-length")
    if declared is not None:
        try:
            declared = int(declared)
        except ValueError:
            _fail(422, "Invalid transfer length.")
        if declared < 0 or declared > MAX_UPLOAD_BYTES:
            _fail(413, "The upload limit is 2 GB per file.")
    temporary = None
    total = 0
    try:
        fd, temporary = tempfile.mkstemp(prefix=".orbit-upload-", dir=parent)
        with os.fdopen(fd, "wb") as stream:
            async for chunk in request.stream():
                total += len(chunk)
                if total > MAX_UPLOAD_BYTES:
                    _fail(413, "The upload limit is 2 GB per file.")
                await _file_io(stream.write, chunk)
            if declared is not None and total != declared:
                _fail(400, "The upload was incomplete. Retry the transfer.")
            await _file_io(stream.flush)
            await _file_io(os.fsync, stream.fileno())
        checked_path(str(parent), directory=True, writing=True)
        checked_path(str(destination), writing=True)
        # link is atomic and fails if another process created the destination.
        # Unlike replace(), it can never overwrite an existing file.
        os.link(temporary, destination)
        return {"path": str(destination), "name": destination.name, "sizeBytes": total}
    except HTTPException:
        raise
    except OSError as exc:
        _os_error(exc)
    finally:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass


class _ArchiveCancelled(Exception):
    pass


def _archive_directory():
    from orbit_tls import data_directory
    return data_directory() / "folder-transfers"


class _ArchiveJob:
    def __init__(self, path):
        self.id = uuid.uuid4().hex
        self.source = path
        self.name = (path.name or "PC files") + ".zip"
        self.status = "scanning"
        self.progress = 0.0
        self.total_bytes = 0
        self.total_entries = 0
        self.archive_bytes = None
        self.error = None
        self.created = time.monotonic()
        self.cancelled = threading.Event()
        self.worker_finished = False
        self.readers = 0
        self.directory = None
        self.archive = None

    def check(self):
        if self.cancelled.is_set():
            raise _ArchiveCancelled()
        if time.monotonic() - self.created > MAX_ARCHIVE_SECONDS:
            _fail(408, "Preparing this folder took more than two minutes. Choose a smaller folder.")

    def snapshot(self):
        return {"id": self.id, "name": self.name, "status": self.status,
                "progress": round(self.progress, 4), "totalBytes": self.total_bytes,
                "totalEntries": self.total_entries, "archiveBytes": self.archive_bytes,
                "error": self.error}


class _BoundedArchiveFile:
    def __init__(self, stream, job):
        self.stream, self.job = stream, job

    def write(self, data):
        self.job.check()
        if self.stream.tell() + len(data) > MAX_ARCHIVE_BYTES:
            _fail(413, "The ZIP archive exceeds the 2 GB limit. Choose a smaller folder.")
        return self.stream.write(data)

    def __getattr__(self, name):
        return getattr(self.stream, name)


def _archive_identity(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def _archive_scan(job):
    """Reject the complete operation if any entry cannot be safely included."""
    entries = []
    total = 0
    seen_names = set()
    root_name = job.source.name or "PC files"

    def visit(path, relative, depth):
        nonlocal total
        job.check()
        if depth > MAX_ARCHIVE_DEPTH:
            _fail(413, "This folder exceeds the 32-level archive depth limit. Choose a subfolder.")
        candidate = _exists(checked_path(str(path)))
        info = candidate.stat()
        folder = stat.S_ISDIR(info.st_mode)
        archive_name = "/".join((root_name, *relative)) + ("/" if folder else "")
        # Windows extraction must not collapse two different archive entries.
        key = archive_name.rstrip("/").casefold()
        if key in seen_names:
            _fail(409, "This folder contains names that conflict on Windows. Rename the conflicting items first.")
        seen_names.add(key)
        entries.append((candidate, archive_name, info, folder))
        if len(entries) > MAX_ARCHIVE_ENTRIES:
            _fail(413, "This folder exceeds 10,000 archive entries. Choose a smaller folder.")
        if not folder:
            total += info.st_size
            if total > MAX_ARCHIVE_SOURCE_BYTES:
                _fail(413, "This folder contains more than 2 GB of files. Choose a smaller folder.")
            return
        with os.scandir(candidate) as iterator:
            children = []
            for child in iterator:
                job.check()
                children.append(child.name)
                if len(children) + len(entries) > MAX_ARCHIVE_ENTRIES:
                    _fail(413, "This folder exceeds 10,000 archive entries. Choose a smaller folder.")
        for name in sorted(children, key=lambda value: (value.casefold(), value)):
            visit(candidate / name, (*relative, name), depth + 1)

    visit(job.source, (), 0)
    return entries, total


def _archive_zip_info(name, info, folder):
    date = dt.datetime.fromtimestamp(info.st_mtime)
    year = min(2107, max(1980, date.year))
    # A leap day remains valid when clamping an out-of-range year.
    day = min(date.day, 28) if date.month == 2 and date.day == 29 and year % 4 else date.day
    value = zipfile.ZipInfo(name, (year, date.month, day, date.hour, date.minute, date.second))
    value.compress_type = zipfile.ZIP_STORED if folder else zipfile.ZIP_DEFLATED
    value._compresslevel = 1
    value.file_size = 0 if folder else info.st_size
    value.external_attr = ((stat.S_IFDIR | 0o755) << 16 | 0x10) if folder else ((stat.S_IFREG | 0o644) << 16)
    return value


class _ArchiveReader:
    def __init__(self, stream, manager, job):
        self.stream, self.manager, self.job = stream, manager, job
        self.closed = False

    def read(self, size):
        if self.job.cancelled.is_set():
            raise _ArchiveCancelled()
        return self.stream.read(size)

    def seek(self, offset):
        return self.stream.seek(offset)

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                self.stream.close()
            finally:
                self.manager.release(self.job)


class ArchiveManager:
    """At most two bounded local ZIPs; no paths or credentials in job metadata."""
    def __init__(self):
        self.jobs = {}
        self.lock = threading.RLock()
        self.janitor = None

    def _remove_locked(self, job):
        if not job.worker_finished or job.readers:
            return False
        try:
            if job.directory:
                shutil.rmtree(job.directory)
        except FileNotFoundError:
            pass
        except OSError:
            # AV or another Windows handle may temporarily delay deletion.
            # Keep tracking the directory so the janitor retries it.
            return False
        self.jobs.pop(job.id, None)
        return True

    def _sweep_locked(self):
        now = time.monotonic()
        for job in list(self.jobs.values()):
            if now - job.created >= ARCHIVE_TTL_SECONDS:
                job.cancelled.set()
                job.status = "cancelling"
            if job.cancelled.is_set():
                self._remove_locked(job)

    def _stale_directories(self):
        directory = _archive_directory()
        try:
            with os.scandir(directory) as iterator:
                for entry in iterator:
                    if not entry.name.startswith("archive-") or entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                        continue
                    try:
                        info = entry.stat(follow_symlinks=False)
                        if getattr(info, "st_file_attributes", 0) & 0x400:
                            continue
                        if time.time() - info.st_mtime >= ARCHIVE_TTL_SECONDS:
                            with self.lock:
                                active = any(job.directory == Path(entry.path) for job in self.jobs.values())
                            if not active:
                                shutil.rmtree(entry.path)
                    except OSError:
                        pass
        except OSError:
            pass

    def _cleaner(self):
        while True:
            self._stale_directories()
            time.sleep(ARCHIVE_SWEEP_SECONDS)
            with self.lock:
                self._sweep_locked()
                if not self.jobs:
                    self.janitor = None
                    return

    def create(self, value):
        path = _exists(checked_path(value, directory=True))
        with self.lock:
            self._sweep_locked()
            if len(self.jobs) >= MAX_ARCHIVE_JOBS:
                _fail(429, "Two folder transfers are already active. Finish or cancel one before starting another.")
            job = _ArchiveJob(path)
            self.jobs[job.id] = job
            if self.janitor is None:
                self.janitor = threading.Thread(target=self._cleaner, name="Orbit archive cleanup", daemon=True)
                self.janitor.start()
            worker = threading.Thread(target=self._build, args=(job,), name="Orbit folder archive", daemon=True)
            worker.start()
            return job.snapshot()

    def _build(self, job):
        try:
            entries, total = _archive_scan(job)
            with self.lock:
                job.check()
                job.total_entries, job.total_bytes, job.status = len(entries), total, "preparing"
            directory = _archive_directory()
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            # Include metadata overhead and leave a small free-space reserve.
            needed = total + len(entries) * 1024 + 16 * 1024 ** 2
            if shutil.disk_usage(directory).free < needed:
                _fail(507, "The PC needs more free space to prepare this folder. Choose a smaller folder or free disk space.")
            job.directory = Path(tempfile.mkdtemp(prefix="archive-", dir=directory))
            job.archive = job.directory / "download.zip"
            processed = 0
            with job.archive.open("w+b") as destination:
                bounded = _BoundedArchiveFile(destination, job)
                with zipfile.ZipFile(bounded, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=1, allowZip64=True) as archive:
                    for index, (path, name, original, folder) in enumerate(entries):
                        job.check()
                        path = _exists(checked_path(str(path), directory=folder))
                        current = path.stat()
                        if _archive_identity(current) != _archive_identity(original):
                            _fail(409, "A file or folder changed while preparing the ZIP. Wait for PC changes to finish and try again.")
                        info = _archive_zip_info(name, original, folder)
                        if folder:
                            archive.writestr(info, b"")
                        else:
                            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0))
                            with os.fdopen(descriptor, "rb") as source:
                                opened = os.fstat(descriptor)
                                if not stat.S_ISREG(opened.st_mode) or opened.st_nlink > 1:
                                    _fail(403, "This folder contains a protected file or link and cannot be archived.")
                                if _archive_identity(opened) != _archive_identity(original):
                                    _fail(409, "A file changed while preparing the ZIP. Wait for PC changes to finish and try again.")
                                remaining = original.st_size
                                with archive.open(info, "w", force_zip64=original.st_size >= zipfile.ZIP64_LIMIT) as entry:
                                    while remaining:
                                        job.check()
                                        data = source.read(min(CHUNK_BYTES, remaining))
                                        if not data:
                                            _fail(409, "A file changed while preparing the ZIP. Try again when it is no longer being modified.")
                                        entry.write(data)
                                        remaining -= len(data)
                                        processed += len(data)
                                        with self.lock:
                                            job.progress = min(0.99, processed / total) if total else index / len(entries)
                                if source.read(1) or _archive_identity(os.fstat(descriptor)) != _archive_identity(original):
                                    _fail(409, "A file changed while preparing the ZIP. Wait for PC changes to finish and try again.")
                        with self.lock:
                            job.progress = min(0.99, processed / total) if total else (index + 1) / len(entries)
                    # A directory gaining/losing an entry must not produce a
                    # silently incomplete folder archive.
                    for path, _, original, folder in entries:
                        job.check()
                        if folder and _archive_identity(_exists(checked_path(str(path), directory=True)).stat()) != _archive_identity(original):
                            _fail(409, "A folder changed while preparing the ZIP. Wait for PC changes to finish and try again.")
            with self.lock:
                job.check()
                job.archive_bytes = job.archive.stat().st_size
                job.progress, job.status, job.worker_finished = 1.0, "ready", True
        except _ArchiveCancelled:
            with self.lock:
                job.status = "cancelling"
        except HTTPException as exc:
            with self.lock:
                job.status, job.error = "failed", str(exc.detail)[:300]
        except OSError as exc:
            try:
                _os_error(exc)
            except HTTPException as failure:
                with self.lock:
                    job.status, job.error = "failed", str(failure.detail)[:300]
        except Exception:
            with self.lock:
                job.status, job.error = "failed", "The folder ZIP could not be prepared. Choose a smaller folder and try again."
        finally:
            with self.lock:
                job.worker_finished = True
                if job.status != "ready":
                    try:
                        if job.directory:
                            shutil.rmtree(job.directory)
                        job.directory = None
                        job.archive = None
                    except OSError:
                        job.cancelled.set()
                if job.cancelled.is_set():
                    self._remove_locked(job)

    def _get_locked(self, identifier):
        self._sweep_locked()
        job = self.jobs.get(identifier)
        if job is None:
            _fail(404, "This folder transfer has expired or was cancelled. Start the download again.")
        return job

    def status(self, identifier):
        with self.lock:
            return self._get_locked(identifier).snapshot()

    def cancel(self, identifier):
        with self.lock:
            job = self._get_locked(identifier)
            job.cancelled.set()
            job.status = "cancelling"
            self._remove_locked(job)
            return {"ok": True}

    def release(self, job):
        with self.lock:
            job.readers = max(0, job.readers - 1)
            if job.cancelled.is_set():
                self._remove_locked(job)

    def download(self, identifier, request):
        from urllib.parse import quote
        with self.lock:
            job = self._get_locked(identifier)
            if job.status != "ready" or not job.archive or not job.worker_finished:
                _fail(409, "The ZIP is not ready yet. Keep this folder transfer open.")
            stream = None
            try:
                size = job.archive.stat().st_size
                start, end, partial = _range(request.headers.get("range"), size)
                stream = job.archive.open("rb")
                stream.seek(start)
                job.readers += 1
                reader = _ArchiveReader(stream, self, job)
            except HTTPException:
                if stream:
                    stream.close()
                raise
            except OSError as exc:
                if stream:
                    stream.close()
                _os_error(exc)
        async def content():
            remaining = max(0, end - start + 1)
            try:
                while remaining:
                    data = await _file_io(reader.read, min(CHUNK_BYTES, remaining))
                    if not data:
                        break
                    remaining -= len(data)
                    yield data
            finally:
                reader.close()
        headers = {"Content-Length": str(max(0, end - start + 1)), "Accept-Ranges": "bytes",
                   "Content-Disposition": f"attachment; filename*=UTF-8''{quote(job.name)}",
                   "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"}
        if partial:
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        return _ClosingStreamingResponse(reader, content(), status_code=206 if partial else 200,
                                         media_type="application/zip", headers=headers)


def _mutation_target(path):
    if _within(AGENT_DIRECTORY, path) or any(_within(protected.absolute(), path) for protected in _protected_paths()):
        _fail(403, "Folders containing the running companion or its private settings are protected.")


def rename_or_move(source, destination):
    source = _exists(checked_path(source, writing=True))
    _mutation_target(source)
    destination = checked_path(destination, writing=True)
    _exists(checked_path(str(destination.parent), directory=True, writing=True))
    if source.parent == source:
        _fail(403, "Drive roots cannot be moved or renamed.")
    if destination.exists() or destination == source:
        _fail(409, "The destination already exists. Choose another name.")
    if _within(destination, source):
        _fail(422, "A folder cannot be moved inside itself.")
    try:
        # Windows rename never overwrites; do not use POSIX rename's replace
        # behavior for the portable tests, or os.replace anywhere.
        if os.name == "nt":
            os.rename(source, destination)
        elif source.is_file():
            os.link(source, destination)
            os.unlink(source)
        else:
            # Portable test helper only; production agent runs on Windows.
            if destination.exists():
                _fail(409, "The destination already exists.")
            os.rename(source, destination)
    except OSError as exc:
        _os_error(exc)
    return {"ok": True, "path": str(destination)}


def recycle_path(value):
    target = _exists(checked_path(value, writing=True))
    _mutation_target(target)
    if target.parent == target:
        _fail(403, "Drive roots cannot be recycled.")
    if os.name != "nt":
        _fail(503, "Recycle Bin is available only on Windows. No file was deleted.")
    # IFileOperation, not legacy SHFileOperation: RECYCLEONDELETE requests a
    # recycle operation explicitly. There is no permanent-delete fallback.
    class GUID(ctypes.Structure):
        _fields_ = [("bytes", ctypes.c_ubyte * 16)]
        def __init__(self, value):
            super().__init__((ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID(value).bytes_le))
    ole = ctypes.OleDLL("ole32")
    shell = ctypes.OleDLL("shell32")
    ole.CoInitializeEx.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    ole.CoInitializeEx.restype = ctypes.c_long
    ole.CoUninitialize.argtypes = []
    ole.CoUninitialize.restype = None
    ole.CoCreateInstance.argtypes = [ctypes.POINTER(GUID), ctypes.c_void_p, ctypes.c_uint32,
                                    ctypes.POINTER(GUID), ctypes.POINTER(ctypes.c_void_p)]
    ole.CoCreateInstance.restype = ctypes.c_long
    shell.SHCreateItemFromParsingName.argtypes = [ctypes.c_wchar_p, ctypes.c_void_p,
                                                 ctypes.POINTER(GUID), ctypes.POINTER(ctypes.c_void_p)]
    shell.SHCreateItemFromParsingName.restype = ctypes.c_long
    initialized = False
    operation, item = ctypes.c_void_p(), ctypes.c_void_p()
    def call(pointer, index, arguments, *values):
        table = ctypes.cast(pointer, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
        method = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, *arguments)(table[index])
        result = method(pointer, *values)
        if result < 0:
            raise OSError("Windows could not recycle this item.")
        return result
    try:
        result = ole.CoInitializeEx(None, 2)
        initialized = result in (0, 1)
        if result < 0:
            raise OSError("Windows could not initialize the Recycle Bin operation.")
        clsid = GUID("3ad05575-8857-4850-9277-11b85bdb8e09")
        iid = GUID("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8")
        result = ole.CoCreateInstance(ctypes.byref(clsid), None, 1, ctypes.byref(iid), ctypes.byref(operation))
        if result < 0 or not operation.value:
            raise OSError("Windows could not create the Recycle Bin operation.")
        item_iid = GUID("43826d1e-e718-42ee-bc55-a1e261c37bfe")
        result = shell.SHCreateItemFromParsingName(str(target), None, ctypes.byref(item_iid), ctypes.byref(item))
        if result < 0 or not item.value:
            raise OSError("Windows could not resolve this item.")
        # Recycle only, stop on errors, no elevation or destructive prompts.
        call(operation, 5, [ctypes.c_uint32], 0x00080000 | 0x00100000 | 0x10 | 0x400 | 0x4)
        call(operation, 18, [ctypes.c_void_p, ctypes.c_void_p], item, None)
        call(operation, 21, [])
        aborted = ctypes.c_int()
        call(operation, 22, [ctypes.POINTER(ctypes.c_int)], ctypes.byref(aborted))
        if aborted.value:
            _fail(409, "Windows cancelled the recycle operation. No permanent deletion was requested.")
        return {"ok": True, "path": str(target)}
    except HTTPException:
        raise
    except (OSError, AttributeError):
        _fail(409, "Windows could not move this item to Recycle Bin. Permanent deletion is never used.")
    finally:
        for pointer in (item, operation):
            if pointer.value:
                try:
                    call(pointer, 2, [])
                except OSError:
                    pass
        if initialized:
            ole.CoUninitialize()


def create_files_router(verify_control, archive_manager=None):
    router = APIRouter(prefix="/api/files", dependencies=[Depends(verify_control), Depends(require_secure)])
    archives = archive_manager or ArchiveManager()

    @router.post("/archive", status_code=202)
    def prepare_archive(body: PathBody):
        return archives.create(body.path)

    @router.get("/archive/{identifier}")
    def archive_status(identifier: str = PathParameter(pattern=r"^[0-9a-f]{32}$")):
        return archives.status(identifier)

    @router.get("/archive/{identifier}/download")
    def archive_download(request: Request, identifier: str = PathParameter(pattern=r"^[0-9a-f]{32}$")):
        return archives.download(identifier, request)

    @router.delete("/archive/{identifier}")
    def archive_cancel(identifier: str = PathParameter(pattern=r"^[0-9a-f]{32}$")):
        return archives.cancel(identifier)

    @router.get("/roots")
    def roots():
        return file_roots()

    @router.get("/list")
    def listing(path: str = Query(max_length=32767), search: str = Query(default="", max_length=255),
                sort: str = Query(default="name", pattern="^(name|size|modified)$"),
                offset: int = Query(default=0, ge=0), limit: int = Query(default=200, ge=1, le=500)):
        return list_directory(path, search, sort, offset, limit)

    @router.get("/download")
    def download(request: Request, path: str = Query(max_length=32767)):
        return download_response(path, request)

    @router.post("/upload")
    async def upload(request: Request, directory: str = Query(max_length=32767), name: str = Query(max_length=255)):
        return await receive_upload(request, directory, name)

    @router.post("/mkdir")
    def mkdir(body: NameBody):
        parent = _exists(checked_path(body.parent, directory=True, writing=True))
        target = checked_path(str(parent / _name(body.name)), writing=True)
        try:
            target.mkdir()
        except OSError as exc:
            _os_error(exc)
        return {"ok": True, "path": str(target)}

    @router.post("/rename")
    def rename(body: RenameBody):
        source = _exists(checked_path(body.path, writing=True))
        return rename_or_move(str(source), str(source.parent / _name(body.name)))

    @router.post("/move")
    def move(body: MoveBody):
        source = _exists(checked_path(body.path, writing=True))
        folder = _exists(checked_path(body.destinationDirectory, directory=True, writing=True))
        return rename_or_move(str(source), str(folder / source.name))

    @router.post("/trash")
    def trash(body: PathBody):
        return recycle_path(body.path)

    return router
