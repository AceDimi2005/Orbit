"""Qt tray and consent-mediated capture; all Qt objects stay on the GUI thread."""
import os
import io
from pathlib import Path
import threading
import time

from PySide6.QtCore import QByteArray, QBuffer, QIODevice, QObject, Qt, QTimer, QUrl, Signal, Slot
from PySide6.QtGui import QDesktopServices, QIcon
from PySide6.QtWidgets import QApplication, QDialog, QLabel, QMenu, QMessageBox, QPushButton, QSystemTrayIcon, QVBoxLayout


class ScreenCapture(QObject):
    requested = Signal(bool)

    def __init__(self, commands=None):
        super().__init__()
        self.condition = threading.Condition()
        self.wanted = False
        self.latest = None
        self.sequence = 0
        self.delivered = 0
        self.error = None
        self.geometry = None
        self.last_encoded = 0.0
        self.screen = self.session = self.sink = None
        from orbit_linux_backend import Commands
        self.commands = commands or Commands()
        self.selected_output = None
        self.approved_output = None
        self.output_name = None
        self.generation = 0
        self.consent = None
        self.requested.connect(self._activate)

    def start(self):
        with self.condition:
            self.wanted = True
            self.latest = None
            self.error = None
            self.delivered = self.sequence
            self.generation += 1
            self.approved_output = self.output_name = None
        self.requested.emit(True)

    def stop(self):
        with self.condition:
            self.wanted = False
            self.latest = None
            self.geometry = None
            self.approved_output = self.output_name = None
            self.generation += 1
            self.condition.notify_all()
        self.requested.emit(False)

    @Slot(bool)
    def _activate(self, active):
        if not active:
            if self.consent is not None:
                self.consent.reject()
                self.consent = None
            if self.screen is not None:
                self.screen.setActive(False)
            return
        with self.condition:
            if not self.wanted:
                return
            if self.selected_output is not None:
                self._request_native_consent(self.selected_output, self.generation)
                return
        try:
            if self.screen is None:
                from PySide6.QtMultimedia import QMediaCaptureSession, QScreenCapture, QVideoSink
                self.screen = QScreenCapture(self)
                self.session = QMediaCaptureSession(self)
                self.sink = QVideoSink(self)
                self.session.setScreenCapture(self.screen)
                self.session.setVideoSink(self.sink)
                self.sink.videoFrameChanged.connect(self._frame)
                self.screen.errorOccurred.connect(self._failed)
            if not QApplication.platformName().startswith("wayland"):
                primary = QApplication.primaryScreen()
                if primary is None:
                    raise RuntimeError("No screen is available.")
                self.screen.setScreen(primary)
                rect = primary.geometry()
                self.geometry = (rect.x(), rect.y(), rect.width(), rect.height())
            # Wayland invokes the ScreenCast portal's chooser; never uses XWayland
            # to capture only X11 windows or silently bypass the compositor.
            self.screen.setActive(True)
        except (ImportError, RuntimeError) as error:
            self._failed(None, str(error))

    def _failed(self, code, message):
        with self.condition:
            self.error = message or "Screen capture failed."
            self.latest = None
            self.output_name = None
            self.condition.notify_all()

    def _frame(self, frame):
        if not frame.isValid() or time.monotonic() - self.last_encoded < 0.09:
            return
        with self.condition:
            if not self.wanted:
                return
        image = frame.toImage()
        if image.isNull():
            return
        image = image.scaled(1280, 720, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
        data = QByteArray()
        buffer = QBuffer(data)
        buffer.open(QIODevice.OpenModeFlag.WriteOnly)
        if not image.save(buffer, "JPEG", 68):
            return
        buffer.close()
        with self.condition:
            if self.wanted:
                self.latest = bytes(data)
                self.sequence += 1
                self.last_encoded = time.monotonic()
                self.condition.notify_all()

    def frame(self, timeout):
        if self.selected_output is not None:
            return self._native_frame(timeout)
        deadline = time.monotonic() + timeout
        with self.condition:
            while self.wanted and not self.error:
                if self.latest is not None and self.sequence > self.delivered:
                    self.delivered = self.sequence
                    return self.latest
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Waiting for screen sharing consent or a frame timed out.")
                self.condition.wait(remaining)
            raise RuntimeError(self.error or "Screen sharing stopped.")

    def select_output(self, output):
        self.stop()
        with self.condition:
            self.selected_output = output

    def _request_native_consent(self, output, generation):
        dialog = QMessageBox(QMessageBox.Icon.Question, "Share a screen with Orbit",
                             f"Allow your paired phone to view {output}?\n\nDirect touch will control this screen. Stop sharing from the Orbit tray at any time.",
                             QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No)
        dialog.setTextFormat(Qt.TextFormat.PlainText)
        dialog.setDefaultButton(QMessageBox.StandardButton.No)
        dialog.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, True)
        self.consent = dialog

        def answered(result):
            if self.consent is dialog:
                self.consent = None
            with self.condition:
                if self.wanted and self.generation == generation:
                    if result == QMessageBox.StandardButton.Yes:
                        self.approved_output = output
                    else:
                        self.error = "Screen sharing was declined on the PC."
                    self.condition.notify_all()

        dialog.finished.connect(answered)
        dialog.open()

    def _native_frame(self, timeout):
        deadline = time.monotonic() + timeout
        with self.condition:
            generation = self.generation
            while self.wanted and not self.error and self.approved_output is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Waiting for screen sharing consent timed out.")
                self.condition.wait(remaining)
            if not self.wanted or self.error:
                raise RuntimeError(self.error or "Screen sharing stopped.")
            output = self.approved_output
        # Runs on the stream worker, never the GUI thread. grim captures exactly
        # this wl_output through the compositor; it never reads XWayland windows.
        try:
            data = self.commands.run("grim", "-o", output, "-t", "jpeg", "-q", "68", "-", timeout=5)
            from PIL import Image
            with Image.open(io.BytesIO(data)) as picture:
                picture.thumbnail((1280, 720))
                encoded = io.BytesIO()
                picture.convert("RGB").save(encoded, "JPEG", quality=68)
                data = encoded.getvalue()
        except Exception as error:
            message = "Native capture failed. Check that grim supports your compositor and the selected screen is connected."
            with self.condition:
                if generation == self.generation:
                    self._failed(None, message)
            raise RuntimeError(message) from error
        with self.condition:
            if not self.wanted or generation != self.generation:
                raise RuntimeError("Screen sharing stopped.")
            self.output_name = output
        return data


class Tray(QObject):
    pairing = Signal(str, str, object)
    notification = Signal(str, str)
    failure = Signal(str)

    def __init__(self, agent, on_stop, startup, log_path):
        super().__init__()
        self.agent, self.on_stop, self.startup, self.log_path = agent, on_stop, startup, log_path
        self.dialogs = []
        self.capture = ScreenCapture(agent.PLATFORM.commands)
        agent.PLATFORM.capture = self.capture
        icon = QIcon(str(Path(__file__).with_name("orbit-linux.svg")))
        self.tray = QSystemTrayIcon(icon, self)
        self.tray.setToolTip("Orbit Linux Companion")
        self.menu = QMenu()
        self.menu.addAction("Connection details…", self.details)
        self.menu.addAction("Copy manual pairing token", lambda: QApplication.clipboard().setText(agent.API_TOKEN))
        self.menu.addAction("Desktop capabilities…", self.diagnostics)
        if agent.PLATFORM.wayland:
            sources = self.menu.addMenu("Screen preview source")
            sources.aboutToShow.connect(lambda: self._screen_sources(sources))
        self.menu.addAction("Stop screen sharing", self.capture.stop)
        startup_action = self.menu.addAction("Start at login")
        startup_action.setCheckable(True)
        startup_action.setChecked(startup.enabled())
        startup_action.triggered.connect(self._startup)
        self.menu.addAction("Open agent log", lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(log_path))))
        self.menu.addAction("Linux setup guide", lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(Path(__file__).with_name("README.md")))))
        self.menu.addSeparator()
        self.menu.addAction("Quit Orbit", on_stop)
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(lambda reason: self.details() if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
        self.pairing.connect(self._pairing)
        self.notification.connect(lambda title, text: self.tray.showMessage(title, text))
        self.failure.connect(lambda text: QMessageBox.critical(None, "Orbit could not start", text))
        self.tray.show()
        if not QSystemTrayIcon.isSystemTrayAvailable():
            # GNOME without a tray extension (or a panel still starting) must not
            # leave an invisible process with no way to stop it.
            self.details(no_tray=True)

    def _screen_sources(self, menu):
        menu.clear()
        native = self.agent.PLATFORM.use_wtype or self.agent.PLATFORM.pointer_backend == "wayland"
        screens = QApplication.screens() if native else []
        for label, output in [("Portal chooser", None)] + [(f"{screen.name()} (native, direct touch)", screen.name()) for screen in screens]:
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(self.capture.selected_output == output)
            action.setEnabled(output is None or self.agent.PLATFORM.commands.has("grim"))
            action.triggered.connect(lambda checked=False, name=output: self.capture.select_output(name))

    def _startup(self, enabled):
        try:
            self.startup.set_enabled(enabled)
        except OSError as error:
            QMessageBox.warning(None, "Could not change startup", str(error))

    def _dialog(self, title, text):
        dialog = QDialog()
        dialog.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, True)
        dialog.setWindowTitle(title)
        layout = QVBoxLayout(dialog)
        label = QLabel(text)
        label.setTextFormat(Qt.TextFormat.PlainText)
        label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        label.setWordWrap(True)
        layout.addWidget(label)
        self.dialogs.append(dialog)
        dialog.finished.connect(lambda _: self.dialogs.remove(dialog) if dialog in self.dialogs else None)
        return dialog, layout

    def details(self, no_tray=False):
        status = self.agent.tray_status_snapshot()
        text = (f"{status['hostname']} — Orbit {status['agentVersion']}\n\n"
                f"Address: {status['ipAddress']}\nHTTPS port: {status['securePort']}\n\n"
                f"Certificate SHA-256:\n{status['fingerprint']}\n\n"
                "Choose Find my PC on your phone. A one-use code will appear here.\n"
                "Start Orbit inside your graphical session, without sudo.")
        if no_tray:
            text += "\n\nNo system tray is available. Enable a Waybar tray, a StatusNotifier panel, or a GNOME tray extension."
        dialog, layout = self._dialog("Orbit Linux Companion", text)
        copy = QPushButton("Copy manual pairing token")
        copy.clicked.connect(lambda: QApplication.clipboard().setText(self.agent.API_TOKEN))
        layout.addWidget(copy)
        stop = QPushButton("Quit Orbit")
        stop.clicked.connect(self.on_stop)
        layout.addWidget(stop)
        dialog.show()

    def diagnostics(self):
        import json
        dialog, _ = self._dialog("Orbit desktop capabilities", json.dumps(self.agent.PLATFORM.diagnostics(), indent=2))
        dialog.show()

    def show_pin(self, name, pin):
        cancelled = threading.Event()
        self.pairing.emit(name, pin, cancelled)
        return cancelled.set

    @Slot(str, str, object)
    def _pairing(self, name, pin, cancelled):
        if cancelled.is_set():
            return
        dialog, _ = self._dialog("Pair with Orbit", f"Pair {name}\n\nCode: {pin}\n\nEnter it on your phone. This code expires in two minutes and works once.\nIgnore requests you did not initiate.")
        deadline = time.monotonic() + 120
        timer = QTimer(dialog)
        timer.setInterval(200)
        timer.timeout.connect(lambda: dialog.close() if cancelled.is_set() or time.monotonic() >= deadline else None)
        timer.start()
        # PINs are deliberately absent from desktop notifications and log files.
        self.tray.showMessage("Orbit pairing request", "Open Orbit to see the one-use pairing code.")
        dialog.show()

    def close(self):
        self.capture.stop()
        for dialog in list(self.dialogs):
            dialog.close()
        self.tray.hide()
