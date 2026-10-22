import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
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
    private var hotKeyRef: EventHotKeyRef?
    private var overlays: [SelectionWindow] = []
    var panels: [FloatingPanel] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "FloatShot")
        let menu = NSMenu()
        menu.addItem(withTitle: "Capture Region  (⇧⌘2)", action: #selector(startCapture), keyEquivalent: "")
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = menu.addItem(withTitle: "FloatShot \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(withTitle: "Quit FloatShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu

        registerHotKey()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    // Carbon hotkeys work globally without Accessibility permission and consume the keystroke.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { me.startCapture() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x464C5348), id: 1) // 'FLSH'
        RegisterEventHotKey(UInt32(kVK_ANSI_2), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func startCapture() {
        guard overlays.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "Screen Recording permission needed"
            alert.informativeText = "Enable FloatShot in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch FloatShot."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        overlays = NSScreen.screens.map { screen in
            let w = SelectionWindow(screen: screen)
            w.onFinish = { [weak self] rect in self?.finishSelection(rect: rect, screen: screen) }
            w.makeKeyAndOrderFront(nil)
            return w
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    private func finishSelection(rect: CGRect?, screen: NSScreen) {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        NSCursor.pop()
        guard let rect, rect.width > 3, rect.height > 3 else { return }
        // Give the window server a beat to remove the overlays before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { await self.capture(rect: rect, screen: screen) }
        }
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
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        path.stroke()
        let label = "\(Int(sel.width)) × \(Int(sel.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        label.draw(at: NSPoint(x: sel.minX + 4, y: max(sel.minY - 16, 2)), withAttributes: attrs)
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
        // Exclude our own windows (other floating shots) from the capture.
        let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])

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

final class FloatingPanel: NSPanel {
    var onClose: (() -> Void)?
    private let shotView: ShotView
    private let ocrScroll = NSScrollView()
    private let ocrText = NSTextView()
    private let image: CGImage
    private var ocrResult: String?
    private let toolbarHeight: CGFloat = 34
    private let ocrWidth: CGFloat = 260
    private var imageSize: NSSize

    init(image: CGImage, scale: CGFloat, origin: CGPoint) {
        self.image = image
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        size.width = max(size.width, 300) // keep room for the toolbar
        imageSize = size
        shotView = ShotView(image: NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)))

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
        buildUI()
    }

    override var canBecomeKey: Bool { true }

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
            ("Copy Text from Image", "doc.on.clipboard", #selector(copyTextFromImage)),
            ("AirDrop Text from Image", "text.bubble", #selector(airDropText)),
            ("AirDrop Image", "photo", #selector(sendViaAirDrop)),
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
            NSImage(systemSymbolName: "textformat", accessibilityDescription: "Text")!,
        ], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modes.selectedSegment = 0
        modes.setToolTip("Move window", forSegment: 0)
        modes.setToolTip("Draw", forSegment: 1)
        modes.setToolTip("Type a note (click to place)", forSegment: 2)
        modes.controlSize = .small

        let color = NSColorWell(style: .minimal)
        color.color = .systemRed
        color.target = self
        color.action = #selector(colorChanged(_:))

        bar.addArrangedSubview(modes)
        bar.addArrangedSubview(color)
        bar.addArrangedSubview(button("arrow.uturn.backward", "Undo", #selector(undo)))
        bar.addArrangedSubview(NSView()) // spacer
        bar.addArrangedSubview(button("text.viewfinder", "Extract text (OCR)", #selector(toggleOCR)))
        bar.addArrangedSubview(button("doc.on.doc", "Copy image with notes", #selector(copyImage)))
        root.addSubview(bar)

        ocrText.isEditable = true
        ocrText.font = .systemFont(ofSize: 12)
        ocrText.textContainerInset = NSSize(width: 6, height: 6)
        ocrText.isVerticallyResizable = true
        ocrText.autoresizingMask = [.width]
        ocrScroll.documentView = ocrText
        ocrScroll.hasVerticalScroller = true
        ocrScroll.isHidden = true
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
        shotView.mode = [.move, .draw, .text][sender.selectedSegment]
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
    enum Mode { case move, draw, text }
    private enum Item { case stroke(NSBezierPath, NSColor), note(NSTextField) }

    var mode: Mode = .move { didSet { window?.invalidateCursorRects(for: self) } }
    var inkColor: NSColor = .systemRed
    private let image: NSImage
    private var items: [Item] = []
    private var currentPath: NSBezierPath?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        switch mode {
        case .move: addCursorRect(bounds, cursor: .openHand)
        case .draw: addCursorRect(bounds, cursor: .crosshair)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: NSRect(origin: .zero, size: image.size).fitting(in: bounds))
        for case let .stroke(path, color) in items { color.setStroke(); path.stroke() }
        if let currentPath { inkColor.setStroke(); currentPath.stroke() }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .move:
            window?.performDrag(with: event)
        case .draw:
            let path = NSBezierPath()
            path.lineWidth = 3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: p)
            currentPath = path
        case .text:
            addNote(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .draw, let path = currentPath else { return }
        path.line(to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .draw, let path = currentPath else { return }
        items.append(.stroke(path, inkColor))
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

private extension NSRect {
    // Draws the image at its natural size anchored top-left, scaled down only if the view is smaller.
    func fitting(in container: NSRect) -> NSRect {
        let s = min(1, container.width / width, container.height / height)
        let w = width * s, h = height * s
        return NSRect(x: container.minX, y: container.maxY - h, width: w, height: h)
    }
}
