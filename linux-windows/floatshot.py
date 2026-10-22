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
from PySide6.QtCore import QObject, QPoint, QRect, Qt, QTimer, Signal
from PySide6.QtGui import (QAction, QColor, QCursor, QFont, QGuiApplication, QIcon, QImage,
                           QPainter, QPainterPath, QPen, QPixmap)
from PySide6.QtWidgets import (QApplication, QColorDialog, QHBoxLayout, QInputDialog,
                               QLabel, QMenu, QMessageBox, QPlainTextEdit, QSystemTrayIcon,
                               QToolButton, QVBoxLayout, QWidget)

VERSION = "1.3.0"
HOTKEY = "<ctrl>+<shift>+2"
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
            p.setPen(QPen(Qt.white, 1))
            p.drawRect(sel)
            p.drawText(sel.bottomLeft() + QPoint(4, 16), f"{sel.width()} × {sel.height()}")

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


# MARK: - Tray app

class HotkeyBridge(QObject):
    pressed = Signal()


class FloatShotApp:
    def __init__(self, app: QApplication):
        self.app = app
        self.shots = set()
        self.recorder = None
        self.overlay = None

        icon = QIcon(str(ASSETS / "icon.png"))
        app.setWindowIcon(icon)
        self.tray = QSystemTrayIcon(icon)
        self.tray.setToolTip("FloatShot")
        menu = QMenu()
        menu.addAction("Capture Region  (Ctrl+Shift+2)", self.capture)
        menu.addSeparator()
        self.rec_screen = menu.addAction("Record Screen", lambda: self.start_recording(None))
        self.rec_region = menu.addAction("Record Region", lambda: self.select(self.start_recording))
        self.stop_action = menu.addAction("Stop Recording", self.stop_recording)
        menu.addSeparator()
        menu.addAction(f"FloatShot {VERSION}").setEnabled(False)
        menu.addAction("Quit FloatShot", app.quit)
        self.menu = menu
        self.tray.setContextMenu(menu)
        self.tray.show()
        self._update_recording_ui()

        # pynput's listener runs on its own thread; bounce presses to the Qt thread.
        self.bridge = HotkeyBridge()
        self.bridge.pressed.connect(self.capture)
        try:
            from pynput import keyboard
            self.hotkeys = keyboard.GlobalHotKeys({HOTKEY: self.bridge.pressed.emit})
            self.hotkeys.start()
        except Exception as exc:  # e.g. Wayland without X11 access
            self.tray.showMessage("FloatShot", f"Global hotkey unavailable ({exc}). Use the tray menu.")

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
