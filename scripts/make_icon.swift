// Renders the app icon into an .iconset directory: swift scripts/make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedWhite: 0.16, alpha: 1), NSColor(calibratedWhite: 0.05, alpha: 1)])!.draw(in: bg, angle: -90)
    // Glowing ring
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: s * 0.17, dy: s * 0.17))
    ring.lineWidth = s * 0.07
    let shadow = NSShadow(); shadow.shadowColor = NSColor(calibratedRed: 0, green: 0.7, blue: 1, alpha: 1); shadow.shadowBlurRadius = s * 0.06
    shadow.set()
    NSColor(calibratedRed: 0.0, green: 0.71, blue: 1.0, alpha: 1).setStroke()
    ring.stroke()
    NSShadow().set()
    // Inner dot
    let dot = NSBezierPath(ovalIn: NSRect(x: s / 2 - s * 0.08, y: s / 2 - s * 0.08, width: s * 0.16, height: s * 0.16))
    NSColor.white.setFill(); dot.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
