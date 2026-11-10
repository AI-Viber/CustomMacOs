import Combine
import Foundation

/// User choices for the system monitor, saved in UserDefaults.
final class MonitorSettings: ObservableObject {
    static let shared = MonitorSettings()

    static let maxVisible = 4
    static let intervals: [Double] = [1, 2, 5]

    private static let enabledKey = "monitor.enabled"
    private static let visibleKey = "monitor.visibleMetrics"
    private static let intervalKey = "monitor.refreshInterval"
    private static let showGlyphKey = "monitor.showGlyph"
    private static let colorGraphsKey = "monitor.colorGraphs"

    /// Master switch. When off, nothing is sampled and no icons are shown.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: MonitorSettings.enabledKey)
            onEnabledChange?()
        }
    }

    /// Metrics pinned to the menu bar: 0 to 4 of them, in display order.
    @Published private(set) var visible: [MetricKind] {
        didSet {
            UserDefaults.standard.set(visible.map(\.rawValue), forKey: MonitorSettings.visibleKey)
            onVisibleChange?()
        }
    }

    /// Seconds between refreshes.
    @Published var interval: Double {
        didSet {
            UserDefaults.standard.set(interval, forKey: MonitorSettings.intervalKey)
            onIntervalChange?()
        }
    }

    /// Draw each metric's glyph beside its graph. Off gives a narrower, graph-only icon.
    @Published var showGlyph: Bool {
        didSet {
            UserDefaults.standard.set(showGlyph, forKey: MonitorSettings.showGlyphKey)
            onAppearanceChange?()
        }
    }

    /// Draw the menu bar graphs in colour rather than the menu bar's single tint.
    @Published var colorGraphs: Bool {
        didSet {
            UserDefaults.standard.set(colorGraphs, forKey: MonitorSettings.colorGraphsKey)
            onAppearanceChange?()
        }
    }

    var onAppearanceChange: (() -> Void)?
    var onEnabledChange: (() -> Void)?
    var onVisibleChange: (() -> Void)?
    var onIntervalChange: (() -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: MonitorSettings.enabledKey) as? Bool ?? true

        if let saved = defaults.stringArray(forKey: MonitorSettings.visibleKey) {
            // An empty saved list is a real choice: no icons pinned.
            let kinds = saved.compactMap { MetricKind(rawValue: $0) }
            let ordered = MetricKind.allCases.filter { kinds.contains($0) }
            visible = Array(ordered.prefix(MonitorSettings.maxVisible))
        } else {
            visible = [.cpu, .memory, .network]
        }

        showGlyph = defaults.object(forKey: MonitorSettings.showGlyphKey) as? Bool ?? true
        colorGraphs = defaults.object(forKey: MonitorSettings.colorGraphsKey) as? Bool ?? true

        let savedInterval = defaults.double(forKey: MonitorSettings.intervalKey)
        interval = MonitorSettings.intervals.contains(savedInterval) ? savedInterval : 2
    }

    func isVisible(_ kind: MetricKind) -> Bool {
        visible.contains(kind)
    }

    /// Unpinning is always allowed; pinning stops at four icons.
    func canToggle(_ kind: MetricKind) -> Bool {
        isVisible(kind) || visible.count < MonitorSettings.maxVisible
    }

    func toggle(_ kind: MetricKind) {
        guard canToggle(kind) else { return }
        var wanted = Set(visible)
        if wanted.contains(kind) {
            wanted.remove(kind)
        } else {
            wanted.insert(kind)
        }
        visible = MetricKind.allCases.filter { wanted.contains($0) }
    }
}

/// Which rows of the dropdown are expanded.
final class MonitorUIState: ObservableObject {
    @Published var expanded: Set<MetricKind> = []

    func toggle(_ kind: MetricKind) {
        if expanded.contains(kind) {
            expanded.remove(kind)
        } else {
            expanded.insert(kind)
        }
    }

    /// Opens the dropdown with just the clicked metric expanded.
    func focus(_ kind: MetricKind) {
        expanded = [kind]
    }
}
