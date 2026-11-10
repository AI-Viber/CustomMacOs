import AppKit
import ServiceManagement
import SwiftUI

extension MetricKind {
    var color: Color {
        switch self {
        case .cpu: return .blue
        case .gpu: return .green
        case .ane: return .purple
        case .memory: return .orange
        case .disk: return .pink
        case .network: return .teal
        }
    }
}

// MARK: - Dropdown

struct MonitorPanelView: View {
    /// True when the monitor runs inside another app, which has its own
    /// Quit and Launch at login controls.
    let embedded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MetricKind.allCases) { kind in
                MetricSection(kind: kind)
                Divider()
            }
            MonitorFooter(embedded: embedded)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row of the dropdown: a summary line that expands to show detail.
struct MetricSection: View {
    let kind: MetricKind
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var settings: MonitorSettings
    @EnvironmentObject var ui: MonitorUIState

    var body: some View {
        let expanded = ui.expanded.contains(kind)
        let pinned = settings.isVisible(kind)
        let series = monitor.history.normalized(kind)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    ui.toggle(kind)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 10)
                        Image(systemName: kind.symbol)
                            .foregroundStyle(kind.color)
                            .frame(width: 20)
                        Text(kind.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Sparkline(values: series.primary, secondary: series.secondary, color: kind.color)
                            .frame(width: 56, height: 18)
                        Text(monitor.snapshot.summary(for: kind))
                            .font(.callout)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: 96, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    settings.toggle(kind)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(pinned ? kind.color : Color.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .disabled(!settings.canToggle(kind))
                .help(pinned ? "Remove from menu bar" : "Show in menu bar (up to 4)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if expanded {
                detail
                    .font(.callout)
                    .padding(.leading, 30)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        let snapshot = monitor.snapshot
        switch kind {
        case .cpu:
            CPUDetail(cpu: snapshot.cpu, power: snapshot.power)
        case .gpu:
            GPUDetail(gpus: snapshot.gpus, power: snapshot.power)
        case .ane:
            ANEDetail(power: snapshot.power)
        case .memory:
            MemoryDetail(memory: snapshot.memory)
        case .disk:
            DiskDetail(disk: snapshot.disk)
        case .network:
            NetworkDetail(network: snapshot.network)
        }
    }
}

// MARK: - Detail panels

struct CPUDetail: View {
    let cpu: CPUStats
    let power: PowerStats

    var body: some View {
        let rows = stride(from: 0, to: cpu.cores.count, by: 2).map { start in
            Array(cpu.cores[start..<min(start + 2, cpu.cores.count)])
        }

        VStack(alignment: .leading, spacing: 5) {
            InfoRow("User", MonitorFormat.percent(cpu.user))
            InfoRow("System", MonitorFormat.percent(cpu.system))
            InfoRow("Idle", MonitorFormat.percent(1 - cpu.total))
            if cpu.loadAverage.count == 3 {
                InfoRow("Load average", cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            }
            if power.available {
                InfoRow("CPU power", MonitorFormat.watts(power.cpuWatts))
            }

            SectionLabel("Per core")
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 14) {
                    ForEach(rows[rowIndex]) { core in
                        BarRow(label: core.label, value: core.usage, color: MetricKind.cpu.color, labelWidth: 24)
                    }
                    if rows[rowIndex].count == 1 {
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
            }
        }
    }
}

struct GPUDetail: View {
    let gpus: [GPUStats]
    let power: PowerStats

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if gpus.isEmpty {
                MonitorNote("No GPU statistics are available on this Mac.")
            }
            ForEach(gpus) { gpu in
                SectionLabel(gpu.name)
                BarRow(label: "Overall", value: gpu.utilization, color: MetricKind.gpu.color, labelWidth: 62)
                if let renderer = gpu.renderer {
                    BarRow(label: "Renderer", value: renderer, color: MetricKind.gpu.color, labelWidth: 62)
                }
                if let tiler = gpu.tiler {
                    BarRow(label: "Tiler", value: tiler, color: MetricKind.gpu.color, labelWidth: 62)
                }
                if let memory = gpu.memoryInUse {
                    InfoRow("Memory in use", MonitorFormat.bytes(memory))
                }
            }
            if power.available {
                InfoRow("GPU power", MonitorFormat.watts(power.gpuWatts))
            }
        }
    }
}

struct ANEDetail: View {
    let power: PowerStats

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if power.hasANE {
                InfoRow("Power", MonitorFormat.watts(power.aneWatts))
                BarRow(label: "Load", value: power.aneLoad, color: MetricKind.ane.color, labelWidth: 62)
                MonitorNote("macOS reports only the Neural Engine's power draw. Load is an estimate against \(Int(PowerStats.aneFullLoadWatts)) W.")
            } else {
                MonitorNote("Neural Engine readings are not available on this Mac.")
            }
        }
    }
}

struct MemoryDetail: View {
    let memory: MemoryStats

    var body: some View {
        let parts: [(String, Double, Color)] = [
            ("App", memory.app, .orange),
            ("Wired", memory.wired, .red),
            ("Compressed", memory.compressed, .yellow),
            ("Cached files", memory.cached, .blue)
        ]

        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(parts.indices, id: \.self) { index in
                        Rectangle()
                            .fill(parts[index].2)
                            .frame(width: segmentWidth(parts[index].1, available: geometry.size.width))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)
            .padding(.bottom, 2)

            ForEach(parts.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Circle().fill(parts[index].2).frame(width: 7, height: 7)
                    InfoRow(parts[index].0, MonitorFormat.bytes(parts[index].1))
                }
            }
            InfoRow("Used", "\(MonitorFormat.bytes(memory.used)) of \(MonitorFormat.bytes(memory.total))")
            InfoRow("Free", MonitorFormat.bytes(memory.free))
            InfoRow("Swap used", MonitorFormat.bytes(memory.swapUsed))
            InfoRow("Pressure", memory.pressureLabel)
        }
    }

    private func segmentWidth(_ value: Double, available: CGFloat) -> CGFloat {
        guard memory.total > 0 else { return 0 }
        let width = available * CGFloat(value / memory.total) - 1
        return max(width, 0)
    }
}

struct DiskDetail: View {
    let disk: DiskStats

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            InfoRow("Read", MonitorFormat.rate(disk.readRate))
            InfoRow("Write", MonitorFormat.rate(disk.writeRate))
            if disk.volumeTotal > 0 {
                InfoRow("Startup disk free", "\(MonitorFormat.bytes(disk.volumeFree)) of \(MonitorFormat.bytes(disk.volumeTotal))")
            }
            if !disk.disks.isEmpty {
                SectionLabel("Per disk (read / write)")
                ForEach(disk.disks) { entry in
                    InfoRow(entry.id, "\(MonitorFormat.rate(entry.readRate))  /  \(MonitorFormat.rate(entry.writeRate))")
                }
            }
            MonitorNote("Graph: filled area is read, line is write.")
        }
    }
}

struct NetworkDetail: View {
    let network: NetworkStats

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            InfoRow("Download", MonitorFormat.rate(network.inRate))
            InfoRow("Upload", MonitorFormat.rate(network.outRate))
            if !network.interfaces.isEmpty {
                SectionLabel("Per interface (down / up)")
                ForEach(network.interfaces) { entry in
                    InfoRow(entry.address.map { "\(entry.id)  \($0)" } ?? entry.id,
                            "\(MonitorFormat.rate(entry.inRate))  /  \(MonitorFormat.rate(entry.outRate))")
                }
            }
            MonitorNote("Graph: filled area is download, line is upload.")
        }
    }
}

// MARK: - Footer

struct MonitorFooter: View {
    let embedded: Bool
    @EnvironmentObject var settings: MonitorSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Refresh")
                    .foregroundStyle(Color.secondary)
                Picker("Refresh", selection: $settings.interval) {
                    ForEach(MonitorSettings.intervals, id: \.self) { value in
                        Text("\(Int(value))s").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                Spacer()
                Text("\(settings.visible.count) of \(MonitorSettings.maxVisible) in menu bar")
                    .foregroundStyle(Color.secondary)
            }
            HStack(spacing: 12) {
                Text("Menu bar icons")
                    .foregroundStyle(Color.secondary)
                Toggle("Glyph", isOn: $settings.showGlyph)
                    .toggleStyle(.checkbox)
                    .help("Show each metric's symbol beside its graph")
                Toggle("Colour", isOn: $settings.colorGraphs)
                    .toggleStyle(.checkbox)
                    .help("Draw the menu bar graphs in colour")
                Spacer()
            }
            HStack {
                if !embedded {
                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.checkbox)
                }
                Spacer()
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                if !embedded {
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(12)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MenuPulse: could not change launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Building blocks

struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .padding(.top, 4)
    }
}

struct MonitorNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Label, horizontal bar and percentage on one line.
struct BarRow: View {
    let label: String
    let value: Double
    let color: Color
    let labelWidth: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            UsageBar(value: value, color: color)
            Text(MonitorFormat.percent(value))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

struct UsageBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// Small history graph: a filled area, plus an optional second series as a line.
struct Sparkline: View {
    let values: [Double]
    let secondary: [Double]?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.06))
                path(values, in: geometry.size, closed: true)
                    .fill(color.opacity(0.55))
                if let secondary {
                    path(secondary, in: geometry.size, closed: false)
                        .stroke(Color.primary.opacity(0.65), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private func path(_ series: [Double], in size: CGSize, closed: Bool) -> Path {
        var path = Path()
        guard series.count > 1 else { return path }

        let step = size.width / CGFloat(MonitorHistory.length - 1)
        let startX = size.width - step * CGFloat(series.count - 1)
        for (index, value) in series.enumerated() {
            let clamped = CGFloat(min(max(value, 0), 1))
            let point = CGPoint(x: startX + step * CGFloat(index), y: size.height * (1 - clamped))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        if closed {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: startX, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}
