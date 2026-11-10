import Foundation

/// CPU / GPU / Neural Engine power from the SoC's "Energy Model" counters.
///
/// macOS has no public API for Neural Engine activity. The energy counters are
/// reachable without root through the private IOReport library, which is what
/// tools such as macmon and Stats use. The library is loaded at runtime so the
/// app still builds and runs (showing "n/a") where it is missing, e.g. on Intel.
final class PowerSampler {
    private typealias CopyChannelsFn = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UInt64, UInt64, UInt64) -> UnsafeRawPointer?
    private typealias SubscribeFn = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>?, UInt64, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias ThreePointerFn = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias StringFn = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias IntegerFn = @convention(c) (UnsafeRawPointer?, Int32) -> Int64

    private var createSamples: ThreePointerFn?
    private var createDelta: ThreePointerFn?
    private var getGroup: StringFn?
    private var getName: StringFn?
    private var getUnit: StringFn?
    private var getInteger: IntegerFn?

    private var subscription: UnsafeRawPointer?
    private var channels: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime: TimeInterval = 0
    private var last = PowerStats()

    init() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
              let subscribe = symbol("IOReportCreateSubscription", as: SubscribeFn.self),
              let samples = symbol("IOReportCreateSamples", as: ThreePointerFn.self),
              let delta = symbol("IOReportCreateSamplesDelta", as: ThreePointerFn.self),
              let group = symbol("IOReportChannelGetGroup", as: StringFn.self),
              let name = symbol("IOReportChannelGetChannelName", as: StringFn.self),
              let unit = symbol("IOReportChannelGetUnitLabel", as: StringFn.self),
              let integer = symbol("IOReportSimpleGetIntegerValue", as: IntegerFn.self)
        else { return }

        let groupName = "Energy Model" as CFString
        let rawChannels = withExtendedLifetime(groupName) {
            copyChannels(PowerSampler.pointer(groupName), nil, 0, 0, 0)
        }
        guard let rawChannels else { return }
        let found = Unmanaged<CFDictionary>.fromOpaque(rawChannels).takeRetainedValue()
        guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, found) else { return }

        var subscribed: UnsafeRawPointer?
        guard let sub = subscribe(nil, PowerSampler.pointer(mutable), &subscribed, 0, nil) else { return }

        // The subscription lives for the life of the app, so it is never released.
        subscription = sub
        channels = mutable
        createSamples = samples
        createDelta = delta
        getGroup = group
        getName = name
        getUnit = unit
        getInteger = integer
    }

    func sample() -> PowerStats {
        guard let createSamples, let createDelta, let getGroup, let getName, let getUnit, let getInteger,
              let subscription, let channels else {
            return PowerStats()
        }
        guard let rawCurrent = createSamples(subscription, PowerSampler.pointer(channels), nil) else { return last }
        let current = Unmanaged<CFDictionary>.fromOpaque(rawCurrent).takeRetainedValue()
        let now = ProcessInfo.processInfo.systemUptime
        let old = previous
        let elapsed = now - previousTime
        previous = current
        previousTime = now

        guard let old, elapsed > 0 else {
            last.available = true
            return last
        }
        guard let rawDelta = createDelta(PowerSampler.pointer(old), PowerSampler.pointer(current), nil) else { return last }
        let delta = Unmanaged<CFDictionary>.fromOpaque(rawDelta).takeRetainedValue() as NSDictionary
        guard let items = delta["IOReportChannels"] as? [NSDictionary] else { return last }

        var stats = PowerStats()
        stats.available = true

        for item in items {
            let pointer = PowerSampler.pointer(item)
            guard string(getGroup, pointer) == "Energy Model" else { continue }
            let name = string(getName, pointer)
            let unit = string(getUnit, pointer).trimmingCharacters(in: .whitespaces)

            let divisor: Double
            switch unit {
            case "mJ": divisor = 1e3
            case "uJ", "µJ": divisor = 1e6
            case "nJ": divisor = 1e9
            default: continue
            }
            let watts = Double(getInteger(pointer, 0)) / divisor / elapsed

            if name == "GPU Energy" {
                stats.gpuWatts += watts
            } else if name.hasSuffix("CPU Energy") {
                stats.cpuWatts += watts
            } else if name.hasPrefix("ANE") {
                stats.aneWatts += watts
                stats.hasANE = true
            }
        }
        last = stats
        return stats
    }

    private func string(_ function: StringFn, _ pointer: UnsafeRawPointer) -> String {
        guard let raw = function(pointer) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func pointer(_ object: AnyObject) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
    }
}
