// Render the FixText icon: a macOS-style rounded tile with an SF Symbol, to FixText.iconset/*.png.
// Run once: swift make-icon.swift && iconutil -c icns FixText.iconset
import AppKit

let sizes: [(name: String, px: Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                                        ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                                        ("512x512", 512), ("512x512@2x", 1024)]
let dir = URL(fileURLWithPath: "FixText.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

for (name, px) in sizes {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let inset = size * 0.1                       // macOS icons leave a transparent margin around the tile
        let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.height * 0.225)
        NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.42, blue: 1.0, alpha: 1),
                   ending: NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.9, alpha: 1))!
            .draw(in: path, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2, width: s.width, height: s.height))
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon_\(name).png"))
}
