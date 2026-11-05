"""Qt tray and consent-mediated capture; all Qt objects stay on the GUI thread."""
import os
from pathlib import Path
import threading
import time

from PySide6.QtCore import QByteArray, QBuffer, QIODevice, QObject, Qt, QTimer, QUrl, Signal, Slot
from PySide6.QtGui import QDesktopServices, QIcon
from PySide6.QtWidgets import QApplication, QDialog, QLabel, QMenu, QMessageBox, QPushButton, QSystemTrayIcon, QVBoxLayout


class ScreenCapture(QObject):
    requested = Signal(bool)

    def __init__(self):
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
        self.requested.connect(self._activate)

    def start(self):
        with self.condition:
            self.wanted = True
            self.latest = None
            self.error = None
            self.delivered = self.sequence
        self.requested.emit(True)

    def stop(self):
        with self.condition:
            self.wanted = False
            self.latest = None
            self.geometry = None
            self.condition.notify_all()
        self.requested.emit(False)

    @Slot(bool)
    def _activate(self, active):
        if not active:
            if self.screen is not None:
                self.screen.setActive(False)
            return
        with self.condition:
            if not self.wanted:
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


class Tray(QObject):
    pairing = Signal(str, str, object)
    notification = Signal(str, str)
    failure = Signal(str)

    def __init__(self, agent, on_stop, startup, log_path):
        super().__init__()
        self.agent, self.on_stop, self.startup, self.log_path = agent, on_stop, startup, log_path
        self.dialogs = []
        self.capture = ScreenCapture()
        agent.PLATFORM.capture = self.capture
        icon = QIcon(str(Path(__file__).with_name("orbit-linux.svg")))
        self.tray = QSystemTrayIcon(icon, self)
        self.tray.setToolTip("Orbit Linux Companion")
        self.menu = QMenu()
        self.menu.addAction("Connection details…", self.details)
        self.menu.addAction("Copy manual pairing token", lambda: QApplication.clipboard().setText(agent.API_TOKEN))
        self.menu.addAction("Desktop capabilities…", self.diagnostics)
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
