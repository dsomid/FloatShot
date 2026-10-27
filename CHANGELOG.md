# Changelog

All notable changes to FloatShot. Versions follow [Semantic Versioning](https://semver.org).

## [1.8.1] - 2026-10-28

### Added
- **⌘Z / Ctrl+Z undo** on screenshots: removes the last arrow, circle, square, drawing or note, one step at a time. While typing in a note it undoes the typing instead.

## [1.8.0] - 2026-10-28

### Added
- **Arrow, Circle and Square tools** in the screenshot toolbar, next to Draw. Drag to place them; hold Shift for a perfect circle or square. They use the selected color and work with Undo.

## [1.7.1] - 2026-10-28

### Fixed
- **Re-capturing a pinned screenshot** now captures what you see, including the pinned shot, instead of what's underneath it. (macOS)
- **Resizing a screenshot** keeps its proportions, so the image always fills the window with no grey or black area; drawings and notes scale with it. (macOS)

## [1.7.0] - 2026-10-22

### Added
- **✕ delete button** on every screenshot's toolbar, alongside right-click → Delete.

### Changed
- **Red selection frame.** Dragging to capture a region now shows the same red dashed frame with corner marks as recording, with the size in a red label.

## [1.6.0] - 2026-10-22

### Added
- **Custom keyboard shortcuts.** A new *Settings…* window lets you set, change or clear a global shortcut for Capture Region, Record Screen, Record Region and Stop Recording. The menu shows each action's current shortcut, conflicts are resolved automatically, and *Restore Defaults* brings back ⇧⌘2 / Ctrl+Shift+2.
- **Open at Login.** A menu toggle that starts FloatShot automatically when you log in (macOS login item, Windows startup apps, Linux autostart).
- **Recording frame.** While recording, a red dashed frame with corner marks shows exactly what's being captured, plus a timer badge you can click to stop. Neither appears in the video. (macOS)
- **Single-file Windows EXE** (`FloatShot-windows-x64.exe`): download and double-click, nothing to unzip or install.

## [1.3.0] - 2026-10-22

### Added
- **Screen recording** from the menu bar: *Record Screen* (the screen under the mouse) and *Record Region* (drag to select). The menu-bar icon turns into a red dot while recording; *Stop Recording* saves a `.mov` to your Movies folder and shows it in Finder.
- **Linux and Windows version** (Python + Qt) with region capture (Ctrl+Shift+2), floating annotatable shots, OCR via Tesseract, a right-click menu (Copy Image, Copy Text from Image, Save Image, Delete), and screen/region recording to MP4.
- Automated Linux and Windows builds attached to each GitHub release.

## 1.2.0 - 2026-10-22

### Added
- **Copy Image** in the right-click menu, which copies the shot together with your drawings and notes.

## [1.1.0] - 2026-10-22

First public release.

### Added
- ⇧⌘2 region capture into a floating, always-on-top window that stays on every Space.
- Draw or type notes on shots, with color picker and undo.
- OCR text extraction with Apple's Vision framework, shown in a side panel.
- Right-click menu: Copy Text from Image, AirDrop Text from Image, AirDrop Image, Delete. Delete is the only way a shot is removed.
- App icon, version shown in the menu bar, and install via Homebrew (`dsomid/tap/floatshot`).

[1.8.1]: https://github.com/dsomid/FloatShot/releases/tag/v1.8.1
[1.8.0]: https://github.com/dsomid/FloatShot/releases/tag/v1.8.0
[1.7.1]: https://github.com/dsomid/FloatShot/releases/tag/v1.7.1
[1.7.0]: https://github.com/dsomid/FloatShot/releases/tag/v1.7.0
[1.6.0]: https://github.com/dsomid/FloatShot/releases/tag/v1.6.0
[1.3.0]: https://github.com/dsomid/FloatShot/releases/tag/v1.3.0
[1.1.0]: https://github.com/dsomid/FloatShot/releases/tag/v1.1.0
