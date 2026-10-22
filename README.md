# FloatShot

A tiny macOS menu-bar app for floating screenshots. Press **⇧⌘2**, drag over any part of the screen, and the capture stays pinned on top of every window and Space, ready to annotate, read, or share.

## Features

- **Global hotkey** ⇧⌘2 for region capture (Esc or right-click cancels the selection)
- **Floating shots** that stay above all apps and on every desktop, without stealing focus
- **Annotate** by drawing or typing notes in any color, with undo
- **OCR** with Apple's Vision framework: show the text in a side panel or copy it in one click
- **Right-click menu** on any shot:
  - Copy Text from Image (Universal Clipboard makes it pasteable on your other Apple devices)
  - AirDrop Text from Image (sent as a `.txt` file)
  - AirDrop Image (includes your annotations)
  - Delete, which is the only way a shot is removed

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel)
- Screen Recording permission: System Settings → Privacy & Security → Screen & System Audio Recording

## Install

With [Homebrew](https://brew.sh):

```bash
brew install --cask dsomid/tap/floatshot
```

Or download the DMG from [Releases](../../releases), open it, and drag FloatShot to Applications.

FloatShot isn't notarized by Apple, so macOS blocks the first launch. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. (On macOS 14 you can instead right-click the app and choose **Open**.) After granting Screen Recording permission, quit FloatShot from the menu bar and open it again.

To update or remove it later:

```bash
brew upgrade --cask floatshot
brew uninstall --cask floatshot
```

## Build from source

Needs the Xcode command line tools.

```bash
./build.sh
```

This produces `build/FloatShot.app` (universal) and `build/FloatShot-<version>.dmg`. The version comes from `CFBundleShortVersionString` in `Info.plist`.

If a code-signing identity named `FloatShot Local Signing` is in your keychain, the build uses it, which keeps the Screen Recording permission across rebuilds. Otherwise it signs ad-hoc.

To redraw the icon after editing `make_icon.swift`:

```bash
swift make_icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
```

## Project layout

| File | Purpose |
| --- | --- |
| `Sources/main.swift` | The whole app: hotkey, selection overlay, ScreenCaptureKit capture, floating panel, annotation, OCR, sharing |
| `Info.plist` | Bundle metadata and version |
| `build.sh` | Compiles, signs, and packages the DMG |
| `make_icon.swift` / `AppIcon.icns` | App icon generator and output |
