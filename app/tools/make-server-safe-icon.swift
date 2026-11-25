// Draws app/ServerSafeIcon.icns: swiftc -O make-server-safe-icon.swift -o mk && mkdir SS.iconset && ./mk SS.iconset && iconutil -c icns SS.iconset -o ../ServerSafeIcon.icns
import AppKit
// VanaGuide Server-Safe icon: night-indigo tile, gold open book, crystal compass star.
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.098, r = s * 0.18
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: r, yRadius: r)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.14, blue: 0.36, alpha: 1), NSColor(red: 0.05, green: 0.05, blue: 0.12, alpha: 1)])!
        .draw(in: tile, angle: -90)
    NSColor(white: 1, alpha: 0.14).setStroke(); tile.lineWidth = s * 0.008; tile.stroke()
    let gold = NSColor(red: 0.93, green: 0.79, blue: 0.44, alpha: 1)
    let crystal = NSColor(red: 0.55, green: 0.83, blue: 0.95, alpha: 1)
    func symbol(_ name: String, _ pt: CGFloat, _ color: NSColor, _ center: NSPoint) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let sz = img.size
        img.draw(in: NSRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2, width: sz.width, height: sz.height))
    }
    symbol("book.pages.fill", s * 0.36, gold, NSPoint(x: s * 0.5, y: s * 0.44))
    symbol("sparkle", s * 0.17, crystal, NSPoint(x: s * 0.70, y: s * 0.70))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let dir = CommandLine.arguments[1]
for (n, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(n).png"))
}
