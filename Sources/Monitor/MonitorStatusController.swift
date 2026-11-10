import AppKit
import SwiftUI

/// Owns the 0-4 menu bar icons and the dropdown they share.
///
/// - `standalone`: the MenuPulse app. If nothing is pinned, one plain icon is
///   shown so the dropdown stays reachable.
/// - `embedded`: inside another menu bar app. With nothing pinned there are no
///   icons at all, and the host opens the dropdown with `showPanel(hostAnchor:)`.
@MainActor
final class MonitorStatusController: NSObject, NSPopoverDelegate {
    enum Mode {
        case standalone
        case embedded
    }

    private let mode: Mode
    private let monitor = SystemMonitor()
    private let settings = MonitorSettings.shared
    private let ui = MonitorUIState()

    private var items: [MetricKind: NSStatusItem] = [:]
    private var fallbackItem: NSStatusItem?
    private let popover = NSPopover()
    private weak var anchorView: NSView?
    private weak var lastClosedAnchor: NSView?
    private var lastCloseTime: TimeInterval = 0

    init(mode: Mode) {
        self.mode = mode
        super.init()

        let root = MonitorPanelView(embedded: mode == .embedded)
            .environmentObject(monitor)
            .environmentObject(settings)
            .environmentObject(ui)
        let host = NSHostingController(rootView: root)
        // Lets the dropdown grow and shrink as rows are expanded.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        settings.onVisibleChange = { [weak self] in
            self?.syncItems()
        }
        settings.onEnabledChange = { [weak self] in
            self?.syncItems()
        }
        settings.onAppearanceChange = { [weak self] in
            self?.redraw()
        }
        settings.onIntervalChange = { [weak self] in
            guard let self else { return }
            if self.monitor.isRunning {
                self.monitor.start(interval: self.settings.interval)
            }
        }
        monitor.onUpdate = { [weak self] in
            self?.redraw()
        }

        syncItems()
    }

    // MARK: - Host entry point

    /// Opens the dropdown from the host app's own menu bar icon, or from the
    /// first pinned icon if the host has none. Returns false if there is
    /// nowhere to show it, or the monitor is switched off.
    @discardableResult
    func showPanel(hostAnchor: NSView?) -> Bool {
        guard isActive else { return false }
        let pinned: NSView? = settings.visible.compactMap { items[$0]?.button }.first
        let fallback: NSView? = fallbackItem?.button
        guard let anchor = hostAnchor ?? pinned ?? fallback else { return false }
        if popover.isShown {
            popover.close()
        }
        present(from: anchor, focus: nil)
        return true
    }

    // MARK: - Status items

    /// The standalone app has no master switch; it is always on.
    private var isActive: Bool {
        mode == .standalone || settings.enabled
    }

    private func makeItem(autosaveName: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS remembers where each icon was ⌘-dragged to under this name.
        item.autosaveName = autosaveName
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown])
        }
        return item
    }

    /// Shows the pinned icons and hides the rest.
    private func syncItems() {
        let wanted = isActive ? settings.visible : []

        // New status items appear to the left of existing ones, so create in
        // reverse to get CPU ... Network from left to right on first use.
        for kind in MetricKind.allCases.reversed() where wanted.contains(kind) && items[kind] == nil {
            items[kind] = makeItem(autosaveName: "MenuPulse.\(kind.rawValue)")
        }
        for (kind, item) in items {
            let show = wanted.contains(kind)
            if !show, popover.isShown, anchorView === item.button {
                popover.close()
            }
            item.isVisible = show
        }

        if mode == .standalone {
            let needsFallback = wanted.isEmpty
            if needsFallback, fallbackItem == nil {
                let item = makeItem(autosaveName: "MenuPulse.fallback")
                let image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "MenuPulse")
                image?.isTemplate = true
                item.button?.image = image
                item.button?.toolTip = "MenuPulse"
                fallbackItem = item
            }
            if let fallbackItem {
                if !needsFallback, popover.isShown, anchorView === fallbackItem.button {
                    popover.close()
                }
                fallbackItem.isVisible = needsFallback
            }
        }

        if !isActive, popover.isShown {
            popover.close()
        }
        updateRunning()
        redraw()
    }

    /// Samples only while something is on screen to show the result.
    private func updateRunning() {
        let needed = isActive && (!settings.visible.isEmpty || popover.isShown)
        if needed, !monitor.isRunning {
            monitor.start(interval: settings.interval)
        } else if !needed, monitor.isRunning {
            monitor.stop()
        }
    }

    private func redraw() {
        guard isActive else { return }
        let history = monitor.history
        let snapshot = monitor.snapshot
        for kind in settings.visible {
            guard let button = items[kind]?.button else { continue }
            button.image = MenuBarIcon.image(for: kind, history: history,
                                             showGlyph: settings.showGlyph,
                                             colorful: settings.colorGraphs,
                                             barHeight: button.bounds.height,
                                             appearance: button.effectiveAppearance)
            button.toolTip = "\(kind.title): \(snapshot.summary(for: kind))"
        }
    }

    // MARK: - Dropdown

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let now = ProcessInfo.processInfo.systemUptime

        if popover.isShown {
            let sameIcon = anchorView === sender
            popover.close()
            if sameIcon { return }
        } else if lastClosedAnchor === sender, now - lastCloseTime < 0.3 {
            // This same click already dismissed the dropdown; do not reopen it.
            return
        }

        let kind = items.first(where: { $0.value.button === sender })?.key
        present(from: sender, focus: kind)
    }

    private func present(from anchor: NSView, focus: MetricKind?) {
        if let focus {
            ui.focus(focus)
        }
        anchorView = anchor
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        updateRunning()
    }

    func popoverDidClose(_ notification: Notification) {
        // Ignore a late notification for a dropdown that has already reopened.
        guard !popover.isShown else { return }
        lastClosedAnchor = anchorView
        lastCloseTime = ProcessInfo.processInfo.systemUptime
        anchorView = nil
        updateRunning()
    }
}
