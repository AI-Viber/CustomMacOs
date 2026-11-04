import Carbon

/// Registers global shortcuts with the Carbon hot key API (works system-wide, no polling).
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var suspended = false
    private var installed = false

    func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hkID)
            if status == noErr {
                HotkeyManager.shared.fire(hkID.id)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Re-registers every shortcut from settings.
    func registerAll() {
        unregisterAll()
        guard !suspended else { return }
        for (action, shortcut) in AppSettings.shared.shortcuts {
            register(shortcut) { WindowManager.shared.perform(action) }
        }
        if AppSettings.shared.menuBarHiderEnabled, let s = AppSettings.shared.menuBarShortcut {
            register(s) {
                if MenuBarHider.isSupported {
                    MenuBarHider.shared.toggle()
                } else {
                    NativeOverflowToggle.shared.toggle()
                }
            }
        }
    }

    /// Used while recording a new shortcut so the old one doesn't fire.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        registerAll()
    }

    private func register(_ s: Shortcut, action: @escaping () -> Void) {
        let id = EventHotKeyID(signature: OSType(0x434D_4F53), id: nextID) // 'CMOS'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            handlers[nextID] = action
        } else {
            NSLog("CustomMacOS: could not register \(s.displayString) (status \(status)) – probably taken by another app")
        }
        nextID += 1
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }
}
