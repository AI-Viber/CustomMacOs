// Draws the app icon PNGs into an .iconset folder (run by build.sh).
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func draw(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle background
    let inset = s * 0.1
    let bg = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bgPath = NSBezierPath(roundedRect: bg, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.36, alpha: 1),
               ending: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.16, alpha: 1))?.draw(in: bgPath, angle: -90)

    // Three window tiles: one tall left, two stacked right
    let pad = s * 0.2
    let g = s * 0.035
    let area = NSRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let r = s * 0.04
    let leftW = area.width * 0.55 - g / 2
    let left = NSRect(x: area.minX, y: area.minY, width: leftW, height: area.height)
    let rightX = area.minX + leftW + g
    let rightW = area.maxX - rightX
    let halfH = (area.height - g) / 2
    let topRight = NSRect(x: rightX, y: area.minY + halfH + g, width: rightW, height: halfH)
    let bottomRight = NSRect(x: rightX, y: area.minY, width: rightW, height: halfH)

    NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: left, xRadius: r, yRadius: r).fill()
    NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.75, alpha: 1).setFill()
    NSBezierPath(roundedRect: topRight, xRadius: r, yRadius: r).fill()
    NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.40, alpha: 1).setFill()
    NSBezierPath(roundedRect: bottomRight, xRadius: r, yRadius: r).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let data = draw(base * scale) {
            try? data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
        }
    }
}
