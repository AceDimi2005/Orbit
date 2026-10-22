"""Application icons for Orbit's audio mixer and Task Manager.

Listings never include executable paths. Each row carries an opaque icon ID
(an HMAC of the file path under a key that exists only in this agent process),
and GET /api/icons turns IDs this agent listed into small PNG images.

Where an icon comes from, in order:
1. The icon Windows shows for the file (SHDefExtractIconW), or the icon an
   audio session names itself ("path,index", such as System sounds).
2. For packaged (MSIX/UWP) apps without an icon resource: the logo files their
   AppxManifest.xml declares.
Files with neither have no icon; the apps keep their own symbol for them.
"""
from collections import OrderedDict
import base64
import ctypes
from ctypes import wintypes
import hashlib
import hmac
import ntpath
import os
import re
import secrets
import struct
import threading
from types import SimpleNamespace
import zlib
from xml.etree import ElementTree

ICON_PIXELS = 128
MAX_IDS_PER_REQUEST = 48
MAX_SOURCES = 4096
MAX_CACHE_BYTES = 16 * 1024 * 1024
MAX_ICON_BYTES = 512 * 1024
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
PACKAGE_SEARCH_DEPTH = 5
ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_MISSING = object()
_NO_ICON_COST = 64
# AND-mask pixels are black (0) where the icon is opaque and white where it is not.
_MASK_TO_ALPHA = bytes(255 if value < 128 else 0 for value in range(256))


def encode_png(width, height, rgba):
    """Minimal 8-bit RGBA PNG writer; enough for icons, no imaging library needed."""
    if (not isinstance(width, int) or not isinstance(height, int) or isinstance(width, bool)
            or isinstance(height, bool) or not 0 < width <= 4096 or not 0 < height <= 4096):
        raise ValueError("Icon dimensions must be between 1 and 4096 pixels.")
    data = bytes(rgba)
    stride = width * 4
    if len(data) != stride * height:
        raise ValueError("Icon pixel data does not match its dimensions.")
    # Filter type 0 (None) before every row.
    raw = b"".join(b"\x00" + data[row * stride:(row + 1) * stride] for row in range(height))

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return PNG_SIGNATURE + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")


def bgra_to_rgba(color, mask=None):
    """GDI rows are BGRA. Icons without an alpha channel take it from their AND mask."""
    color = bytes(color)
    if len(color) % 4:
        raise ValueError("Pixel data must hold whole BGRA pixels.")
    rgba = bytearray(color)
    rgba[0::4] = color[2::4]
    rgba[2::4] = color[0::4]
    if not any(color[3::4]):
        if mask is not None and len(mask) == len(color):
            rgba[3::4] = bytes(mask)[0::4].translate(_MASK_TO_ALPHA)
        else:
            rgba[3::4] = b"\xff" * (len(color) // 4)
    return bytes(rgba)


def clean_icon_path(path):
    """A local, absolute file path, or None. Network shares are skipped: they can stall."""
    if not isinstance(path, str):
        return None
    path = path.strip()
    if not path or len(path) > 32767 or "\0" in path:
        return None
    if not (os.path.isabs(path) or ntpath.isabs(path)):
        return None
    if path.startswith(("\\\\", "//")) and not path.startswith(("\\\\?\\", "\\\\.\\")):
        return None
    if path.upper().startswith("\\\\?\\UNC\\"):
        return None
    return path


def parse_icon_location(value):
    """'@%SystemRoot%\\System32\\AudioSrv.Dll,-203' -> (expanded path, -203), else None."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if text.startswith("@"):
        text = text[1:].strip()
    index = 0
    head, separator, tail = text.rpartition(",")
    if separator and re.fullmatch(r"\s*-?\d{1,6}\s*", tail):
        text, index = head.strip(), int(tail)
    path = clean_icon_path(ntpath.expandvars(text.strip().strip('"')))
    return (path, index) if path else None


def system_sounds_icon_location():
    """The speaker icon Windows' own volume mixer shows for System sounds."""
    if os.name != "nt":
        return None
    root = os.environ.get("SystemRoot") or os.environ.get("windir") or r"C:\Windows"
    return ntpath.join(root, "System32", "AudioSrv.dll"), -203


# MARK: - Windows icon resources

class ICONINFO(ctypes.Structure):
    _fields_ = [("fIcon", wintypes.BOOL), ("xHotspot", wintypes.DWORD), ("yHotspot", wintypes.DWORD),
                ("hbmMask", wintypes.HBITMAP), ("hbmColor", wintypes.HBITMAP)]


class BITMAP(ctypes.Structure):
    _fields_ = [("bmType", wintypes.LONG), ("bmWidth", wintypes.LONG), ("bmHeight", wintypes.LONG),
                ("bmWidthBytes", wintypes.LONG), ("bmPlanes", wintypes.WORD),
                ("bmBitsPixel", wintypes.WORD), ("bmBits", ctypes.c_void_p)]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD),
                ("biCompression", wintypes.DWORD), ("biSizeImage", wintypes.DWORD),
                ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wintypes.DWORD * 4)]


_WINDOWS_APIS = None
_WINDOWS_APIS_LOCK = threading.Lock()


def _windows_apis():
    global _WINDOWS_APIS
    with _WINDOWS_APIS_LOCK:
        if _WINDOWS_APIS is None:
            shell32 = ctypes.WinDLL("shell32", use_last_error=True)
            user32 = ctypes.WinDLL("user32", use_last_error=True)
            gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
            prototypes = (
                (shell32.SHDefExtractIconW, [wintypes.LPCWSTR, ctypes.c_int, wintypes.UINT,
                                             ctypes.POINTER(wintypes.HICON), ctypes.POINTER(wintypes.HICON),
                                             wintypes.UINT], ctypes.c_long),
                (user32.GetIconInfo, [wintypes.HICON, ctypes.POINTER(ICONINFO)], wintypes.BOOL),
                (user32.DestroyIcon, [wintypes.HICON], wintypes.BOOL),
                (gdi32.GetObjectW, [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
                (gdi32.CreateCompatibleDC, [wintypes.HDC], wintypes.HDC),
                (gdi32.DeleteDC, [wintypes.HDC], wintypes.BOOL),
                (gdi32.GetDIBits, [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT,
                                   ctypes.c_void_p, ctypes.POINTER(BITMAPINFO), wintypes.UINT], ctypes.c_int),
                (gdi32.DeleteObject, [wintypes.HANDLE], wintypes.BOOL),
            )
            for function, arguments, result in prototypes:
                function.argtypes = arguments
                function.restype = result
            _WINDOWS_APIS = SimpleNamespace(shell32=shell32, user32=user32, gdi32=gdi32)
        return _WINDOWS_APIS


def _dib_pixels(api, bitmap, width, height):
    """32-bit top-down BGRA rows of a GDI bitmap."""
    info = BITMAPINFO()
    info.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    info.bmiHeader.biWidth = width
    info.bmiHeader.biHeight = -height
    info.bmiHeader.biPlanes = 1
    info.bmiHeader.biBitCount = 32
    info.bmiHeader.biCompression = 0  # BI_RGB
    buffer = ctypes.create_string_buffer(width * height * 4)
    context = api.gdi32.CreateCompatibleDC(None)
    if not context:
        raise OSError("Windows could not create a drawing context for the icon.")
    try:
        lines = api.gdi32.GetDIBits(context, bitmap, 0, height, buffer, ctypes.byref(info), 0)
    finally:
        api.gdi32.DeleteDC(context)
    if lines != height:
        raise OSError("Windows could not read the icon pixels.")
    return buffer.raw


def _hicon_png(api, icon):
    info = ICONINFO()
    if not api.user32.GetIconInfo(icon, ctypes.byref(info)):
        raise OSError("Windows could not read the icon.")
    try:
        if not info.hbmColor:
            return None  # Monochrome icon.
        bitmap = BITMAP()
        if not api.gdi32.GetObjectW(info.hbmColor, ctypes.sizeof(BITMAP), ctypes.byref(bitmap)):
            raise OSError("Windows could not measure the icon.")
        width, height = int(bitmap.bmWidth), abs(int(bitmap.bmHeight))
        if not (0 < width <= 512 and 0 < height <= 512):
            return None
        color = _dib_pixels(api, info.hbmColor, width, height)
        mask = None
        if not any(color[3::4]) and info.hbmMask:
            mask = _dib_pixels(api, info.hbmMask, width, height)
        rgba = bgra_to_rgba(color, mask)
        if not any(rgba[3::4]):
            return None
        return encode_png(width, height, rgba)
    finally:
        if info.hbmColor:
            api.gdi32.DeleteObject(info.hbmColor)
        if info.hbmMask:
            api.gdi32.DeleteObject(info.hbmMask)


def windows_icon_png(path, index=0, pixels=ICON_PIXELS):
    """PNG of a file's icon resource; None when the file has none; OSError when unreadable."""
    api = _windows_apis()
    large, small = wintypes.HICON(), wintypes.HICON()
    # Low word: the large icon's size; high word: the small icon's size.
    result = api.shell32.SHDefExtractIconW(path, index, 0, ctypes.byref(large), ctypes.byref(small),
                                           (16 << 16) | pixels)
    try:
        if result == 1:  # S_FALSE: the file has no icons.
            return None
        if result != 0 or not large.value:
            raise OSError(f"Windows could not extract the icon (0x{result & 0xFFFFFFFF:08X}).")
        return _hicon_png(api, large)
    finally:
        for handle in (large, small):
            if handle.value:
                api.user32.DestroyIcon(handle)


# MARK: - Packaged app logos

def _local_name(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def _package_root(executable):
    directory = os.path.dirname(executable)
    for _ in range(PACKAGE_SEARCH_DEPTH):
        if os.path.isfile(os.path.join(directory, "AppxManifest.xml")):
            return directory
        parent = os.path.dirname(directory)
        if not parent or parent == directory:
            return None
        directory = parent
    return None


def _qualifiers(text):
    values = {}
    for part in text.split("_"):
        key, separator, value = part.partition("-")
        if not separator or not key or not value:
            return None
        values[key.casefold()] = value.casefold()
    return values


def _logo_score(qualifiers, base_size, pixels):
    """Rank one logo file: transparent ('unplated') first, then big enough, then closest."""
    if "contrast" in qualifiers or qualifiers.get("theme") == "light":
        return None
    altform = qualifiers.get("altform", "")
    if altform not in ("", "unplated"):
        return None  # lightunplated and friends are drawn for light backgrounds.
    try:
        if "targetsize" in qualifiers:
            size = int(qualifiers["targetsize"])
        elif "scale" in qualifiers:
            size = base_size * int(qualifiers["scale"]) / 100
        else:
            size = base_size
    except ValueError:
        return None
    if size <= 0:
        return None
    adequate = size >= pixels
    return (altform == "unplated", adequate, -size if adequate else size)


def _best_logo_file(root, relative, base_size, pixels):
    relative = relative.replace("\\", "/").strip("/")
    if not relative or ".." in relative.split("/"):
        return None
    directory = os.path.join(root, *relative.split("/")[:-1])
    stem, extension = os.path.splitext(relative.split("/")[-1])
    if not stem or extension.casefold() != ".png":
        return None
    try:
        names = os.listdir(directory)
    except OSError:
        return None
    best = None
    for name in names:
        folded = name.casefold()
        if not folded.endswith(".png") or not folded.startswith(stem.casefold()):
            continue
        middle = name[len(stem):-len(extension)]
        if middle == "":
            qualifiers = {}
        elif middle.startswith("."):
            qualifiers = _qualifiers(middle[1:])
            if qualifiers is None:
                continue
        else:
            continue  # Another file that merely shares the prefix.
        score = _logo_score(qualifiers, base_size, pixels)
        if score is not None and (best is None or score > best[0]):
            best = (score, name)
    return os.path.join(directory, best[1]) if best else None


def package_logo_png(executable, pixels=ICON_PIXELS):
    """The logo a packaged app declares for itself, as PNG bytes, or None."""
    root = _package_root(executable)
    if root is None:
        return None
    manifest = os.path.join(root, "AppxManifest.xml")
    try:
        if os.path.getsize(manifest) > MAX_MANIFEST_BYTES:
            return None
        document = ElementTree.parse(manifest).getroot()
    except (OSError, ElementTree.ParseError):
        return None
    relative = os.path.relpath(executable, root).replace("/", "\\").casefold()
    applications = [element for element in document.iter() if _local_name(element.tag) == "Application"]
    chosen = next((application for application in applications
                   if (application.get("Executable") or "").replace("/", "\\").casefold() == relative),
                  applications[0] if applications else None)
    candidates = []
    if chosen is not None:
        for element in chosen.iter():
            if _local_name(element.tag) == "VisualElements":
                for attribute, size in (("Square44x44Logo", 44), ("Square150x150Logo", 150)):
                    if element.get(attribute):
                        candidates.append((element.get(attribute), size))
                break
    for element in document.iter():
        if _local_name(element.tag) == "Logo" and (element.text or "").strip():
            candidates.append((element.text.strip(), 50))
            break
    for logo, size in candidates:
        path = _best_logo_file(root, logo, size, pixels)
        if path is None:
            continue
        try:
            if os.path.getsize(path) > MAX_ICON_BYTES:
                continue
            with open(path, "rb") as handle:
                data = handle.read(MAX_ICON_BYTES + 1)
        except OSError:
            continue
        if data.startswith(PNG_SIGNATURE) and len(data) <= MAX_ICON_BYTES:
            return data
    return None


def extract_icon_png(path, index=0):
    """PNG for a file's icon; None if it has none; OSError if Windows could not read it now."""
    failure = None
    if os.name == "nt":
        try:
            image = windows_icon_png(path, index)
            if image:
                return image
        except (OSError, ValueError, AttributeError) as error:
            failure = error
    if index == 0:
        logo = package_logo_png(path)
        if logo:
            return logo
    if failure is not None:
        raise OSError(str(failure))
    return None


# MARK: - Registry

class IconRegistry:
    """Maps opaque icon IDs to the files they came from and caches their PNGs."""

    def __init__(self, extractor=None, key=None):
        self._key = key or secrets.token_bytes(32)
        self._extractor = extractor or extract_icon_png
        self._lock = threading.Lock()
        self._extract_lock = threading.Lock()
        self._sources = OrderedDict()  # icon ID -> (path, index)
        self._images = OrderedDict()   # icon ID -> PNG bytes, or None when the file has no icon
        self._image_bytes = 0

    def identity(self, path, index=0):
        text = f"{path.casefold()}\0{index}".encode("utf-8", "surrogatepass")
        return hmac.new(self._key, text, hashlib.sha256).hexdigest()[:32]

    def register(self, path, index=0):
        """Icon ID for a file, or None when it is known to have no icon."""
        path = clean_icon_path(path)
        if path is None or not isinstance(index, int) or isinstance(index, bool) or abs(index) > 0xFFFF:
            return None
        identity = self.identity(path, index)
        with self._lock:
            if self._images.get(identity, _MISSING) is None:
                return None
            self._sources[identity] = (path, index)
            self._sources.move_to_end(identity)
            while len(self._sources) > MAX_SOURCES:
                evicted, _ = self._sources.popitem(last=False)
                self._forget(evicted)
        return identity

    def lookup(self, identities):
        """Base64 PNG (or None) for every ID this agent listed; unknown IDs are left out."""
        result = {}
        for identity in identities:
            with self._lock:
                source = self._sources.get(identity)
                image = self._images.get(identity, _MISSING)
                if image is not _MISSING:
                    self._images.move_to_end(identity)
            if source is None:
                continue
            if image is _MISSING:
                image = self._extract(identity, source)
            result[identity] = base64.b64encode(image).decode("ascii") if image else None
        return result

    def _extract(self, identity, source):
        with self._extract_lock:
            with self._lock:
                image = self._images.get(identity, _MISSING)
            if image is not _MISSING:
                return image
            try:
                image = self._extractor(*source)
            except Exception:
                return None  # Not cached: a later request tries again.
            if image is not None and (not isinstance(image, (bytes, bytearray))
                                      or not bytes(image).startswith(PNG_SIGNATURE)
                                      or len(image) > MAX_ICON_BYTES):
                image = None
            image = bytes(image) if image else None
            with self._lock:
                self._forget(identity)
                self._images[identity] = image
                self._image_bytes += len(image) if image else _NO_ICON_COST
                while self._image_bytes > MAX_CACHE_BYTES and self._images:
                    self._forget(next(iter(self._images)))
            return image

    def _forget(self, identity):
        image = self._images.pop(identity, _MISSING)
        if image is not _MISSING:
            self._image_bytes -= len(image) if image else _NO_ICON_COST


ICONS = IconRegistry()


def parse_icon_ids(text):
    """Comma-separated icon IDs from a query string, deduplicated; ValueError when malformed."""
    identities = []
    for value in (text or "").split(","):
        value = value.strip()
        if not value:
            continue
        if not ID_PATTERN.fullmatch(value):
            raise ValueError("Icon IDs are 32 lowercase hexadecimal characters.")
        if value not in identities:
            identities.append(value)
    if not identities:
        raise ValueError("Ask for at least one icon ID.")
    if len(identities) > MAX_IDS_PER_REQUEST:
        raise ValueError(f"Ask for at most {MAX_IDS_PER_REQUEST} icons at a time.")
    return identities
