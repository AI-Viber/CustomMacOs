import AppKit
import IOKit
import IOKit.hidsystem

/// Karabiner-style Caps Lock handling.
///
/// macOS handles Caps Lock below the level an event tap can intercept, so we first
/// use `hidutil` to remap the physical Caps Lock key to F18, then an event tap turns
/// F18 into Hyper (⌃⌥⇧⌘) when held, Escape when tapped, and real Caps Lock with Shift.
/// The hidutil mapping is cleared when the app quits.
final class KeyRemapper {
    static let shared = KeyRemapper()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Settings the key handler needs, copied here so it never reads AppSettings from the
    /// key-handling thread.
    private struct Config {
        var mode: CapsLockMode = .off
        var shiftCapsTogglesCapsLock = true
    }
    private let config = Locked(Config())

    // Only touched on the key-handling thread.
    private var hyperDown = false
    private var hyperUsed = false
    private var hyperDownAt: TimeInterval = 0
    private var swallowNextCapsUp = false

    private let syntheticMarker: Int64 = 0x434D_4F53 // 'CMOS'
    private let f18: Int64 = 79
    private let escapeKey: CGKeyCode = 53
    private let tapTimeout: TimeInterval = 0.5
    private let hyperFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    func apply(_ mode: CapsLockMode) {
        settingsChanged(mode: mode)
        if mode == .off {
            stopTap()
            setHIDMapping(enabled: false)
            return
        }
        // Only remap the physical key once we can actually handle F18; otherwise Caps Lock would go dead.
        if startTap() {
            setHIDMapping(enabled: true)
        } else {
            setHIDMapping(enabled: false)
        }
    }

    /// Copies the settings the key handler uses. Call when they change.
    func settingsChanged(mode: CapsLockMode? = nil) {
        let settings = AppSettings.shared
        config.set(Config(mode: mode ?? settings.capsLockMode,
                          shiftCapsTogglesCapsLock: settings.shiftCapsTogglesCapsLock))
    }

    func shutdown() {
        stopTap()
        setHIDMapping(enabled: false)
    }

    // MARK: hidutil

    private func setHIDMapping(enabled: Bool) {
        // Caps Lock → F18 is applied by KeyboardMappings, together with any per-keyboard
        // Option/Command swaps, so the two never overwrite each other.
        KeyboardMappings.shared.setCapsToF18(enabled)
    }

    // MARK: Event tap

    @discardableResult
    private func startTap() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyRemapper>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: CGEventMask(mask),
                                             callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("CustomMacOS: event tap unavailable (Accessibility permission missing?)")
            return false
        }
        tap = newTap
        hyperDown = false  // the tap isn't running yet, so this can't race the key handler
        // Handle keys on their own thread, so nothing on the main thread can delay typing.
        if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) {
            runLoopSource = src
            EventTapThread.shared.add(src)
        }
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { EventTapThread.shared.remove(runLoopSource) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }

        let cfg = config.get()
        let mode = cfg.mode
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if code == f18 {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown {
                // Shift + Caps Lock → real Caps Lock
                if !isRepeat && !hyperDown && cfg.shiftCapsTogglesCapsLock && event.flags.contains(.maskShift) {
                    CapsLock.toggle()
                    swallowNextCapsUp = true
                    return nil
                }
                if swallowNextCapsUp { return nil }
                if mode == .escape {
                    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(escapeKey))
                    return Unmanaged.passUnretained(event)
                }
                if isRepeat { return nil }
                hyperDown = true
                hyperUsed = false
                hyperDownAt = ProcessInfo.processInfo.systemUptime
                return nil
            } else {
                if swallowNextCapsUp {
                    swallowNextCapsUp = false
                    return nil
                }
                if mode == .escape {
                    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(escapeKey))
                    return Unmanaged.passUnretained(event)
                }
                let wasTap = hyperDown && !hyperUsed
                    && ProcessInfo.processInfo.systemUptime - hyperDownAt < tapTimeout
                hyperDown = false
                if mode == .hyperEscape && wasTap { postEscape() }
                return nil
            }
        }

        if hyperDown {
            if type == .keyDown { hyperUsed = true }
            event.flags = event.flags.union(hyperFlags)
        }
        return Unmanaged.passUnretained(event)
    }

    private func postEscape() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: escapeKey, keyDown: down) else { continue }
            e.flags = []
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            e.post(tap: .cgSessionEventTap)
        }
    }
}

enum CapsLock {
    /// Flips the system Caps Lock state (and its LED) directly through IOHIDSystem.
    static func toggle() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        // 1 = kIOHIDParamConnectType
        guard IOServiceOpen(service, mach_task_self_, 1, &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        var on = false
        // 1 = kIOHIDCapsLockState
        IOHIDGetModifierLockState(connect, 1, &on)
        IOHIDSetModifierLockState(connect, 1, !on)
    }
}
