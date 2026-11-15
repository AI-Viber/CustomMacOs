import AppKit
import Combine
import IOKit.ps

/// One reading of the internal battery.
struct BatterySnapshot: Equatable {
    /// 0–100.
    var percent: Int
    /// Actively charging.
    var isCharging: Bool
    /// Connected to a power adapter (charging or not).
    var onACPower: Bool
    /// Fully charged.
    var isCharged: Bool
    /// Minutes until empty / full; nil while macOS is still estimating.
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var lowPowerMode: Bool

    /// macOS shows the battery in red at this level or below when not plugged in.
    var isLow: Bool { !onACPower && percent <= 10 }

    /// One line for the menu, e.g. "Charging · 1:05 until full".
    var statusLine: String {
        if isCharging {
            if let m = minutesToFull, m > 0 { return "Charging · \(Self.hm(m)) until full" }
            return "Charging"
        }
        if onACPower {
            return isCharged || percent >= 100 ? "Fully charged · on power adapter" : "Not charging · on power adapter"
        }
        if let m = minutesToEmpty, m > 0 { return "On battery · \(Self.hm(m)) remaining" }
        return "On battery · calculating time remaining…"
    }

    var accessibilityText: String {
        var s = "Battery \(percent) percent"
        if isCharging { s += ", charging" } else if onACPower { s += ", on power adapter" }
        if lowPowerMode { s += ", Low Power Mode" }
        return s
    }

    private static func hm(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Watches the internal battery and Low Power Mode.
final class BatteryStatus: ObservableObject {
    static let shared = BatteryStatus()

    /// nil on Macs without a battery.
    @Published private(set) var snapshot: BatterySnapshot?

    var hasBattery: Bool { snapshot != nil }

    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var lowPowerObserver: Any?

    private init() {
        snapshot = Self.read()
    }

    func start() {
        guard runLoopSource == nil else { return }
        // macOS calls this whenever anything about the power sources changes.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<BatteryStatus>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { me.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        // Time estimates change without a power-source notification; refresh them every minute.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        let new = Self.read()
        if new != snapshot { snapshot = new }
    }

    private static func read() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  (d[kIOPSIsPresentKey] as? Bool) ?? true else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            let toEmpty = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            let toFull = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            return BatterySnapshot(
                percent: min(max(percent, 0), 100),
                isCharging: d[kIOPSIsChargingKey] as? Bool ?? false,
                onACPower: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                isCharged: d[kIOPSIsChargedKey] as? Bool ?? false,
                minutesToEmpty: toEmpty >= 0 ? toEmpty : nil,
                minutesToFull: toFull >= 0 ? toFull : nil,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        return nil
    }

    static func openBatterySettings() {
        let urls = ["x-apple.systempreferences:com.apple.Battery-Settings.extension",
                    "x-apple.systempreferences:com.apple.preference.battery"]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}

/// Draws an upright battery for the menu bar, filling from the bottom, in the style of
/// macOS's own battery icon. Sized and drawn the same way as the System Monitor's icons, so
/// macOS positions it in line with every other menu bar icon.
enum BatteryIcon {
    /// - Parameters:
    ///   - bodyWidth: the battery's width in points.
    ///   - barHeight: the menu bar button's height; the battery uses all of it but a 1pt margin.
    ///   - appearance: the button's appearance, so the battery is light on a dark menu bar and
    ///     dark on a light one.
    ///   - percent: show the percentage beside the battery ("87%"), inside it ("87"), or not at all.
    ///   - coloured: colour the charge level by state (see `levelColour`).
    static func image(for s: BatterySnapshot, percent: BatteryPercentStyle, coloured: Bool,
                      bodyWidth: CGFloat = 30, barHeight: CGFloat? = nil,
                      appearance: NSAppearance? = nil) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        let text = percent == .beside ? "\(s.percent)%" : ""
        let insideText = percent == .inside ? "\(s.percent)" : ""
        let textSize = text.isEmpty ? .zero : (text as NSString).size(withAttributes: [.font: font])

        // Same rule as the System Monitor icons: menu bar buttons give 22–24pt of usable height
        // (also on Macs with a notch); keep within that, less 1pt above and below.
        let height = min(max(barHeight ?? NSStatusBar.system.thickness, 18), 24) - 2
        let bodyW = max(10, bodyWidth)
        let nubH: CGFloat = 2, nubW = max(5, bodyW * 0.4)
        let bodyH = height - nubH - 1
        let gap: CGFloat = text.isEmpty ? 0 : 3
        let width = ceil(textSize.width + gap + bodyW)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { dest in
            var drewOK = true
            let draw = {
                // Draw into a private bitmap first, so cutting the outline around the bolt
                // can't punch through to the menu bar.
                let scale: CGFloat = 2
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                                                 pixelsHigh: Int(height * scale), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { drewOK = false; return }
                // Set the size in points before making the context, so drawing is in points
                // (otherwise the context works in pixels and the battery fills only the
                // bottom-left quarter: half-size and low).
                rep.size = NSSize(width: width, height: height)
                guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { drewOK = false; return }
                // Resolve colours for this menu bar now (light or dark).
                let ink = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
                let warn: NSColor? = coloured ? levelColour(for: s)
                    : (s.lowPowerMode ? .systemYellow : (s.isLow ? .systemRed : nil))
                let fillColour = warn.flatMap { $0.usingColorSpace(.sRGB) } ?? ink

                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                drawBattery(s, text: text, insideText: insideText, textSize: textSize, font: font, gap: gap,
                            bodyW: bodyW, bodyH: bodyH, nubW: nubW, nubH: nubH,
                            ink: ink, fillColour: fillColour)
                NSGraphicsContext.restoreGraphicsState()
                rep.draw(in: dest)
            }
            if let appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return drewOK
        }
        image.isTemplate = false
        image.accessibilityDescription = s.accessibilityText
        return image
    }

    /// Blue while charging, yellow in Low Power Mode, otherwise green above 20%,
    /// orange from 10% to 20%, and red below 10%.
    static func levelColour(for s: BatterySnapshot) -> NSColor {
        if s.isCharging { return .systemBlue }
        if s.lowPowerMode { return .systemYellow }
        if s.percent < 10 { return .systemRed }
        if s.percent <= 20 { return .systemOrange }
        return .systemGreen
    }

    private static func drawBattery(_ s: BatterySnapshot, text: String, insideText: String,
                                    textSize: NSSize, font: NSFont,
                                    gap: CGFloat, bodyW: CGFloat, bodyH: CGFloat, nubW: CGFloat, nubH: CGFloat,
                                    ink: NSColor, fillColour: NSColor) {
        let totalH = bodyH + 1 + nubH
        if !text.isEmpty {
            let y = (totalH - textSize.height) / 2
            (text as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: [.font: font, .foregroundColor: ink])
        }

        let x0 = text.isEmpty ? 0 : textSize.width + gap
        let body = NSRect(x: x0, y: 0, width: bodyW, height: bodyH)
        // A clear outline, plus a faint tint inside so the empty part still reads as battery.
        let line: CGFloat = 1.5
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: line / 2, dy: line / 2), xRadius: 4, yRadius: 4)
        ink.withAlphaComponent(0.15).setFill()
        outline.fill()
        outline.lineWidth = line
        ink.withAlphaComponent(0.75).setStroke()
        outline.stroke()

        // Terminal on top.
        let nub = NSRect(x: body.midX - nubW / 2, y: body.maxY + 1, width: nubW, height: nubH)
        ink.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: nub, xRadius: 1, yRadius: 1).fill()

        // Charge rises from the bottom.
        let inner = body.insetBy(dx: line + 1.5, dy: line + 1.5)
        let level = CGFloat(s.percent) / 100
        if level > 0 {
            let fill = NSRect(x: inner.minX, y: inner.minY,
                              width: inner.width, height: max(1.5, inner.height * level))
            fillColour.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        }

        if !insideText.isEmpty {
            // The number takes the place of the bolt or plug.
            drawNumber(insideText, centredIn: body, ink: ink)
        } else if s.onACPower {
            // Charging bolt, or plug when on power but not charging.
            drawGlyph(s.isCharging ? "bolt.fill" : "powerplug.fill", centredIn: body, ink: ink,
                      pointSize: min(bodyH * 0.6, bodyW * 0.7))
        }
    }

    /// Draws the percentage inside the battery, as large as fits, with a knocked-out outline.
    private static func drawNumber(_ text: String, centredIn rect: NSRect, ink: NSColor) {
        var size = min(rect.height * 0.62, 11)
        var attributes: [NSAttributedString.Key: Any] = [:]
        var textSize = NSSize.zero
        while true {
            attributes = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: ink]
            textSize = (text as NSString).size(withAttributes: attributes)
            if textSize.width <= rect.width - 5 || size <= 5 { break }
            size -= 0.5
        }
        let imageSize = NSSize(width: ceil(textSize.width), height: ceil(textSize.height))
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let label = NSImage(size: imageSize, flipped: false) { _ in
            (text as NSString).draw(at: .zero, withAttributes: attributes)
            return true
        }
        let r = NSRect(x: rect.midX - imageSize.width / 2, y: rect.midY - imageSize.height / 2,
                       width: imageSize.width, height: imageSize.height)
        drawKnockedOut(label, in: r)
    }

    /// Draws an SF Symbol with a knocked-out outline, so it stays readable over the fill.
    private static func drawGlyph(_ name: String, centredIn rect: NSRect, ink: NSColor, pointSize: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let r = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                       width: size.width, height: size.height)
        drawKnockedOut(symbol, in: r)
    }

    private static func drawKnockedOut(_ image: NSImage, in r: NSRect) {
        // Cut a 1-point outline around the shape...
        for dx in [-1.0, 0, 1.0] {
            for dy in [-1.0, 0, 1.0] where dx != 0 || dy != 0 {
                image.draw(in: r.offsetBy(dx: dx, dy: dy), from: .zero, operation: .destinationOut, fraction: 1)
            }
        }
        // ...then draw the shape itself.
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
