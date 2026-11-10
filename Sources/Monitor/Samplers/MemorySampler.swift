import Darwin
import Foundation

/// Memory breakdown matching Activity Monitor's categories.
final class MemorySampler {
    func sample() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = Double(ProcessInfo.processInfo.physicalMemory)

        var pageSizeValue: vm_size_t = 0
        _ = host_page_size(mach_host_self(), &pageSizeValue)
        let pageSize = Double(pageSizeValue)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        if result == KERN_SUCCESS {
            let purgeable = Double(vm.purgeable_count)
            stats.app = max(Double(vm.internal_page_count) - purgeable, 0) * pageSize
            stats.wired = Double(vm.wire_count) * pageSize
            stats.compressed = Double(vm.compressor_page_count) * pageSize
            stats.cached = (Double(vm.external_page_count) + purgeable) * pageSize
            stats.free = max(stats.total - stats.used - stats.cached, 0)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            stats.swapUsed = Double(swap.xsu_used)
            stats.swapTotal = Double(swap.xsu_total)
        }

        stats.pressureLevel = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 0
        return stats
    }
}
