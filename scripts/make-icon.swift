// Draws Hop's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (from the repo root)
import AppKit

let size: CGFloat = 1024

func drawIcon() -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        // Body: rounded square on the standard macOS icon grid (824pt inside a 1024pt canvas).
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let bodyShadow = NSShadow()
        bodyShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        bodyShadow.shadowOffset = NSSize(width: 0, height: -12)
        bodyShadow.shadowBlurRadius = 24
        bodyShadow.set()
        NSColor(red: 0.35, green: 0.30, blue: 0.85, alpha: 1).setFill()
        bodyPath.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(red: 0.47, green: 0.45, blue: 0.98, alpha: 1),
                   ending: NSColor(red: 0.30, green: 0.22, blue: 0.80, alpha: 1))!
            .draw(in: bodyPath, angle: 90)

        // Back window.
        let back = NSRect(x: 214, y: 330, width: 390, height: 290)
        NSColor.white.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: back, xRadius: 38, yRadius: 38).fill()

        // Front window, with a soft shadow.
        let front = NSRect(x: 420, y: 470, width: 390, height: 290)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowBlurRadius = 30
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: front, xRadius: 38, yRadius: 38).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Front window contents: a title bar and a few lines of "text".
        let lavender = NSColor(red: 0.86, green: 0.85, blue: 1.0, alpha: 1)
        let bar = NSBezierPath(roundedRect: NSRect(x: front.minX, y: front.minY, width: front.width, height: 64), xRadius: 38, yRadius: 38)
        bar.append(NSBezierPath(rect: NSRect(x: front.minX, y: front.minY + 32, width: front.width, height: 32)))
        lavender.setFill()
        bar.fill()
        for (i, width) in [250.0, 300.0, 200.0].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: front.minX + 44, y: front.minY + 110 + CGFloat(i) * 52, width: width, height: 22),
                         xRadius: 11, yRadius: 11).fill()
        }

        // The hop: an arc from the back window over to the front one.
        let white = NSColor.white
        let arc = NSBezierPath()
        arc.move(to: NSPoint(x: 430, y: 300))
        arc.curve(to: NSPoint(x: 700, y: 420), controlPoint1: NSPoint(x: 480, y: 170), controlPoint2: NSPoint(x: 660, y: 170))
        arc.lineWidth = 30
        arc.lineCapStyle = .round
        white.setStroke()
        arc.stroke()

        let head = NSBezierPath()
        head.move(to: NSPoint(x: 648, y: 380))
        head.line(to: NSPoint(x: 706, y: 440))
        head.line(to: NSPoint(x: 752, y: 368))
        head.lineWidth = 30
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let icon = drawIcon()
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(icon, pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(icon, pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try png(icon, pixels: 512).write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
