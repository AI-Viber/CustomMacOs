import Darwin
import Foundation

/// Per-interface network throughput from the interface byte counters.
final class NetworkSampler {
    private var previous: [String: (input: UInt32, output: UInt32)] = [:]
    private var previousTime: TimeInterval = 0

    func sample() -> NetworkStats {
        var stats = NetworkStats()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime > 0 ? now - previousTime : 0

        var counters: [String: (input: UInt32, output: UInt32)] = [:]
        var addresses: [String: String] = [:]

        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return stats }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr else { continue }
            if Int32(interface.ifa_flags) & IFF_LOOPBACK != 0 { continue }
            let name = String(cString: interface.ifa_name)
            let family = Int32(address.pointee.sa_family)

            if family == AF_LINK, let data = interface.ifa_data {
                let info = data.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = (info.ifi_ibytes, info.ifi_obytes)
            } else if family == AF_INET {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = String(cString: host)
                }
            }
        }

        for (name, value) in counters {
            var inRate = 0.0
            var outRate = 0.0
            if let old = previous[name], elapsed > 0 {
                // These counters are 32-bit and wrap every 4 GB, so subtract with overflow.
                inRate = Double(value.input &- old.input) / elapsed
                outRate = Double(value.output &- old.output) / elapsed
            }

            // Only physical links count towards the total, otherwise VPN
            // traffic would be counted twice (once on utun, once on en0).
            let physical = name.hasPrefix("en") || name.hasPrefix("pdp_ip")
            if physical {
                stats.inRate += inRate
                stats.outRate += outRate
            }

            let hasAddress = addresses[name] != nil
            let hasTraffic = value.input > 0 || value.output > 0
            if hasAddress || (physical && hasTraffic) {
                stats.interfaces.append(InterfaceEntry(id: name, address: addresses[name],
                                                       inRate: inRate, outRate: outRate,
                                                       totalIn: Double(value.input), totalOut: Double(value.output)))
            }
        }
        stats.interfaces.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        previous = counters
        previousTime = now
        return stats
    }
}
