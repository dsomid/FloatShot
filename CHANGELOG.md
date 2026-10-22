# Changelog

All notable changes to FloatShot. Versions follow [Semantic Versioning](https://semver.org).

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

[1.3.0]: https://github.com/dsomid/FloatShot/releases/tag/v1.3.0
[1.1.0]: https://github.com/dsomid/FloatShot/releases/tag/v1.1.0
