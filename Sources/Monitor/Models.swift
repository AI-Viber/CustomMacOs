import Foundation

/// The six things MenuPulse can measure.
enum MetricKind: String, CaseIterable, Identifiable {
    case cpu, gpu, ane, memory, disk, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ane: return "Neural Engine"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        }
    }

    /// SF Symbol used in the menu bar and in the dropdown.
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .ane: return "brain"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        }
    }

    /// Text drawn in the menu bar if the symbol is unavailable.
    var shortLabel: String {
        switch self {
        case .cpu: return "C"
        case .gpu: return "G"
        case .ane: return "N"
        case .memory: return "M"
        case .disk: return "D"
        case .network: return "W"
        }
    }

    /// Disk and network show two series (read/write, down/up).
    var isDual: Bool { self == .disk || self == .network }
}

// MARK: - Per-metric readings

struct CoreStats: Identifiable {
    let id: Int
    var label: String
    var usage: Double
}

struct CPUStats {
    var total = 0.0
    var user = 0.0
    var system = 0.0
    var cores: [CoreStats] = []
    var loadAverage: [Double] = []
}

struct GPUStats: Identifiable {
    let id: Int
    var name: String
    var utilization: Double
    var renderer: Double?
    var tiler: Double?
    var memoryInUse: Double?
}

/// Power draw from the SoC energy counters (Apple Silicon only).
struct PowerStats {
    var available = false
    var hasANE = false
    var cpuWatts = 0.0
    var gpuWatts = 0.0
    var aneWatts = 0.0

    /// The Neural Engine exposes no utilisation figure, only energy use.
    /// Load is estimated against this nominal full-load power.
    static let aneFullLoadWatts = 8.0

    var aneLoad: Double { min(max(aneWatts / PowerStats.aneFullLoadWatts, 0), 1) }
}

struct MemoryStats {
    var total = 0.0
    var app = 0.0
    var wired = 0.0
    var compressed = 0.0
    var cached = 0.0
    var free = 0.0
    var swapUsed = 0.0
    var swapTotal = 0.0
    var pressureLevel = 0

    var used: Double { app + wired + compressed }
    var usedFraction: Double { total > 0 ? min(used / total, 1) : 0 }

    var pressureLabel: String {
        switch pressureLevel {
        case 1: return "Normal"
        case 2: return "Warning"
        case 4: return "Critical"
        default: return "Unknown"
        }
    }
}

struct DiskEntry: Identifiable {
    let id: String
    var readRate: Double
    var writeRate: Double
    var totalRead: Double
    var totalWritten: Double
}

struct DiskStats {
    var readRate = 0.0
    var writeRate = 0.0
    var disks: [DiskEntry] = []
    var volumeTotal = 0.0
    var volumeFree = 0.0
}

struct InterfaceEntry: Identifiable {
    let id: String
    var address: String?
    var inRate: Double
    var outRate: Double
    var totalIn: Double
    var totalOut: Double
}

struct NetworkStats {
    var inRate = 0.0
    var outRate = 0.0
    var interfaces: [InterfaceEntry] = []
}

// MARK: - MonitorSnapshot

struct MonitorSnapshot {
    var cpu = CPUStats()
    var gpus: [GPUStats] = []
    var power = PowerStats()
    var memory = MemoryStats()
    var disk = DiskStats()
    var network = NetworkStats()

    var gpuUtilization: Double { gpus.map(\.utilization).max() ?? 0 }

    /// Short text shown at the right of each row and in tooltips.
    func summary(for kind: MetricKind) -> String {
        switch kind {
        case .cpu:
            return MonitorFormat.percent(cpu.total)
        case .gpu:
            return gpus.isEmpty ? "n/a" : MonitorFormat.percent(gpuUtilization)
        case .ane:
            return power.hasANE ? MonitorFormat.watts(power.aneWatts) : "n/a"
        case .memory:
            return MonitorFormat.percent(memory.usedFraction)
        case .disk:
            return "R \(MonitorFormat.compact(disk.readRate))  W \(MonitorFormat.compact(disk.writeRate))"
        case .network:
            return "↓\(MonitorFormat.compact(network.inRate))  ↑\(MonitorFormat.compact(network.outRate))"
        }
    }
}

// MARK: - MonitorHistory

/// Rolling history used for the menu bar graphs and the row sparklines.
struct MonitorHistory {
    static let length = 60

    var cpu: [Double] = []
    var gpu: [Double] = []
    var ane: [Double] = []
    var memory: [Double] = []
    var diskRead: [Double] = []
    var diskWrite: [Double] = []
    var netIn: [Double] = []
    var netOut: [Double] = []

    mutating func push(_ keyPath: WritableKeyPath<MonitorHistory, [Double]>, _ value: Double) {
        self[keyPath: keyPath].append(value)
        let extra = self[keyPath: keyPath].count - MonitorHistory.length
        if extra > 0 {
            self[keyPath: keyPath].removeFirst(extra)
        }
    }

    /// Series scaled to 0...1. Rates are scaled to the busiest moment in the
    /// window, with a floor so idle background chatter does not fill the graph.
    func normalized(_ kind: MetricKind) -> (primary: [Double], secondary: [Double]?) {
        switch kind {
        case .cpu: return (cpu, nil)
        case .gpu: return (gpu, nil)
        case .ane: return (ane, nil)
        case .memory: return (memory, nil)
        case .disk: return MonitorHistory.scale(diskRead, diskWrite, floor: 1_048_576)
        case .network: return MonitorHistory.scale(netIn, netOut, floor: 131_072)
        }
    }

    private static func scale(_ a: [Double], _ b: [Double], floor: Double) -> (primary: [Double], secondary: [Double]?) {
        let peak = max(a.max() ?? 0, b.max() ?? 0, floor)
        return (a.map { $0 / peak }, b.map { $0 / peak })
    }
}

// MARK: - Formatting

enum MonitorFormat {
    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }

    static func watts(_ value: Double) -> String {
        String(format: "%.2f W", value)
    }

    private static func scaled(_ value: Double) -> (Double, Int) {
        var v = max(value, 0)
        var index = 0
        while v >= 1024 && index < 4 {
            v /= 1024
            index += 1
        }
        return (v, index)
    }

    /// "1.2 GB"
    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        let (v, i) = scaled(value)
        let number = (i == 0 || v >= 100) ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return number + " " + units[i]
    }

    /// "1.2 MB/s"
    static func rate(_ value: Double) -> String {
        bytes(value) + "/s"
    }

    /// "1.2M" - per-second rate squeezed for the row summaries.
    static func compact(_ value: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        let (v, i) = scaled(value)
        let number = (i == 0 || v >= 10) ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return number + units[i]
    }
}
