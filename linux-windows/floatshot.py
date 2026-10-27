"""FloatShot for Linux and Windows.

Tray app: Ctrl+Shift+2 captures a region into a floating, always-on-top window
you can annotate, OCR, copy, or delete. The tray menu also records the screen
or a region to an MP4.
"""
import os
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import mss
import numpy as np
from PySide6.QtCore import QObject, QPoint, QRect, QSettings, Qt, QTimer, Signal
from PySide6.QtGui import (QAction, QColor, QCursor, QFont, QGuiApplication, QIcon, QImage,
                           QKeySequence, QPainter, QPainterPath, QPen, QPixmap)
from PySide6.QtWidgets import (QApplication, QColorDialog, QDialog, QDialogButtonBox,
                               QFormLayout, QHBoxLayout, QInputDialog, QKeySequenceEdit, QPushButton,
                               QLabel, QMenu, QMessageBox, QPlainTextEdit, QSystemTrayIcon,
                               QToolButton, QVBoxLayout, QWidget)

VERSION = "1.7.1"
ASSETS = Path(getattr(sys, "_MEIPASS", Path(__file__).parent))


# MARK: - Capture

def grab(rect: QRect) -> QImage:
    """Grabs a rect given in Qt logical (device-independent) coordinates."""
    screen = QGuiApplication.screenAt(rect.center()) or QGuiApplication.primaryScreen()
    ratio = screen.devicePixelRatio()
    box = {"left": int(rect.x() * ratio), "top": int(rect.y() * ratio),
           "width": int(rect.width() * ratio), "height": int(rect.height() * ratio)}
    with mss.mss() as sct:
        shot = sct.grab(box)
    img = QImage(shot.bgra, shot.width, shot.height, QImage.Format_ARGB32).copy()
    img.setDevicePixelRatio(ratio)
    return img


def ocr(image: QImage) -> str:
    """Tesseract OCR; needs the tesseract binary installed and on PATH."""
    try:
        import pytesseract
        from PIL import Image
    except ImportError:
        return "OCR needs the pytesseract and Pillow packages."
    rgb = image.convertToFormat(QImage.Format_RGB888)
    arr = np.frombuffer(rgb.constBits(), np.uint8).reshape(rgb.height(), rgb.bytesPerLine())
    pil = Image.fromarray(arr[:, : rgb.width() * 3].reshape(rgb.height(), rgb.width(), 3))
    try:
        return pytesseract.image_to_string(pil).strip()
    except pytesseract.TesseractNotFoundError:
        return ("Tesseract isn't installed. Windows: install it from "
                "https://github.com/UB-Mannheim/tesseract/wiki. Linux: sudo apt install tesseract-ocr")


# MARK: - Region selection overlay

def draw_red_frame(p: QPainter, r: QRect):
    """Red dashed outline with solid corner marks, matching the macOS app."""
    p.setRenderHint(QPainter.Antialiasing)
    p.setPen(QPen(QColor(220, 38, 38, 220), 3, Qt.DashLine))
    p.drawRect(r)
    n = min(28, r.width() // 3, r.height() // 3)
    p.setPen(QPen(QColor(220, 38, 38), 5, Qt.SolidLine, Qt.RoundCap))
    for corner, dx, dy in ((r.topLeft(), 1, 1), (r.topRight(), -1, 1),
                           (r.bottomLeft(), 1, -1), (r.bottomRight(), -1, -1)):
        p.drawLine(corner, corner + QPoint(n * dx, 0))
        p.drawLine(corner, corner + QPoint(0, n * dy))

class SelectionOverlay(QWidget):
    finished = Signal(object)  # QRect in global logical coords, or None

    def __init__(self):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_DeleteOnClose)
        self.setCursor(Qt.CrossCursor)
        geo = QRect()
        for s in QGuiApplication.screens():
            geo = geo.united(s.geometry())
        self.setGeometry(geo)
        self.start = self.end = None

    def selection(self) -> QRect | None:
        if self.start is None:
            return None
        return QRect(self.start, self.end).normalized()

    def paintEvent(self, _):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(0, 0, 0, 80))
        sel = self.selection()
        if sel:
            p.setCompositionMode(QPainter.CompositionMode_Clear)
            p.fillRect(sel, Qt.transparent)
            p.setCompositionMode(QPainter.CompositionMode_SourceOver)
            draw_red_frame(p, sel.adjusted(-3, -3, 3, 3))
            label = f" {sel.width()} × {sel.height()} "
            box = p.fontMetrics().boundingRect(label).adjusted(-2, -2, 2, 2)
            box.moveTopLeft(sel.bottomLeft() + QPoint(0, 8))
            p.fillRect(box, QColor(220, 38, 38))
            p.setPen(Qt.white)
            p.drawText(box, Qt.AlignCenter, label)

    def mousePressEvent(self, e):
        if e.button() == Qt.RightButton:
            self._finish(None)
            return
        self.start = self.end = e.position().toPoint()
        self.update()

    def mouseMoveEvent(self, e):
        if self.start is not None:
            self.end = e.position().toPoint()
            self.update()

    def mouseReleaseEvent(self, e):
        if e.button() != Qt.LeftButton or self.start is None:
            return
        self.end = e.position().toPoint()
        sel = self.selection()
        self._finish(sel.translated(self.geometry().topLeft()) if sel.width() > 3 and sel.height() > 3 else None)

    def keyPressEvent(self, e):
        if e.key() == Qt.Key_Escape:
            self._finish(None)

    def _finish(self, rect):
        self.hide()
        # Let the compositor remove the overlay before anything is captured.
        QTimer.singleShot(150, lambda: (self.finished.emit(rect), self.close()))


# MARK: - Floating shot

class Canvas(QWidget):
    """The screenshot with drawn strokes and typed notes on top."""

    def __init__(self, image: QImage):
        super().__init__()
        self.image = image
        self.mode = "move"
        self.color = QColor("red")
        self.items = []  # ("stroke", QPainterPath, QColor) | ("note", QPoint, str, QColor)
        self.current = None
        self.drag_origin = None
        size = image.deviceIndependentSize().toSize()
        self.setFixedSize(size)

    def render_image(self) -> QImage:
        out = QImage(self.image.size(), QImage.Format_ARGB32)
        out.setDevicePixelRatio(self.image.devicePixelRatio())
        p = QPainter(out)
        self._paint(p)
        p.end()
        return out

    def _paint(self, p: QPainter):
        p.setRenderHint(QPainter.Antialiasing)
        p.drawImage(0, 0, self.image)
        for item in self.items + ([("stroke", self.current, self.color)] if self.current else []):
            if item[0] == "stroke":
                p.setPen(QPen(item[2], 3, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
                p.drawPath(item[1])
            else:
                p.setPen(item[3])
                p.setFont(QFont(self.font().family(), 16, QFont.Bold))
                p.drawText(item[1], item[2])

    def paintEvent(self, _):
        self._paint(QPainter(self))

    def mousePressEvent(self, e):
        if e.button() != Qt.LeftButton:
            return
        pos = e.position().toPoint()
        if self.mode == "move":
            self.drag_origin = e.globalPosition().toPoint() - self.window().pos()
        elif self.mode == "draw":
            self.current = QPainterPath(pos)
        else:
            text, ok = QInputDialog.getText(self, "FloatShot", "Note:")
            if ok and text:
                self.items.append(("note", pos, text, QColor(self.color)))
                self.update()

    def mouseMoveEvent(self, e):
        if self.mode == "move" and self.drag_origin is not None:
            self.window().move(e.globalPosition().toPoint() - self.drag_origin)
        elif self.current is not None:
            self.current.lineTo(e.position())
            self.update()

    def mouseReleaseEvent(self, _):
        self.drag_origin = None
        if self.current is not None:
            self.items.append(("stroke", self.current, QColor(self.color)))
            self.current = None
            self.update()

    def undo(self):
        if self.items:
            self.items.pop()
            self.update()


class FloatingShot(QWidget):
    closed = Signal(object)

    def __init__(self, image: QImage, pos: QPoint):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setAttribute(Qt.WA_DeleteOnClose)
        self.image = image
        self.ocr_text = None
        self.canvas = Canvas(image)

        bar = QHBoxLayout()
        bar.setContentsMargins(6, 4, 6, 4)
        for label, mode in (("✋ Move", "move"), ("✏️ Draw", "draw"), ("T Text", "text")):
            b = QToolButton(text=label, checkable=True, autoExclusive=True)
            b.setChecked(mode == "move")
            b.clicked.connect(lambda _, m=mode: setattr(self.canvas, "mode", m))
            bar.addWidget(b)
        for label, fn in (("🎨", self.pick_color), ("↶ Undo", self.canvas.undo), ("OCR", self.toggle_ocr)):
            b = QToolButton(text=label)
            b.clicked.connect(fn)
            bar.addWidget(b)
        bar.addStretch()
        close = QToolButton(text="✕")
        close.setToolTip("Delete this screenshot")
        close.setStyleSheet("QToolButton { color: #dc2626; font-weight: bold; }")
        close.clicked.connect(self.delete)
        bar.addWidget(close)

        self.ocr_box = QPlainTextEdit()
        self.ocr_box.setFixedWidth(260)
        self.ocr_box.hide()

        body = QHBoxLayout()
        body.setContentsMargins(0, 0, 0, 0)
        body.addWidget(self.canvas)
        body.addWidget(self.ocr_box)
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addLayout(bar)
        root.addLayout(body)
        self.move(pos)

    # Right-click anywhere opens the menu; Delete is the only way to remove a shot.
    def contextMenuEvent(self, e):
        menu = QMenu(self)
        menu.addAction("Copy Image", self.copy_image)
        menu.addAction("Copy Text from Image", self.copy_text)
        menu.addAction("Save Image…", self.save_image)
        menu.addSeparator()
        menu.addAction("Delete", self.delete)
        menu.exec(e.globalPos())

    def keyPressEvent(self, e):
        pass  # Esc and friends must not close the shot

    def closeEvent(self, e):
        if getattr(self, "_deleting", False):
            self.closed.emit(self)
            e.accept()
        else:
            e.ignore()

    def delete(self):
        self._deleting = True
        self.close()

    def pick_color(self):
        c = QColorDialog.getColor(self.canvas.color, self)
        if c.isValid():
            self.canvas.color = c

    def copy_image(self):
        QGuiApplication.clipboard().setImage(self.canvas.render_image())

    def with_text(self, use):
        if self.ocr_text is None:
            QApplication.setOverrideCursor(Qt.WaitCursor)
            try:
                self.ocr_text = ocr(self.image)
            finally:
                QApplication.restoreOverrideCursor()
        use(self.ocr_text)

    def copy_text(self):
        self.with_text(QGuiApplication.clipboard().setText)

    def toggle_ocr(self):
        if self.ocr_box.isVisible():
            self.ocr_box.hide()
        else:
            self.with_text(lambda t: self.ocr_box.setPlainText(t or "(No text found)"))
            self.ocr_box.show()
        self.adjustSize()

    def save_image(self):
        from PySide6.QtWidgets import QFileDialog
        default = str(Path.home() / "Pictures" / f"FloatShot {datetime.now():%Y-%m-%d at %H.%M.%S}.png")
        path, _ = QFileDialog.getSaveFileName(self, "Save Image", default, "PNG (*.png)")
        if path:
            self.canvas.render_image().save(path)


# MARK: - Screen recording

class Recorder:
    """Grabs frames with mss on a thread and encodes them to MP4 with imageio-ffmpeg."""

    def __init__(self, rect: QRect | None):
        screen = QGuiApplication.screenAt(QCursor.pos()) or QGuiApplication.primaryScreen()
        rect = rect or screen.geometry()
        ratio = screen.devicePixelRatio()
        w, h = int(rect.width() * ratio) & ~1, int(rect.height() * ratio) & ~1  # H.264 needs even sizes
        self.box = {"left": int(rect.x() * ratio), "top": int(rect.y() * ratio), "width": w, "height": h}
        videos = Path.home() / ("Videos" if (Path.home() / "Videos").exists() else "")
        self.path = videos / f"FloatShot Recording {datetime.now():%Y-%m-%d at %H.%M.%S}.mp4"
        self.stop_flag = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self, fps=30):
        import imageio.v2 as imageio
        writer = imageio.get_writer(self.path, fps=fps, codec="libx264", quality=8, macro_block_size=2)
        with mss.mss() as sct:
            next_t = time.perf_counter()
            while not self.stop_flag.is_set():
                frame = np.asarray(sct.grab(self.box))[:, :, 2::-1]  # BGRA -> RGB
                writer.append_data(frame)
                next_t += 1 / fps
                time.sleep(max(0, next_t - time.perf_counter()))
        writer.close()

    def stop(self) -> Path:
        self.stop_flag.set()
        self.thread.join()
        return self.path


# MARK: - Open at login

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
AUTOSTART = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "autostart" / "floatshot.desktop"


def launch_command() -> str:
    # Frozen builds launch themselves; from source, run this script with the same Python.
    if getattr(sys, "frozen", False):
        return f'"{sys.executable}"'
    return f'"{sys.executable}" "{Path(__file__).resolve()}"'


def open_at_login_enabled() -> bool:
    if sys.platform == "win32":
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
                winreg.QueryValueEx(key, "FloatShot")
            return True
        except OSError:
            return False
    return AUTOSTART.exists()


def set_open_at_login(enabled: bool):
    if sys.platform == "win32":
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
            if enabled:
                winreg.SetValueEx(key, "FloatShot", 0, winreg.REG_SZ, launch_command())
            else:
                try:
                    winreg.DeleteValue(key, "FloatShot")
                except FileNotFoundError:
                    pass
    elif enabled:
        AUTOSTART.parent.mkdir(parents=True, exist_ok=True)
        AUTOSTART.write_text("[Desktop Entry]\nType=Application\nName=FloatShot\n"
                             f"Exec={launch_command()}\nX-GNOME-Autostart-enabled=true\n")
    else:
        AUTOSTART.unlink(missing_ok=True)


# MARK: - Tray app

ACTIONS = {  # id -> (title, default shortcut in Qt notation)
    "capture_region": ("Capture Region", "Ctrl+Shift+2"),
    "record_screen": ("Record Screen", ""),
    "record_region": ("Record Region", ""),
    "stop_recording": ("Stop Recording", ""),
}
settings = QSettings("FloatShot", "FloatShot")


def shortcut_for(action: str) -> str:
    return settings.value(f"shortcuts/{action}", ACTIONS[action][1])


def to_pynput(sequence: str) -> str | None:
    """'Ctrl+Shift+2' -> '<ctrl>+<shift>+2' for pynput's GlobalHotKeys."""
    if not sequence:
        return None
    names = {"ctrl": "<ctrl>", "shift": "<shift>", "alt": "<alt>", "meta": "<cmd>", "space": "<space>",
             "tab": "<tab>", "return": "<enter>", "enter": "<enter>", "esc": "<esc>", "del": "<delete>",
             "backspace": "<backspace>", "home": "<home>", "end": "<end>", "pgup": "<page_up>",
             "pgdown": "<page_down>", "ins": "<insert>", "print": "<print_screen>",
             "left": "<left>", "right": "<right>", "up": "<up>", "down": "<down>"}
    parts = []
    for part in sequence.split("+"):
        key = part.strip().lower()
        if key in names:
            parts.append(names[key])
        elif key.startswith("f") and key[1:].isdigit():
            parts.append(f"<{key}>")
        elif len(key) == 1:
            parts.append(key)
        else:
            return None
    return "+".join(parts)


class SettingsDialog(QDialog):
    """Lets the user record a key combination for each action."""

    def __init__(self, on_save):
        super().__init__(None, Qt.WindowStaysOnTopHint)
        self.setWindowTitle("FloatShot Settings")
        self.on_save = on_save
        self.edits = {}
        form = QFormLayout()
        for action, (title, _) in ACTIONS.items():
            edit = QKeySequenceEdit(QKeySequence(shortcut_for(action)))
            edit.setMaximumSequenceLength(1)
            edit.setClearButtonEnabled(True)
            self.edits[action] = edit
            form.addRow(title + ":", edit)
        hint = QLabel("Click a field and press the new key combination. Include Ctrl, Alt or Win "
                      "(or use a function key). Use the ✕ to clear.")
        hint.setWordWrap(True)
        reset = QPushButton("Restore Defaults")
        reset.clicked.connect(lambda: [e.setKeySequence(QKeySequence(ACTIONS[a][1])) for a, e in self.edits.items()])
        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.save)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel("<b>Keyboard Shortcuts</b>"))
        layout.addWidget(hint)
        layout.addLayout(form)
        layout.addWidget(reset)
        layout.addWidget(buttons)

    def save(self):
        chosen = {a: e.keySequence().toString(QKeySequence.PortableText) for a, e in self.edits.items()}
        used = [s for s in chosen.values() if s]
        if len(used) != len(set(used)):
            QMessageBox.warning(self, "FloatShot", "Two actions have the same shortcut.")
            return
        for action, seq in chosen.items():
            if seq and to_pynput(seq) is None:
                QMessageBox.warning(self, "FloatShot", f"{seq} can't be used as a global shortcut.")
                return
            if seq and not any(m in seq for m in ("Ctrl", "Alt", "Meta")) and not seq.startswith("F"):
                QMessageBox.warning(self, "FloatShot", f"{seq} needs Ctrl, Alt or Win (or a function key).")
                return
        for action, seq in chosen.items():
            settings.setValue(f"shortcuts/{action}", seq)
        self.on_save()
        self.accept()


class HotkeyBridge(QObject):
    pressed = Signal(str)


class FloatShotApp:
    def __init__(self, app: QApplication):
        self.app = app
        self.shots = set()
        self.recorder = None
        self.overlay = None
        self.hotkeys = None
        self.settings_dialog = None

        icon = QIcon(str(ASSETS / "icon.png"))
        app.setWindowIcon(icon)
        self.tray = QSystemTrayIcon(icon)
        self.tray.setToolTip("FloatShot")
        menu = QMenu()
        self.items = {"capture_region": menu.addAction("Capture Region", self.capture)}
        menu.addSeparator()
        self.items["record_screen"] = menu.addAction("Record Screen", lambda: self.start_recording(None))
        self.items["record_region"] = menu.addAction("Record Region", lambda: self.select(self.start_recording))
        self.items["stop_recording"] = menu.addAction("Stop Recording", self.stop_recording)
        self.rec_screen, self.rec_region, self.stop_action = (
            self.items["record_screen"], self.items["record_region"], self.items["stop_recording"])
        menu.addSeparator()
        login = menu.addAction("Open at Login")
        login.setCheckable(True)
        login.setChecked(open_at_login_enabled())
        login.toggled.connect(self.toggle_open_at_login)
        menu.addAction("Settings…", self.show_settings)
        menu.addSeparator()
        menu.addAction(f"FloatShot {VERSION}").setEnabled(False)
        menu.addAction("Quit FloatShot", app.quit)
        self.menu = menu
        self.tray.setContextMenu(menu)
        self.tray.show()
        self._update_recording_ui()

        # pynput's listener runs on its own thread; bounce presses to the Qt thread.
        self.bridge = HotkeyBridge()
        self.bridge.pressed.connect(self.perform)
        self.apply_shortcuts()

    def perform(self, action: str):
        if action == "capture_region":
            self.capture()
        elif self.recorder is None and action == "record_screen":
            self.start_recording(None)
        elif self.recorder is None and action == "record_region":
            self.select(self.start_recording)
        elif action == "stop_recording":
            self.stop_recording()

    def apply_shortcuts(self):
        """(Re)starts the global hotkey listener with the saved shortcuts."""
        if self.hotkeys is not None:
            self.hotkeys.stop()
            self.hotkeys = None
        mapping = {}
        for action, item in self.items.items():
            seq = shortcut_for(action)
            item.setText(ACTIONS[action][0] + (f"  ({seq})" if seq else ""))
            combo = to_pynput(seq)
            if combo:
                mapping[combo] = lambda a=action: self.bridge.pressed.emit(a)
        if not mapping:
            return
        try:
            from pynput import keyboard
            self.hotkeys = keyboard.GlobalHotKeys(mapping)
            self.hotkeys.start()
        except Exception as exc:  # e.g. Wayland without X11 access
            self.tray.showMessage("FloatShot", f"Global shortcuts unavailable ({exc}). Use the tray menu.")

    def show_settings(self):
        if self.hotkeys is not None:  # don't fire actions while the user types new combos
            self.hotkeys.stop()
            self.hotkeys = None
        self.settings_dialog = SettingsDialog(on_save=lambda: None)
        self.settings_dialog.finished.connect(lambda _: self.apply_shortcuts())
        self.settings_dialog.show()
        self.settings_dialog.raise_()
        self.settings_dialog.activateWindow()

    def select(self, then):
        if self.overlay is not None:
            return
        self.overlay = SelectionOverlay()

        def done(rect):
            self.overlay = None
            if rect is not None:
                then(rect)
        self.overlay.finished.connect(done)
        self.overlay.show()
        self.overlay.activateWindow()

    def capture(self):
        if self.recorder is None:
            self.select(self.show_shot)

    def show_shot(self, rect: QRect):
        shot = FloatingShot(grab(rect), rect.topLeft() - QPoint(0, 34))
        shot.closed.connect(self.shots.discard)
        self.shots.add(shot)
        shot.show()

    def start_recording(self, rect):
        try:
            self.recorder = Recorder(rect)
        except Exception as exc:
            QMessageBox.critical(None, "FloatShot", f"Couldn't start recording: {exc}")
            return
        self._update_recording_ui()

    def stop_recording(self):
        if self.recorder is None:
            return
        path = self.recorder.stop()
        self.recorder = None
        self._update_recording_ui()
        self.tray.showMessage("FloatShot", f"Saved {path}")

    def toggle_open_at_login(self, enabled: bool):
        try:
            set_open_at_login(enabled)
        except OSError as exc:
            QMessageBox.warning(None, "FloatShot", f"Couldn't change Open at Login: {exc}")

    def _update_recording_ui(self):
        recording = self.recorder is not None
        self.rec_screen.setEnabled(not recording)
        self.rec_region.setEnabled(not recording)
        self.stop_action.setVisible(recording)
        self.tray.setToolTip("FloatShot — recording…" if recording else "FloatShot")


def main():
    if sys.platform.startswith("linux") and os.environ.get("XDG_SESSION_TYPE") == "wayland":
        os.environ.setdefault("QT_QPA_PLATFORM", "xcb")  # overlays and grabbing need X11/XWayland
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    if not QSystemTrayIcon.isSystemTrayAvailable():
        QMessageBox.critical(None, "FloatShot", "No system tray found.")
        return 1
    _ = FloatShotApp(app)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
