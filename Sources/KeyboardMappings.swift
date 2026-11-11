import Foundation
import IOKit
import IOKit.hid
import Combine

/// A keyboard attached to this Mac.
struct KeyboardInfo: Identifiable, Hashable {
    let vendorID: Int
    let productID: Int
    let name: String
    let builtIn: Bool
    let transport: String

    /// Identifies the model of keyboard, so the setting follows it between ports and reconnects.
    var id: String { "\(vendorID):\(productID)" }
    var isApple: Bool { vendorID == 0x05AC || vendorID == 0x004C }

    var detail: String {
        if builtIn { return "Built-in keyboard" }
        let kind = isApple ? "Apple keyboard" : "PC / Windows-layout keyboard"
        return transport.isEmpty ? kind : "\(kind) · \(transport)"
    }
}

/// A keyboard with the swap turned on that isn't plugged in right now.
struct RememberedKeyboard: Identifiable {
    let id: String
    let name: String
}

/// Owns the low-level (HID) key remapping for all keyboards:
///  • Caps Lock → F18 on every keyboard, when Caps Lock remapping is on (see KeyRemapper).
///  • Option ↔ Command swapped on the keyboards the user picked, for Windows/PC keyboards
///    where Alt sits where ⌘ Command is on a Mac keyboard.
///
/// The swap is done with `hidutil` on that keyboard only, the same mechanism as System Settings
/// → Keyboard → Modifier Keys, so it works everywhere (including password fields) and needs no
/// Accessibility permission. Choices are stored in this Mac's preferences only, so each Mac
/// keeps its own list. Keyboards are re-mapped automatically when they're plugged in.
final class KeyboardMappings: ObservableObject {
    static let shared = KeyboardMappings()

    @Published private(set) var connected: [KeyboardInfo] = []
    /// Keyboard id → name, for every keyboard the user turned the swap on for.
    @Published private(set) var swapped: [String: String]

    private var capsToF18 = false
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pendingRefresh: DispatchWorkItem?
    private let swappedKey = "swapOptionCommandKeyboards"

    // HID keyboard usages (page 7) as hidutil expects them: 0x700000000 | usage.
    private static func usage(_ u: Int) -> Int { 0x7_0000_0000 | u }
    private static let capsLock = usage(0x39), f18 = usage(0x6D)
    private static let leftOption = usage(0xE2), leftCommand = usage(0xE3)
    private static let rightOption = usage(0xE6), rightCommand = usage(0xE7)

    private init() {
        swapped = (UserDefaults.standard.dictionary(forKey: "swapOptionCommandKeyboards") as? [String: String]) ?? [:]
    }

    // MARK: Public

    /// Starts watching for keyboards being connected and applies the current mappings.
    func start() {
        guard notifyPort == nil else { return }
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            notifyPort = port
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOServiceMatchingCallback = { refcon, iterator in
                KeyboardMappings.drain(iterator)
                guard let refcon else { return }
                Unmanaged<KeyboardMappings>.fromOpaque(refcon).takeUnretainedValue().devicesChanged()
            }
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                if IOServiceAddMatchingNotification(port, type, IOServiceMatching(kIOHIDDeviceKey),
                                                    callback, refcon, &iterator) == KERN_SUCCESS {
                    Self.drain(iterator)  // arms the notification
                    iterators.append(iterator)
                }
            }
        }
        refresh()
    }

    /// Called by KeyRemapper when Caps Lock remapping turns on or off.
    func setCapsToF18(_ on: Bool) {
        capsToF18 = on
        apply()
    }

    func isSwapped(_ id: String) -> Bool { swapped[id] != nil }

    func setSwap(_ on: Bool, id: String, name: String) {
        var updated = swapped
        if on { updated[id] = name } else { updated.removeValue(forKey: id) }
        swapped = updated
        UserDefaults.standard.set(updated, forKey: swappedKey)
        apply()
    }

    /// Keyboards with the swap on that aren't connected now (so they can still be turned off).
    var rememberedNotConnected: [RememberedKeyboard] {
        let here = Set(connected.map(\.id))
        return swapped.filter { !here.contains($0.key) }
            .map { RememberedKeyboard(id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// Removes every mapping, putting all keyboards back to normal (used when quitting).
    func shutdown() {
        capsToF18 = false
        hidutil(matching: nil, mappings: [])
        for kb in connected { hidutil(matching: kb, mappings: []) }
    }

    // MARK: Applying

    func apply() {
        let caps: [(Int, Int)] = capsToF18 ? [(Self.capsLock, Self.f18)] : []
        let swap: [(Int, Int)] = [(Self.leftOption, Self.leftCommand), (Self.leftCommand, Self.leftOption),
                                  (Self.rightOption, Self.rightCommand), (Self.rightCommand, Self.rightOption)]
        // All keyboards first; then each connected keyboard explicitly, so a keyboard that had
        // the swap turned off is reset rather than keeping its old mapping.
        hidutil(matching: nil, mappings: caps)
        for kb in connected {
            hidutil(matching: kb, mappings: isSwapped(kb.id) ? caps + swap : caps)
        }
        let names = connected.filter { isSwapped($0.id) }.map(\.name)
        DiagnosticsLog.append("keyboard", "applied: capsToF18=\(capsToF18), Option/Command swapped on \(names.isEmpty ? "none" : names.joined(separator: ", "))")
    }

    private func hidutil(matching kb: KeyboardInfo?, mappings: [(Int, Int)]) {
        let entries = mappings.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.0),\"HIDKeyboardModifierMappingDst\":\($0.1)}"
        }
        var args = ["property"]
        if let kb {
            args += ["--matching", "{\"VendorID\":\(kb.vendorID),\"ProductID\":\(kb.productID)}"]
        }
        args += ["--set", "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            DiagnosticsLog.append("keyboard", "hidutil failed: \(error)")
        }
    }

    // MARK: Finding keyboards

    private func devicesChanged() {
        // Devices arrive in bursts (one keyboard can register several HID interfaces),
        // and a new one needs a moment before it accepts a mapping.
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func refresh() {
        connected = Self.scanKeyboards()
        apply()
    }

    private static func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private static func scanKeyboards() -> [KeyboardInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [String: KeyboardInfo] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard isKeyboard(service),
                  let vendor = property(service, kIOHIDVendorIDKey) as? Int,
                  let product = property(service, kIOHIDProductIDKey) as? Int else { continue }
            let transport = (property(service, kIOHIDTransportKey) as? String) ?? ""
            // Skip software keyboards (e.g. Karabiner's virtual keyboard, remote-control apps).
            if transport.caseInsensitiveCompare("Virtual") == .orderedSame { continue }
            let name = (property(service, kIOHIDProductKey) as? String) ?? "Keyboard"
            let builtIn = (property(service, "Built-In") as? Bool)
                ?? ["SPI", "FIFO", "AID"].contains(transport.uppercased())
            let kb = KeyboardInfo(vendorID: vendor, productID: product, name: name,
                                  builtIn: builtIn, transport: transport)
            if found[kb.id] == nil { found[kb.id] = kb }
        }
        return found.values.sorted {
            if $0.builtIn != $1.builtIn { return $0.builtIn }  // built-in first
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// True for devices whose usages include Generic Desktop / Keyboard (page 1, usage 6).
    private static func isKeyboard(_ service: io_service_t) -> Bool {
        if (property(service, kIOHIDPrimaryUsagePageKey) as? Int) == 1,
           (property(service, kIOHIDPrimaryUsageKey) as? Int) == 6 {
            return true
        }
        let pairs = (property(service, kIOHIDDeviceUsagePairsKey) as? [[String: Any]]) ?? []
        return pairs.contains {
            ($0[kIOHIDDeviceUsagePageKey] as? Int) == 1 && ($0[kIOHIDDeviceUsageKey] as? Int) == 6
        }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
