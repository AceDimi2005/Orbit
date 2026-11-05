"""Persistent, unprivileged wlr virtual pointer for Hyprland/Sway and peers.

The caller serializes every operation (including close) with its input lock. Keep
one Wayland connection across calls so a drag survives between phone messages.
All round trips have deadlines; no input is replayed through another backend.
"""
import select
import time


class PointerUnavailable(RuntimeError):
    pass


class WaylandPointer:
    def __init__(self):
        self.display = self.manager = self.pointer = None
        self.outputs = {}
        self.bound_output = None
        self.held = set()
        self.manager_version = 0
        try:
            from pywayland.client import Display
            from pywayland.protocol.wayland import WlOutput
            from orbit_wayland_protocols.wlr_virtual_pointer_unstable_v1 import ZwlrVirtualPointerManagerV1
            self.display = Display()
            self.display.connect()
            self.registry = self.display.get_registry()

            def added(registry, name, interface, version):
                if interface == ZwlrVirtualPointerManagerV1.name:
                    self.manager_version = min(version, 2)
                    self.manager = registry.bind(name, ZwlrVirtualPointerManagerV1, self.manager_version)
                elif interface == WlOutput.name and version >= 4:
                    output = registry.bind(name, WlOutput, 4)
                    self.outputs[name] = {"proxy": output, "name": None}
                    output.dispatcher["name"] = lambda _, value: self.outputs[name].update(name=value)

            def removed(_, name):
                output = self.outputs.pop(name, None)
                if output:
                    output["proxy"].destroy()

            self.registry.dispatcher["global"] = added
            self.registry.dispatcher["global_remove"] = removed
            self._sync()
            if self.manager is None:
                raise PointerUnavailable("The compositor does not expose the wlr virtual-pointer protocol.")
            self._sync()  # wl_output names arrive after the registry bindings.
        except Exception as error:
            self.close()
            if isinstance(error, PointerUnavailable):
                raise
            raise PointerUnavailable("Could not connect to the native Wayland pointer backend.") from error

    def _sync(self, timeout=2):
        done = []
        callback = self.display.sync()
        callback.dispatcher["done"] = lambda *_: done.append(True)
        deadline = time.monotonic() + timeout
        try:
            while not done:
                if self.display.dispatch(block=False) < 0:
                    raise PointerUnavailable("The Wayland connection closed.")
                if done:
                    break
                pending = self.display.flush() < 0
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise PointerUnavailable("The compositor did not respond to pointer input.")
                fd = self.display.get_fd()
                readable, _, _ = select.select([fd], [fd] if pending else [], [], remaining)
                if readable:
                    self.display.read()
        finally:
            callback.destroy()

    @staticmethod
    def _time():
        return int(time.monotonic() * 1000) & 0xFFFFFFFF

    def _device(self, output):
        self._sync()  # Process output removals before accepting absolute input.
        target = None
        if output is not None:
            target = next((item["proxy"] for item in self.outputs.values() if item["name"] == output), None)
            if self.manager_version < 2 or target is None:
                raise PointerUnavailable("The shared output is no longer available for direct-touch input.")
        if self.pointer is None or (output is not None and target is not self.bound_output):
            self.release()
            if self.pointer is not None:
                self.pointer.destroy()
            self.pointer = (self.manager.create_virtual_pointer_with_output(None, target) if target is not None
                            else self.manager.create_virtual_pointer(None))
            self.bound_output = target

    def cursor(self, dx=0, dy=0, click="", scroll=0, hscroll=0, norm_x=None, norm_y=None, drag="", output=None):
        self._device(output if norm_x is not None else None)
        now = self._time()
        if norm_x is not None:
            if output is None:
                raise PointerUnavailable("Choose a native screen in the tray before direct-touch input.")
            # The compositor maps to the captured wl_output, including its scale,
            # rotation and layout position. Never guess desktop-wide coordinates.
            self.pointer.motion_absolute(now, round(norm_x * 65535), round(norm_y * 65535), 65536, 65536)
        elif dx or dy:
            self.pointer.motion(now, dx, dy)
        if drag:
            self.pointer.button(now, 272, int(drag == "down"))
            (self.held.add if drag == "down" else self.held.discard)(272)
        self.pointer.frame()
        if click:
            button = {"left": 272, "right": 273, "middle": 274, "double": 272}[click]
            for _ in range(2 if click == "double" else 1):
                self.pointer.button(self._time(), button, 1)
                self.held.add(button)
                self.pointer.frame()
                self.pointer.button(self._time(), button, 0)
                self.held.discard(button)
                self.pointer.frame()
        if scroll or hscroll:
            self.pointer.axis_source(0)  # wl_pointer.axis_source.wheel
            for axis, steps in ((0, -scroll), (1, hscroll)):
                if steps:
                    self.pointer.axis_discrete(now, axis, steps * 15.0, steps)
            self.pointer.frame()
        self._sync()

    def release(self):
        if self.pointer is not None and self.held:
            for button in self.held:
                self.pointer.button(self._time(), button, 0)
            self.pointer.frame()
            self.held.clear()
            self._sync()

    def close(self):
        try:
            self.release()
        except Exception:
            pass  # Disconnect also removes this client's virtual devices.
        finally:
            if self.display is not None:
                self.display.disconnect()
            self.display = self.manager = self.pointer = None
            self.held.clear()
