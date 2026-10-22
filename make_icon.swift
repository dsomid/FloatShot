// Renders the FloatShot app icon into an .iconset folder.
// Usage: swift make_icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // Rounded-square background with a blue→violet gradient.
    let bg = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: bg, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.22, green: 0.45, blue: 1.0, alpha: 1),
                        NSColor(red: 0.55, green: 0.25, blue: 0.95, alpha: 1)])!.draw(in: squircle, angle: -60)

    // Back "floating" card.
    let back = NSBezierPath(roundedRect: NSRect(x: 300 * s, y: 330 * s, width: 470 * s, height: 360 * s), xRadius: 40 * s, yRadius: 40 * s)
    NSColor.white.withAlphaComponent(0.35).setFill()
    back.fill()

    // Front card with a shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 30 * s
    shadow.shadowOffset = NSSize(width: 0, height: -14 * s)
    shadow.set()
    let card = NSRect(x: 235 * s, y: 255 * s, width: 470 * s, height: 360 * s)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: card, xRadius: 40 * s, yRadius: 40 * s).fill()
    NSGraphicsContext.restoreGraphicsState()

    // "Text" lines on the card (the OCR hint).
    NSColor(white: 0.78, alpha: 1).setFill()
    for (i, w) in [330.0, 260.0, 300.0].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 290 * s, y: (530 - CGFloat(i) * 70) * s, width: CGFloat(w) * s, height: 30 * s),
                     xRadius: 15 * s, yRadius: 15 * s).fill()
    }

    // Red annotation scribble.
    let scribble = NSBezierPath()
    scribble.move(to: NSPoint(x: 280 * s, y: 330 * s))
    scribble.curve(to: NSPoint(x: 640 * s, y: 345 * s), controlPoint1: NSPoint(x: 400 * s, y: 280 * s), controlPoint2: NSPoint(x: 520 * s, y: 400 * s))
    scribble.lineWidth = 28 * s
    scribble.lineCapStyle = .round
    NSColor.systemRed.setStroke()
    scribble.stroke()

    // Selection corner brackets.
    NSColor.white.setStroke()
    let r = NSRect(x: 180 * s, y: 200 * s, width: 580 * s, height: 470 * s), L = 90 * s
    for (corner, dx, dy) in [(NSPoint(x: r.minX, y: r.minY), 1.0, 1.0), (NSPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                             (NSPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (NSPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: corner.x + L * dx, y: corner.y))
        p.line(to: corner)
        p.line(to: NSPoint(x: corner.x, y: corner.y + L * dy))
        p.lineWidth = 26 * s
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
