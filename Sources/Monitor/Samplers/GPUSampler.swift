import Foundation
import IOKit

/// GPU utilisation from the IOAccelerator "PerformanceStatistics" dictionary.
/// This is the same source Activity Monitor's GPU history uses; no root needed.
final class GPUSampler {
    func sample() -> [GPUStats] {
        var result: [GPUStats] = []

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        var index = 0
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }

            func fraction(_ key: String) -> Double? {
                guard let number = stats[key] as? NSNumber else { return nil }
                return min(max(number.doubleValue / 100, 0), 1)
            }

            let utilization = fraction("Device Utilization %") ?? fraction("GPU Activity(%)") ?? 0
            let memory = (stats["In use system memory"] as? NSNumber)?.doubleValue

            result.append(GPUStats(id: index,
                                   name: name(of: entry) ?? "GPU \(index + 1)",
                                   utilization: utilization,
                                   renderer: fraction("Renderer Utilization %"),
                                   tiler: fraction("Tiler Utilization %"),
                                   memoryInUse: memory))
            index += 1
        }
        return result
    }

    private func name(of entry: io_registry_entry_t) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let value = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "model" as CFString, kCFAllocatorDefault, options)
        if let string = value as? String {
            return string
        }
        if let data = value as? Data {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
