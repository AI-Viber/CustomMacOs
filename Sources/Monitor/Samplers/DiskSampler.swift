import Foundation
import IOKit

/// Read/write throughput per physical disk from IOBlockStorageDriver counters.
final class DiskSampler {
    private var previous: [String: (read: UInt64, write: UInt64)] = [:]
    private var previousTime: TimeInterval = 0

    func sample() -> DiskStats {
        var stats = DiskStats()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime > 0 ? now - previousTime : 0
        var current: [String: (read: UInt64, write: UInt64)] = [:]

        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var index = 0
            while true {
                let entry = IOIteratorNext(iterator)
                if entry == 0 { break }
                defer { IOObjectRelease(entry) }
                index += 1

                guard let counters = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
                let read = (counters["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                let write = (counters["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0

                // The driver's child IOMedia object carries the BSD name (disk0, disk4...).
                let bsdName = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "BSD Name" as CFString,
                                                              kCFAllocatorDefault,
                                                              IOOptionBits(kIORegistryIterateRecursively)) as? String
                let name = bsdName ?? "disk #\(index)"
                current[name] = (read, write)

                var readRate = 0.0
                var writeRate = 0.0
                if let old = previous[name], elapsed > 0, read >= old.read, write >= old.write {
                    readRate = Double(read - old.read) / elapsed
                    writeRate = Double(write - old.write) / elapsed
                }
                stats.readRate += readRate
                stats.writeRate += writeRate
                stats.disks.append(DiskEntry(id: name, readRate: readRate, writeRate: writeRate,
                                             totalRead: Double(read), totalWritten: Double(write)))
            }
        }
        stats.disks.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        previous = current
        previousTime = now

        let root = URL(fileURLWithPath: "/")
        if let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            stats.volumeTotal = Double(values.volumeTotalCapacity ?? 0)
            stats.volumeFree = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
        }
        return stats
    }
}
