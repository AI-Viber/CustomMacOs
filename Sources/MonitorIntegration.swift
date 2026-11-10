import AppKit
import SwiftUI

/// Connects the system monitor in Sources/Monitor (shared with the standalone
/// MenuPulse app) to CustomMacOS: start-up, the "System Monitor…" menu item and
/// the Monitor tab in Settings.
enum SystemMonitorFeature {
    private static var controller: MonitorStatusController?

    /// Call once at launch, on the main thread.
    static func start() {
        MainActor.assumeIsolated {
            if controller == nil {
                controller = MonitorStatusController(mode: .embedded)
            }
        }
    }

    /// Opens the monitor panel below `anchor` (the CustomMacOS menu bar icon), or below
    /// the first pinned monitor icon when there is no anchor. Returns false if the
    /// monitor is switched off or there is no icon to open it from.
    static func showPanel(anchor: NSView?) -> Bool {
        MainActor.assumeIsolated {
            controller?.showPanel(hostAnchor: anchor) ?? false
        }
    }
}

struct MonitorTab: View {
    @ObservedObject var monitor = MonitorSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show system monitor", isOn: $monitor.enabled)
            } footer: {
                Text("Adds live CPU, GPU, Neural Engine, memory, disk and network readings. Choose “System Monitor…” from the CustomMacOS menu, or click any monitor icon, to see the detail.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if monitor.enabled {
                Section {
                    ForEach(MetricKind.allCases) { kind in
                        Toggle(isOn: Binding(
                            get: { monitor.isVisible(kind) },
                            set: { _ in monitor.toggle(kind) })) {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                        .disabled(!monitor.canToggle(kind))
                    }
                    Toggle("Show a symbol beside each graph", isOn: $monitor.showGlyph)
                    Toggle("Colour the graphs", isOn: $monitor.colorGraphs)
                } header: {
                    Text("Menu bar icons")
                } footer: {
                    Text("Up to \(MonitorSettings.maxVisible), or none at all. ⌘-drag an icon in the menu bar to move it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Refresh every", selection: $monitor.interval) {
                        ForEach(MonitorSettings.intervals, id: \.self) { value in
                            Text("\(Int(value)) s").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Readings are only taken while a monitor icon or the panel is showing. The Neural Engine figure is estimated from its power draw.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
