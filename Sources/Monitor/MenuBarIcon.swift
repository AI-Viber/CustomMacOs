import AppKit

extension MetricKind {
    /// Colour of this metric's menu bar graph.
    var graphColor: NSColor {
        switch self {
        case .cpu: return .systemBlue
        case .gpu: return .systemGreen
        case .ane: return .systemPurple
        case .memory: return .systemOrange
        case .disk: return .systemPink
        case .network: return .systemTeal
        }
    }

    /// Colour of the second series (disk writes, network uploads).
    var secondaryGraphColor: NSColor {
        .systemIndigo
    }
}

/// Draws one menu bar icon: an optional glyph plus a small history graph.
enum MenuBarIcon {
    /// Space left clear above and below the icon inside the menu bar.
    private static let verticalMargin: CGFloat = 1
    private static let glyphWidth: CGFloat = 16
    private static let graphWidth: CGFloat = 22

    /// - Parameters:
    ///   - showGlyph: false draws the graph on its own, for a narrower icon.
    ///   - colorful: false draws a single-colour template image that macOS tints.
    ///   - barHeight: height of the menu bar button; the graph fills most of it.
    ///   - appearance: the menu bar button's appearance, so that the glyph and
    ///     frame are light on a dark menu bar and dark on a light one.
    static func image(for kind: MetricKind, history: MonitorHistory,
                      showGlyph: Bool, colorful: Bool, barHeight: CGFloat,
                      appearance: NSAppearance) -> NSImage {
        // Menu bars are 22-24 pt of usable height, more on notched displays;
        // stay within that range so the icon never looks oversized.
        let height = min(max(barHeight, 18), 24) - verticalMargin * 2
        let series = history.normalized(kind)
        let primary = series.primary
        let secondary = series.secondary
        let graphX = showGlyph ? glyphWidth : 0
        let size = NSSize(width: graphX + graphWidth, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            if colorful {
                appearance.performAsCurrentDrawingAppearance {
                    // Resolve the label colour for this menu bar now.
                    let ink = NSColor.labelColor.usingColorSpace(.sRGB) ?? NSColor.labelColor
                    if showGlyph {
                        drawGlyph(for: kind, height: height, ink: ink, tinted: true)
                    }
                    drawGraph(x: graphX, height: height, primary: primary, secondary: secondary, frame: ink,
                              primaryColor: kind.graphColor, secondaryColor: kind.secondaryGraphColor)
                }
            } else {
                if showGlyph {
                    drawGlyph(for: kind, height: height, ink: .black, tinted: false)
                }
                drawGraph(x: graphX, height: height, primary: primary, secondary: secondary, frame: .black,
                          primaryColor: .black, secondaryColor: .black)
            }
            return true
        }
        image.isTemplate = !colorful
        return image
    }

    private static func drawGlyph(for kind: MetricKind, height: CGFloat, ink: NSColor, tinted: Bool) {
        let box = NSRect(x: 0, y: (height - 14) / 2, width: 14, height: 14)
        var configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if tinted {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        }

        if let symbol = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)?
            .withSymbolConfiguration(configuration) {
            let natural = symbol.size
            guard natural.width > 0, natural.height > 0 else { return }
            let scale = min(box.width / natural.width, box.height / natural.height, 1)
            let width = natural.width * scale
            let glyphHeight = natural.height * scale
            symbol.draw(in: NSRect(x: box.midX - width / 2, y: box.midY - glyphHeight / 2, width: width, height: glyphHeight))
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ink
            ]
            let text = NSAttributedString(string: kind.shortLabel, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: box.midX - textSize.width / 2, y: box.midY - textSize.height / 2))
        }
    }

    private static func drawGraph(x: CGFloat, height: CGFloat, primary: [Double], secondary: [Double]?, frame: NSColor,
                                  primaryColor: NSColor, secondaryColor: NSColor) {
        let box = NSRect(x: x + 0.5, y: 0.5, width: graphWidth - 1, height: height - 1)
        let outline = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        frame.withAlphaComponent(0.45).setStroke()
        outline.stroke()

        let inner = box.insetBy(dx: 1.5, dy: 1.5)
        let columns = Int(inner.width)

        func clamp(_ value: Double) -> CGFloat {
            CGFloat(min(max(value, 0), 1))
        }

        if let secondary {
            // Two series: the first grows up from the middle, the second grows down.
            let half = inner.height / 2
            let up = Array(primary.suffix(columns))
            let down = Array(secondary.suffix(columns))

            primaryColor.setFill()
            for (index, value) in up.enumerated() {
                let barX = inner.maxX - CGFloat(up.count - index)
                NSRect(x: barX, y: inner.midY, width: 1, height: clamp(value) * half).fill()
            }
            secondaryColor.setFill()
            for (index, value) in down.enumerated() {
                let barX = inner.maxX - CGFloat(down.count - index)
                let barHeight = clamp(value) * half
                NSRect(x: barX, y: inner.midY - barHeight, width: 1, height: barHeight).fill()
            }
            frame.withAlphaComponent(0.3).setFill()
            NSRect(x: inner.minX, y: inner.midY - 0.25, width: inner.width, height: 0.5).fill()
        } else {
            let values = Array(primary.suffix(columns))
            primaryColor.setFill()
            for (index, value) in values.enumerated() {
                let barX = inner.maxX - CGFloat(values.count - index)
                NSRect(x: barX, y: inner.minY, width: 1, height: clamp(value) * inner.height).fill()
            }
        }
    }
}
