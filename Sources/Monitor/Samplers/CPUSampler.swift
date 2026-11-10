import Darwin
import Foundation

/// Reads an integer sysctl value (works for both 32- and 64-bit values).
func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

/// Aggregate and per-core CPU usage from the kernel's tick counters.
final class CPUSampler {
    private var previous: [[UInt32]] = []
    private let efficiencyCount: Int
    private let performanceCount: Int

    init() {
        // Apple Silicon reports two "performance levels": 0 = P cores, 1 = E cores.
        if (sysctlInt("hw.nperflevels") ?? 1) >= 2 {
            performanceCount = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
            efficiencyCount = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        } else {
            performanceCount = 0
            efficiencyCount = 0
        }
    }

    func sample() -> CPUStats {
        var stats = CPUStats()

        var cpuCount: natural_t = 0
        var infoPointer: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &infoPointer, &infoCount)
        guard result == KERN_SUCCESS, let info = infoPointer else { return stats }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            _ = vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        let states = Int(CPU_STATE_MAX)
        let userIndex = Int(CPU_STATE_USER)
        let systemIndex = Int(CPU_STATE_SYSTEM)
        let idleIndex = Int(CPU_STATE_IDLE)
        let niceIndex = Int(CPU_STATE_NICE)

        var current: [[UInt32]] = []
        current.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            var ticks = [UInt32](repeating: 0, count: states)
            for state in 0..<states {
                ticks[state] = UInt32(bitPattern: info[cpu * states + state])
            }
            current.append(ticks)
        }

        if previous.count == current.count {
            var sumUser = 0.0
            var sumSystem = 0.0
            var sumAll = 0.0
            let labelCores = efficiencyCount + performanceCount == current.count && efficiencyCount > 0

            for (index, ticks) in current.enumerated() {
                let old = previous[index]
                // Counters are 32-bit and wrap, so subtract with overflow.
                let user = Double(ticks[userIndex] &- old[userIndex]) + Double(ticks[niceIndex] &- old[niceIndex])
                let system = Double(ticks[systemIndex] &- old[systemIndex])
                let idle = Double(ticks[idleIndex] &- old[idleIndex])
                let all = user + system + idle
                let usage = all > 0 ? (user + system) / all : 0

                sumUser += user
                sumSystem += system
                sumAll += all

                // On Apple Silicon the efficiency cores are listed first.
                let label: String
                if labelCores {
                    label = index < efficiencyCount ? "E\(index + 1)" : "P\(index - efficiencyCount + 1)"
                } else {
                    label = "\(index + 1)"
                }
                stats.cores.append(CoreStats(id: index, label: label, usage: usage))
            }

            if sumAll > 0 {
                stats.user = sumUser / sumAll
                stats.system = sumSystem / sumAll
                stats.total = (sumUser + sumSystem) / sumAll
            }
        }
        previous = current

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 {
            stats.loadAverage = load
        }
        return stats
    }
}
