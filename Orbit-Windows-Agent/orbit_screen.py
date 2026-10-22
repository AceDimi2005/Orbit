"""JPEG screen preview for /ws/stream, captured and encoded off the event loop.

Grabbing a 4K desktop and encoding it as JPEG takes tens of milliseconds. Done on
the asyncio loop, that stalls /ws/input and every other request, so each preview
gets one worker thread of its own: the capture library keeps per-thread GDI
handles on Windows, so the same thread opens, grabs and closes.

Pacing adapts to the PC and the link: never faster than MAX_FPS, slower while
capture/encode or sending takes longer, and an unchanged screen is not re-encoded
(the last frame is re-sent once a second so viewers can tell the stream is alive).
"""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import threading
import time

MAX_FPS = 15
MIN_INTERVAL = 1.0 / MAX_FPS
MAX_INTERVAL = 0.5
KEEPALIVE_SECONDS = 1.0
MAX_SIZE = (1280, 720)
QUALITY_STEPS = (68, 58, 48)
MAX_STREAMS = 2


class NoDisplay(RuntimeError):
    pass


class FrameSource:
    """Owns one capture object. Every method runs on the stream's single worker thread."""

    def __init__(self, capture_factory=None, image_module=None, max_size=MAX_SIZE):
        self._capture_factory = capture_factory
        self._image = image_module
        self._max_size = max_size
        self._capture = None
        self._monitor = None
        self.thread_names = []

    def open(self):
        self.thread_names.append(threading.current_thread().name)
        if self._capture_factory is None:
            import mss
            self._capture_factory = mss.mss
        if self._image is None:
            from PIL import Image
            self._image = Image
        self._capture = self._capture_factory()
        monitors = getattr(self._capture, "monitors", [])
        if len(monitors) < 2:
            raise NoDisplay("No display is available")
        self._monitor = monitors[1]

    def frame(self, previous_digest=None, force=False, quality=QUALITY_STEPS[0]):
        """(jpeg bytes or None when unchanged, digest of the scaled frame)."""
        self.thread_names.append(threading.current_thread().name)
        raw = self._capture.grab(self._monitor)
        image = self._image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
        image.thumbnail(self._max_size)
        digest = hashlib.blake2b(image.tobytes(), digest_size=16).digest()
        if digest == previous_digest and not force:
            return None, digest
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=quality)
        return buffer.getvalue(), digest

    def close(self):
        capture, self._capture = self._capture, None
        if capture is not None and hasattr(capture, "close"):
            try:
                capture.close()
            except Exception:
                pass


class StreamSlots:
    """At most MAX_STREAMS previews at once; each one costs a capture thread."""

    def __init__(self, limit=MAX_STREAMS):
        self.limit = limit
        self.active = 0
        self._lock = threading.Lock()

    def acquire(self):
        with self._lock:
            if self.active >= self.limit:
                return False
            self.active += 1
            return True

    def release(self):
        with self._lock:
            self.active = max(0, self.active - 1)


def next_interval(work_seconds, send_seconds):
    """Seconds between frames: as fast as MAX_FPS allows, slower when the PC or the link lags."""
    return min(MAX_INTERVAL, max(MIN_INTERVAL, work_seconds * 1.5, send_seconds * 1.5))


def next_quality(index, send_seconds):
    """Lower JPEG quality while sending is slow; recover one step at a time."""
    if send_seconds > MIN_INTERVAL * 2 and index < len(QUALITY_STEPS) - 1:
        return index + 1
    if send_seconds < MIN_INTERVAL / 2 and index > 0:
        return index - 1
    return index


async def stream_frames(send_bytes, source, *, clock=time.monotonic, sleep=asyncio.sleep,
                        executor=None, max_frames=None):
    """Send JPEG frames from `source` through `send_bytes` until sending fails."""
    loop = asyncio.get_running_loop()
    owned = executor is None
    executor = executor or ThreadPoolExecutor(max_workers=1, thread_name_prefix="orbit-screen")
    try:
        await loop.run_in_executor(executor, source.open)
        last_digest, last_frame, last_sent = None, None, None
        quality_index = 0
        sent = 0
        while max_frames is None or sent < max_frames:
            started = clock()
            keepalive = last_sent is not None and started - last_sent >= KEEPALIVE_SECONDS
            frame, digest = await loop.run_in_executor(
                executor, source.frame, last_digest, last_frame is None, QUALITY_STEPS[quality_index])
            work = clock() - started
            send = 0.0
            if frame is not None:
                last_frame = frame
            if frame is not None or keepalive:
                send_started = clock()
                await send_bytes(last_frame)
                send = clock() - send_started
                last_sent = clock()
                last_digest = digest
                sent += 1
                quality_index = next_quality(quality_index, send)
            await sleep(max(0.0, next_interval(work, send) - (clock() - started)))
    finally:
        # The worker may still be inside a grab; closing is queued behind it, on the
        # same thread, and never blocks the event loop.
        try:
            executor.submit(source.close)
        except RuntimeError:
            pass
        if owned:
            executor.shutdown(wait=False)
