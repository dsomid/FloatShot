import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers
import Vision

// MARK: - App entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlays: [SelectionWindow] = []
    var panels: [FloatingPanel] = []
    private var recorder: ScreenRecorder?
    private var recordingIndicator: RecordingIndicator?
    private var actionItems: [HotkeyAction: NSMenuItem] = [:]
    private var loginItem: NSMenuItem!
    private var settingsWindow: SettingsWindowController?
    private let hotkeys = HotkeyCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ action: HotkeyAction, _ selector: Selector) {
            actionItems[action] = menu.addItem(withTitle: action.title, action: selector, keyEquivalent: "")
        }
        add(.captureRegion, #selector(startCapture))
        menu.addItem(.separator())
        add(.recordScreen, #selector(recordScreen))
        add(.recordRegion, #selector(recordRegion))
        add(.stopRecording, #selector(stopRecording))
        menu.addItem(.separator())
        loginItem = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = menu.addItem(withTitle: "FloatShot \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(withTitle: "Quit FloatShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
        updateRecordingUI()

        hotkeys.onPress = { [weak self] action in self?.perform(action) }
        applyShortcuts()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .captureRegion: startCapture()
        case .recordScreen: recordScreen()
        case .recordRegion: recordRegion()
        case .stopRecording: stopRecording()
        }
    }

    /// Registers the saved shortcuts and shows them next to the menu items.
    /// Returns the actions whose shortcut macOS refused (already taken by something else).
    @discardableResult
    func applyShortcuts() -> [HotkeyAction] {
        let failed = hotkeys.register(ShortcutStore.all())
        for (action, item) in actionItems {
            let shortcut = ShortcutStore.shortcut(for: action)
            item.keyEquivalent = shortcut?.menuKey ?? ""
            item.keyEquivalentModifierMask = shortcut?.modifierFlags ?? []
        }
        return failed
    }

    func suspendShortcuts(_ suspended: Bool) {
        if suspended { hotkeys.unregisterAll() } else { applyShortcuts() }
    }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func hasPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Enable FloatShot in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch FloatShot."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        return false
    }

    // Shows the drag-to-select overlay on every screen and reports the chosen rect.
    private func selectRegion(_ completion: @escaping (CGRect, NSScreen) -> Void) {
        guard overlays.isEmpty, hasPermission() else { return }
        overlays = NSScreen.screens.map { screen in
            let w = SelectionWindow(screen: screen)
            w.onFinish = { [weak self] rect in
                guard let self else { return }
                self.overlays.forEach { $0.orderOut(nil) }
                self.overlays.removeAll()
                NSCursor.pop()
                guard let rect, rect.width > 3, rect.height > 3 else { return }
                // Give the window server a beat to remove the overlays.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { completion(rect, screen) }
            }
            w.makeKeyAndOrderFront(nil)
            return w
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    @objc func startCapture() {
        guard recorder == nil else { return }
        selectRegion { rect, screen in Task { await self.capture(rect: rect, screen: screen) } }
    }

    @MainActor
    private func capture(rect: CGRect, screen: NSScreen) async {
        do {
            let image = try await ScreenCapturer.capture(globalRect: rect, on: screen)
            let panel = FloatingPanel(image: image, scale: screen.backingScaleFactor, origin: rect.origin)
            panel.onClose = { [weak self, weak panel] in self?.panels.removeAll { $0 === panel } }
            panels.append(panel)
            panel.orderFrontRegardless()
            panel.makeKey()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: Recording

    @objc private func recordScreen() {
        guard recorder == nil, hasPermission() else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        startRecording(rect: nil, screen: screen)
    }

    @objc private func recordRegion() {
        guard recorder == nil else { return }
        selectRegion { rect, screen in self.startRecording(rect: rect, screen: screen) }
    }

    private func startRecording(rect: CGRect?, screen: NSScreen) {
        let recorder = ScreenRecorder()
        self.recorder = recorder
        updateRecordingUI()
        let indicator = RecordingIndicator(region: rect ?? screen.frame, fullScreen: rect == nil, screen: screen)
        indicator.onStop = { [weak self] in self?.stopRecording() }
        recordingIndicator = indicator
        Task { @MainActor in
            do {
                try await recorder.start(globalRect: rect, on: screen, excluding: indicator.windowNumbers)
                indicator.startTimer()
            } catch {
                self.recorder = nil
                self.recordingIndicator?.close()
                self.recordingIndicator = nil
                self.updateRecordingUI()
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func stopRecording() {
        guard let recorder else { return }
        self.recorder = nil
        recordingIndicator?.close()
        recordingIndicator = nil
        updateRecordingUI()
        Task { @MainActor in
            do {
                let url = try await recorder.stop()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // Registers FloatShot as a login item, shown in System Settings → General → Login Items.
    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        loginItem.state = service.status == .enabled ? .on : .off
    }

    private func updateRecordingUI() {
        let recording = recorder != nil
        actionItems[.recordScreen]?.isEnabled = !recording
        actionItems[.recordRegion]?.isEnabled = !recording
        actionItems[.stopRecording]?.isHidden = !recording
        let symbol = recording ? "record.circle.fill" : "camera.viewfinder"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FloatShot")
        image?.isTemplate = !recording
        statusItem.button?.image = recording
            ? image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            : image
    }
}

// MARK: - Shortcuts

enum HotkeyAction: String, CaseIterable {
    case captureRegion, recordScreen, recordRegion, stopRecording

    var title: String {
        switch self {
        case .captureRegion: return "Capture Region"
        case .recordScreen: return "Record Screen"
        case .recordRegion: return "Record Region"
        case .stopRecording: return "Stop Recording"
        }
    }

    var defaultShortcut: Shortcut? {
        self == .captureRegion ? Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), key: "2") : nil
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask
    var key: String       // what the key types, for display

    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    /// Builds a shortcut from a key press. Needs ⌘, ⌃ or ⌥ unless it's a function key,
    /// so plain typing never gets hijacked.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        let code = Int(event.keyCode)
        let isFunctionKey = Shortcut.namedKeys[code]?.hasPrefix("F") == true
        guard isFunctionKey || mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        let typed = Shortcut.namedKeys[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        self.init(keyCode: UInt32(code), modifiers: mods, key: typed)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    // Menus can only show single-character keys; named keys are left off the menu.
    var menuKey: String { key.count == 1 ? key.lowercased() : "" }
}

/// Saved shortcuts in UserDefaults. A missing entry means "use the default";
/// an explicitly cleared one is stored as an empty value.
enum ShortcutStore {
    private static func defaultsKey(_ action: HotkeyAction) -> String { "shortcut.\(action.rawValue)" }

    static func shortcut(for action: HotkeyAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(action)) else { return action.defaultShortcut }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func set(_ shortcut: Shortcut?, for action: HotkeyAction) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: defaultsKey(action))
    }

    static func resetAll() {
        HotkeyAction.allCases.forEach { UserDefaults.standard.removeObject(forKey: defaultsKey($0)) }
    }

    static func all() -> [HotkeyAction: Shortcut] {
        var result: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases { result[action] = shortcut(for: action) }
        return result
    }
}

/// Global hotkeys via Carbon: they work without Accessibility permission and consume the keystroke.
final class HotkeyCenter {
    var onPress: ((HotkeyAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    @discardableResult
    func register(_ shortcuts: [HotkeyAction: Shortcut]) -> [HotkeyAction] {
        installHandler()
        unregisterAll()
        var failed: [HotkeyAction] = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let s = shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x464C5348), id: UInt32(index)) // 'FLSH'
            if RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            } else {
                failed.append(action)
            }
        }
        return failed
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotkeyCenter>.fromOpaque(userData!).takeUnretainedValue()
            let actions = HotkeyAction.allCases
            if Int(id.id) < actions.count {
                DispatchQueue.main.async { me.onPress?(actions[Int(id.id)]) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var app: AppDelegate?
    private var fields: [HotkeyAction: ShortcutField] = [:]
    private let status = NSTextField(labelWithString: "")

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FloatShot Settings"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        let header = NSTextField(labelWithString: "Keyboard Shortcuts")
        header.font = .boldSystemFont(ofSize: 13)
        let hint = NSTextField(wrappingLabelWithString: "Click a shortcut, then press the new key combination. Use ⌘, ⌃ or ⌥ (or a function key). Press ⌫ to clear, Esc to cancel.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        for action in HotkeyAction.allCases {
            let field = ShortcutField(shortcut: ShortcutStore.shortcut(for: action))
            field.onRecordingChanged = { [weak self] recording in self?.app?.suspendShortcuts(recording) }
            field.onChange = { [weak self] shortcut in self?.update(action, to: shortcut) }
            fields[action] = field
            let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")!,
                                 target: field, action: #selector(ShortcutField.clear))
            clear.isBordered = false
            clear.contentTintColor = .tertiaryLabelColor
            clear.toolTip = "Remove shortcut"
            grid.addRow(with: [NSTextField(labelWithString: action.title + ":"), field, clear])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 180

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .systemRed

        let stack = NSStackView(views: [header, hint, grid, status, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        hint.preferredMaxLayoutWidth = 400
        window?.contentView = stack
        window?.setContentSize(stack.fittingSize)
    }

    private func update(_ action: HotkeyAction, to shortcut: Shortcut?) {
        // One combination can only belong to one action.
        if let shortcut {
            for other in HotkeyAction.allCases where other != action && ShortcutStore.shortcut(for: other) == shortcut {
                ShortcutStore.set(nil, for: other)
                fields[other]?.shortcut = nil
            }
        }
        ShortcutStore.set(shortcut, for: action)
        refresh()
    }

    private func refresh() {
        let failed = app?.applyShortcuts() ?? []
        status.stringValue = failed.isEmpty ? ""
            : "Already used by macOS or another app: " + failed.map(\.title).joined(separator: ", ")
        window?.setContentSize(window?.contentView?.fittingSize ?? .zero)
    }

    @objc private func restoreDefaults() {
        ShortcutStore.resetAll()
        for (action, field) in fields { field.shortcut = ShortcutStore.shortcut(for: action) }
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        fields.values.forEach { $0.stopRecording() }
    }
}

/// A button that records the next key combination pressed while it's focused.
final class ShortcutField: NSButton {
    var onChange: ((Shortcut?) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var shortcut: Shortcut? { didSet { updateTitle() } }
    private var recording = false { didSet { updateTitle(); onRecordingChanged?(recording) } }

    init(shortcut: Shortcut?) {
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private func updateTitle() {
        title = recording ? "Type shortcut…" : (shortcut?.display ?? "None")
    }

    @objc private func beginRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    func stopRecording() {
        if recording { recording = false }
    }

    @objc func clear() {
        stopRecording()
        shortcut = nil
        onChange?(nil)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    // ⌘-combinations arrive here rather than in keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain && event.keyCode == UInt16(kVK_Escape) { stopRecording(); return }
        if plain && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) { clear(); return }
        guard let s = Shortcut(event: event) else { NSSound.beep(); return }
        shortcut = s
        stopRecording()
        onChange?(s)
    }
}

// MARK: - Region selection overlay

final class SelectionWindow: NSWindow {
    var onFinish: ((CGRect?) -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] localRect in
            guard let self else { return }
            // Convert from window-local to global screen coordinates.
            self.onFinish?(localRect.map { $0.offsetBy(dx: self.frame.minX, dy: self.frame.minY) })
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    var selection: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y)).integral
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); onFinish?(selection) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onFinish?(nil) } else { super.keyDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard let sel = selection else { return }
        NSColor.clear.setFill()
        sel.fill(using: .copy)
        // Same red frame as recording, drawn just outside the area being captured.
        RecordingFrameView.drawFrame(in: sel.insetBy(dx: -3, dy: -3))
        let label = " \(Int(sel.width)) × \(Int(sel.height)) " as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.white, .backgroundColor: NSColor.systemRed]
        label.draw(at: NSPoint(x: sel.minX, y: max(sel.minY - 22, 2)), withAttributes: attrs)
    }
}

// MARK: - Screen capture

enum ScreenCapturer {
    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "Could not find the display to capture." }
    }

    static func capture(globalRect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        // Capture exactly what's on screen, including pinned screenshots, so a shot can be re-captured.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // sourceRect is in display points with a top-left origin.
        let local = globalRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let flipped = CGRect(x: local.minX, y: screen.frame.height - local.maxY, width: local.width, height: local.height)
        let scale = screen.backingScaleFactor

        let config = SCStreamConfiguration()
        config.sourceRect = flipped
        config.width = Int(flipped.width * scale)
        config.height = Int(flipped.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

// MARK: - Screen recording

final class ScreenRecorder: NSObject, SCStreamOutput {
    enum RecordError: LocalizedError {
        case noDisplay, noFrames
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "Could not find the display to record."
            case .noFrames: return "The recording didn't capture any frames."
            }
        }
    }

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private let queue = DispatchQueue(label: "FloatShot.recorder")
    private(set) var url: URL!

    // Records the whole screen when globalRect is nil, otherwise just that region.
    func start(globalRect: CGRect?, on screen: NSScreen, excluding windowNumbers: [Int] = []) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw RecordError.noDisplay }
        // Keep the recording frame and badge out of the video.
        let hidden = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: hidden)

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        var size = screen.frame.size
        if let rect = globalRect {
            let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            config.sourceRect = CGRect(x: local.minX, y: screen.frame.height - local.maxY, width: local.width, height: local.height)
            size = rect.size
        }
        // H.264 needs even dimensions.
        let width = Int(size.width * scale) & ~1, height = Int(size.height * scale) & ~1
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.queueDepth = 6

        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        url = movies.appendingPathComponent("FloatShot Recording \(stamp.string(from: Date())).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws -> URL {
        try? await stream?.stopCapture()
        stream = nil
        guard let writer, let input else { throw RecordError.noFrames }
        // Drain any frames still being appended on the capture queue.
        let started = queue.sync { sessionStarted }
        guard started else { writer.cancelWriting(); throw RecordError.noFrames }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, let writer, let input else { return }
        // Skip idle/blank frames; only complete frames carry new pixels.
        guard let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }
}

// MARK: - Recording indicator

/// A red frame with corner marks around what's being recorded, plus a badge
/// showing elapsed time that stops the recording when clicked.
final class RecordingIndicator {
    var onStop: (() -> Void)?
    private let frameWindow: NSWindow
    private let badgeWindow: NSPanel
    private let timeLabel = NSTextField(labelWithString: "REC 0:00")
    private var timer: Timer?
    private var started = Date()

    var windowNumbers: [Int] { [frameWindow.windowNumber, badgeWindow.windowNumber] }

    init(region: CGRect, fullScreen: Bool, screen: NSScreen) {
        // A region frame sits just outside the area so it never covers recorded pixels.
        let pad: CGFloat = 4
        let frameRect = fullScreen ? screen.frame : region.insetBy(dx: -pad, dy: -pad)
        frameWindow = NSWindow(contentRect: frameRect, styleMask: .borderless, backing: .buffered, defer: false)
        frameWindow.isOpaque = false
        frameWindow.backgroundColor = .clear
        frameWindow.ignoresMouseEvents = true
        frameWindow.hasShadow = false
        frameWindow.level = .screenSaver
        frameWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        frameWindow.contentView = RecordingFrameView(frame: NSRect(origin: .zero, size: frameRect.size))
        frameWindow.orderFrontRegardless()

        // Badge: above the region's top-right corner, or inside it when there's no room.
        let size = NSSize(width: 118, height: 28)
        var origin = NSPoint(x: frameRect.maxX - size.width, y: frameRect.maxY + 6)
        if fullScreen || origin.y + size.height > screen.visibleFrame.maxY {
            origin = NSPoint(x: frameRect.maxX - size.width - 12, y: min(frameRect.maxY, screen.visibleFrame.maxY) - size.height - 12)
        }
        origin.x = max(origin.x, screen.frame.minX + 8)
        badgeWindow = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        badgeWindow.isOpaque = false
        badgeWindow.backgroundColor = .clear
        badgeWindow.level = .screenSaver
        badgeWindow.hidesOnDeactivate = false
        badgeWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let badge = NSButton(title: "", target: nil, action: nil)
        badge.isBordered = false
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = size.height / 2
        badge.frame = NSRect(origin: .zero, size: size)
        badge.toolTip = "Click to stop recording"
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.alignment = .center
        timeLabel.frame = NSRect(x: 0, y: 6, width: size.width, height: 16)
        badge.addSubview(timeLabel)
        badgeWindow.contentView = badge
        badgeWindow.orderFrontRegardless()

        badge.target = self
        badge.action = #selector(stopClicked)
    }

    func startTimer() {
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() {
        let s = Int(Date().timeIntervalSince(started))
        timeLabel.stringValue = String(format: "■  REC %d:%02d", s / 60, s % 60)
    }

    @objc private func stopClicked() { onStop?() }

    func close() {
        timer?.invalidate()
        frameWindow.orderOut(nil)
        badgeWindow.orderOut(nil)
    }
}

final class RecordingFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Self.drawFrame(in: bounds.insetBy(dx: 1.5, dy: 1.5))
    }

    /// Red dashed outline with solid corner marks, shared by region selection and recording.
    static func drawFrame(in r: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.85).setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 3
        border.setLineDash([10, 6], count: 2, phase: 0)
        border.stroke()

        // Solid corner marks so the edges are easy to spot.
        let len = min(28, r.width / 3, r.height / 3)
        let corners = NSBezierPath()
        corners.lineWidth = 5
        corners.lineCapStyle = .round
        for (p, dx, dy) in [(NSPoint(x: r.minX, y: r.minY), 1.0, 1.0), (NSPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                            (NSPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (NSPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            corners.move(to: NSPoint(x: p.x + len * dx, y: p.y))
            corners.line(to: p)
            corners.line(to: NSPoint(x: p.x, y: p.y + len * dy))
        }
        NSColor.systemRed.setStroke()
        corners.stroke()
    }
}

// MARK: - OCR

enum OCR {
    static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            let text = error.map { "OCR failed: \($0.localizedDescription)" } ?? lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        DispatchQueue.global(qos: .userInitiated).async {
            do { try VNImageRequestHandler(cgImage: image).perform([request]) }
            catch { DispatchQueue.main.async { completion("OCR failed: \(error.localizedDescription)") } }
        }
    }
}

// MARK: - Floating panel

final class FloatingPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let shotView: ShotView
    private let ocrScroll = NSScrollView()
    private let ocrText = NSTextView()
    private let image: CGImage
    private var ocrResult: String?
    private let toolbarHeight: CGFloat = 34
    private let ocrWidth: CGFloat = 260
    private var imageSize: NSSize
    private static let minImageWidth: CGFloat = 440

    init(image: CGImage, scale: CGFloat, origin: CGPoint) {
        self.image = image
        let natural = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        // Small captures are shown a little larger so the toolbar fits; the aspect ratio never changes.
        let grow = max(1, FloatingPanel.minImageWidth / natural.width)
        let size = NSSize(width: natural.width * grow, height: natural.height * grow)
        imageSize = size
        shotView = ShotView(image: NSImage(cgImage: image, size: natural))

        let frame = NSRect(x: origin.x, y: origin.y - toolbarHeight, width: size.width, height: size.height + toolbarHeight)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hasShadow = true
        backgroundColor = .windowBackgroundColor
        isReleasedWhenClosed = false
        delegate = self
        buildUI()
    }

    override var canBecomeKey: Bool { true }

    // ⌘Z removes the last drawing, shape or note. While typing in a note, ⌘Z undoes typing instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let editingNote = firstResponder is NSText
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "z", !editingNote {
            shotView.undo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Resizing keeps the screenshot's proportions so it always fills the window.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let side = ocrScroll.isHidden ? 0 : ocrWidth
        let imageWidth = max(frameSize.width - side, FloatingPanel.minImageWidth)
        let aspect = shotView.imageAspect
        return NSSize(width: imageWidth + side, height: (imageWidth / aspect).rounded() + toolbarHeight)
    }

    // The only way a shot goes away is "Delete" from the right-click menu.
    private var allowClose = false

    override func sendEvent(_ event: NSEvent) {
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if isContextClick, let view = contentView {
            NSMenu.popUpContextMenu(contextMenu(), with: event, for: view)
            return
        }
        super.sendEvent(event)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let items: [(String, String, Selector)] = [
            ("Copy Image", "doc.on.doc", #selector(copyImage)),
            ("Copy Text from Image", "doc.on.clipboard", #selector(copyTextFromImage)),
            ("AirDrop Text from Image", "text.bubble", #selector(airDropText)),
            ("AirDrop Image", "photo", #selector(sendViaAirDrop)),
            ("Save Image…", "square.and.arrow.down", #selector(saveImage)),
        ]
        for (title, symbol, action) in items {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        let delete = menu.addItem(withTitle: "Delete", action: #selector(deleteShot), keyEquivalent: "")
        delete.target = self
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return menu
    }

    @objc func deleteShot() {
        allowClose = true
        close()
    }

    override func close() {
        guard allowClose else { return }
        super.close()
        onClose?()
    }
    override func performClose(_ sender: Any?) {}
    override func cancelOperation(_ sender: Any?) {} // Esc must not dismiss
    override func orderOut(_ sender: Any?) { if allowClose { super.orderOut(sender) } }
    override func miniaturize(_ sender: Any?) {}

    private func withRecognizedText(_ use: @escaping (String) -> Void) {
        if let ocrResult { use(ocrResult); return }
        OCR.recognize(image) { [weak self] text in
            self?.ocrResult = text
            use(text)
        }
    }

    @objc private func copyTextFromImage() {
        withRecognizedText { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc private func airDropText() {
        withRecognizedText { text in
            // AirDrop rejects bare strings, so send the text as a .txt file.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("FloatShot Text \(Int(Date().timeIntervalSince1970)).txt")
            guard !text.isEmpty, (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil,
                  let service = NSSharingService(named: .sendViaAirDrop) else { NSSound.beep(); return }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: [url])
        }
    }

    @objc private func sendViaAirDrop() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatShot \(Int(Date().timeIntervalSince1970)).png")
        guard let png = annotatedImage()?.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil,
              let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    @objc private func saveImage() {
        guard let png = annotatedImage()?.representation(using: .png, properties: [:]) else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = "FloatShot \(stamp.string(from: Date())).png"
        save.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        save.level = .floating + 1
        NSApp.activate(ignoringOtherApps: true)
        if save.runModal() == .OK, let url = save.url {
            do { try png.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
    }

    private func annotatedImage() -> NSBitmapImageRep? {
        guard let rep = shotView.bitmapImageRepForCachingDisplay(in: shotView.bounds) else { return nil }
        shotView.cacheDisplay(in: shotView.bounds, to: rep)
        return rep
    }

    private func buildUI() {
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.autoresizingMask = [.width, .height]

        shotView.frame = NSRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
        shotView.autoresizingMask = [.width, .height]
        root.addSubview(shotView)

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.frame = NSRect(x: 0, y: imageSize.height, width: imageSize.width, height: toolbarHeight)
        bar.autoresizingMask = [.width, .minYMargin]

        let modes = NSSegmentedControl(images: [
            NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Move")!,
            NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: "Draw")!,
            NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Highlight")!,
            NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Arrow")!,
            NSImage(systemSymbolName: "circle", accessibilityDescription: "Circle")!,
            NSImage(systemSymbolName: "square", accessibilityDescription: "Square")!,
            NSImage(systemSymbolName: "checkerboard.rectangle", accessibilityDescription: "Blur")!,
            NSImage(systemSymbolName: "textformat", accessibilityDescription: "Text")!,
        ], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modes.selectedSegment = 0
        modes.setToolTip("Move window", forSegment: 0)
        modes.setToolTip("Draw", forSegment: 1)
        modes.setToolTip("Highlighter", forSegment: 2)
        modes.setToolTip("Arrow (drag from tail to tip)", forSegment: 3)
        modes.setToolTip("Circle (drag to size)", forSegment: 4)
        modes.setToolTip("Square (drag to size)", forSegment: 5)
        modes.setToolTip("Blur (drag over what to hide)", forSegment: 6)
        modes.setToolTip("Type a note (click to place)", forSegment: 7)
        modes.controlSize = .small

        let color = NSColorWell(style: .minimal)
        color.color = .systemRed
        color.target = self
        color.action = #selector(colorChanged(_:))

        bar.addArrangedSubview(modes)
        bar.addArrangedSubview(color)
        bar.addArrangedSubview(button("arrow.uturn.backward", "Undo (⌘Z)", #selector(undo)))
        bar.addArrangedSubview(NSView()) // spacer
        bar.addArrangedSubview(button("text.viewfinder", "Extract text (OCR)", #selector(toggleOCR)))
        bar.addArrangedSubview(button("doc.on.doc", "Copy image with notes", #selector(copyImage)))
        let close = button("xmark.circle.fill", "Delete this screenshot", #selector(deleteShot))
        close.contentTintColor = .systemRed
        bar.addArrangedSubview(close)
        root.addSubview(bar)

        ocrText.isEditable = true
        ocrText.font = .systemFont(ofSize: 12)
        ocrText.textContainerInset = NSSize(width: 6, height: 6)
        ocrText.isVerticallyResizable = true
        ocrText.autoresizingMask = [.width]
        ocrScroll.documentView = ocrText
        ocrScroll.hasVerticalScroller = true
        ocrScroll.isHidden = true
        // Give the hidden panel a real height; at zero, autoresizing can't shrink it and blocks
        // the window from getting shorter.
        ocrScroll.frame = NSRect(x: imageSize.width, y: 0, width: ocrWidth, height: imageSize.height + toolbarHeight)
        ocrScroll.autoresizingMask = [.minXMargin, .height]
        root.addSubview(ocrScroll)

        contentView = root
        shotView.window?.makeFirstResponder(shotView)
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.toolTip = tip
        return b
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        shotView.mode = [.move, .draw, .highlight, .arrow, .oval, .rectangle, .blur, .text][sender.selectedSegment]
    }
    @objc private func colorChanged(_ sender: NSColorWell) { shotView.inkColor = sender.color }
    @objc private func undo() { shotView.undo() }

    @objc private func copyImage() {
        guard let rep = annotatedImage() else { return }
        let img = NSImage(size: shotView.bounds.size)
        img.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    @objc private func toggleOCR() {
        let showing = !ocrScroll.isHidden
        var f = frame
        if showing {
            ocrScroll.isHidden = true
            f.size.width -= ocrWidth
            setFrame(f, display: true, animate: true)
            return
        }
        f.size.width += ocrWidth
        // Keep the image where it is; grow to the right.
        setFrame(f, display: true, animate: true)
        shotView.frame.size.width = f.width - ocrWidth
        ocrScroll.frame = NSRect(x: f.width - ocrWidth, y: 0, width: ocrWidth, height: f.height)
        ocrScroll.isHidden = false
        ocrText.frame = NSRect(origin: .zero, size: ocrScroll.contentSize)
        if let ocrResult {
            ocrText.string = ocrResult
        } else {
            ocrText.string = "Recognizing text…"
            OCR.recognize(image) { [weak self] text in
                self?.ocrResult = text
                self?.ocrText.string = text.isEmpty ? "(No text found)" : text
            }
        }
    }
}

// MARK: - Image + annotation view

final class ShotView: NSView {
    enum Mode { case move, draw, highlight, arrow, oval, rectangle, blur, text }
    private enum Item { case stroke(NSBezierPath, NSColor), blur(NSRect), note(NSTextField) }
    private static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.4)

    var mode: Mode = .move { didSet { window?.invalidateCursorRects(for: self) } }
    var inkColor: NSColor = .systemRed
    private let image: NSImage
    private var items: [Item] = []
    private var currentPath: NSBezierPath?
    private var shapeStart: NSPoint?
    private var currentColor: NSColor { mode == .highlight ? Self.highlightColor : inkColor }

    // A low-resolution copy of the screenshot; drawn without smoothing it looks pixelated.
    private lazy var pixelated: NSImage = {
        let block: CGFloat = 12
        let small = NSSize(width: max(1, (image.size.width / block).rounded()), height: max(1, (image.size.height / block).rounded()))
        let out = NSImage(size: small)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: small))
        out.unlockFocus()
        return out
    }()

    // Arrow, circle or square between two points. Shift makes a perfect circle/square.
    private func shapePath(from a: NSPoint, to b: NSPoint, shift: Bool) -> NSBezierPath {
        let path: NSBezierPath
        switch mode {
        case .arrow:
            path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = min(18, hypot(b.x - a.x, b.y - a.y) / 2)
            for side in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
                path.move(to: b)
                path.line(to: NSPoint(x: b.x + head * cos(angle + side), y: b.y + head * sin(angle + side)))
            }
        default:
            var w = b.x - a.x, h = b.y - a.y
            if shift { let side = max(abs(w), abs(h)); w = copysign(side, w); h = copysign(side, h) }
            let rect = NSRect(x: min(a.x, a.x + w), y: min(a.y, a.y + h), width: abs(w), height: abs(h))
            path = mode == .oval ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
        }
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    var imageAspect: CGFloat { image.size.width / image.size.height }

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    // The view always works in the image's own coordinates, so when the window is resized
    // the screenshot, drawings and notes all scale together.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setBoundsSize(image.size)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        switch mode {
        case .move: addCursorRect(bounds, cursor: .openHand)
        case .draw, .highlight, .arrow, .oval, .rectangle, .blur: addCursorRect(bounds, cursor: .crosshair)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        // Blurred areas show a coarse pixelated copy of the screenshot, clipped to each rect.
        for case let .blur(rect) in items {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            NSGraphicsContext.current?.imageInterpolation = .none
            pixelated.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        for case let .stroke(path, color) in items { color.setStroke(); path.stroke() }
        if let currentPath {
            if mode == .blur {
                NSColor.secondaryLabelColor.setStroke()
                currentPath.setLineDash([6, 4], count: 2, phase: 0)
                currentPath.lineWidth = 1.5
            } else {
                currentColor.setStroke()
            }
            currentPath.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .move:
            window?.performDrag(with: event)
        case .draw, .highlight:
            let path = NSBezierPath()
            path.lineWidth = mode == .highlight ? 18 : 3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: p)
            currentPath = path
        case .arrow, .oval, .rectangle, .blur:
            shapeStart = p
            currentPath = nil
        case .text:
            addNote(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if mode == .draw || mode == .highlight, let path = currentPath {
            path.line(to: p)
        } else if mode == .blur, let start = shapeStart {
            currentPath = NSBezierPath(rect: NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)))
        } else if let start = shapeStart {
            currentPath = shapePath(from: start, to: p, shift: event.modifierFlags.contains(.shift))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        shapeStart = nil
        guard mode != .move, mode != .text, let path = currentPath else { return }
        items.append(mode == .blur ? .blur(path.bounds) : .stroke(path, currentColor))
        currentPath = nil
        needsDisplay = true
    }

    private func addNote(at p: NSPoint) {
        window?.makeKey()
        let field = NSTextField(string: "")
        field.placeholderString = "Type a note…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .boldSystemFont(ofSize: 16)
        field.textColor = inkColor
        field.frame = NSRect(x: p.x, y: p.y - 12, width: max(bounds.width - p.x, 80), height: 24)
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)
        window?.makeFirstResponder(field)
        items.append(.note(field))
    }

    func undo() {
        guard let last = items.popLast() else { return }
        if case let .note(field) = last { field.removeFromSuperview() }
        needsDisplay = true
    }
}
