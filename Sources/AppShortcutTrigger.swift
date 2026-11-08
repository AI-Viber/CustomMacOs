import AppKit
import Combine

/// Remembers the last app other than CustomMacOS that was in front, so the
/// "Add Shortcut to Menu Item…" command knows which app to work on even after
/// CustomMacOS's own window has been brought forward.
final class ActiveAppTracker {
    static let shared = ActiveAppTracker()
    private(set) var lastExternalApp: NSRunningApplication?
    private var observer: Any?

    func start() {
        guard observer == nil else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me {
            lastExternalApp = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != me else { return }
            self?.lastExternalApp = app
            AppShortcutTrigger.shared.refresh(for: app)
            // A freshly launched app may still be building its menus; check again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AppShortcutTrigger.shared.refresh(for: app) }
        }
    }

    /// The app the user means: the frontmost one, or the last one before CustomMacOS came forward.
    var targetApp: NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { return front }
        if let last = lastExternalApp, !last.isTerminated { return last }
        return nil
    }
}

/// The CustomMacOS half of app shortcuts: watches key presses and, when one matches a
/// shortcut assigned to the frontmost app, presses that menu item directly.
///
/// Once the app has been reopened and picked the shortcut up from macOS App Shortcuts,
/// the app handles it itself and CustomMacOS stands aside, so nothing runs twice.
final class AppShortcutTrigger {
    static let shared = AppShortcutTrigger()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// bundleID → shortcuts, for quick lookup on every key press.
    private var byApp: [String: [AppMenuShortcut]] = [:]
    /// "bundleID|path" for shortcuts the app currently shows in its own menu (handled natively).
    private var nativeActive: Set<String> = []
    private var storeObserver: AnyCancellable?

    /// Starts or stops watching keys depending on whether any app shortcuts exist.
    func update() {
        if storeObserver == nil {
            storeObserver = AppShortcutStore.shared.$items
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.update() }
        }
        rebuildLookup()
        if byApp.isEmpty || !AXIsProcessTrusted() {
            stopTap()
        } else {
            startTap()
            if let front = NSWorkspace.shared.frontmostApplication { refresh(for: front) }
        }
    }

    func stop() { stopTap() }

    /// Re-checks which of this app's shortcuts it already handles natively.
    func refresh(for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, let mine = byApp[bundleID], !mine.isEmpty else { return }
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            var active = Set<String>()
            for s in mine {
                if let item = MenuReader.findItem(pid: pid, path: s.path),
                   MenuReader.shortcut(of: item) == s.shortcut {
                    active.insert(Self.key(s))
                }
            }
            DispatchQueue.main.async {
                self.nativeActive = self.nativeActive.filter { !$0.hasPrefix(bundleID + "|") }.union(active)
            }
        }
    }

    private static func key(_ s: AppMenuShortcut) -> String {
        s.bundleID + "|" + s.path.joined(separator: "\u{1b}")
    }

    private func rebuildLookup() {
        byApp = Dictionary(grouping: AppShortcutStore.shared.items, by: { $0.bundleID })
    }

    // MARK: Event tap

    private func startTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<AppShortcutTrigger>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                             options: .defaultTap, eventsOfInterest: mask,
                                             callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            DiagnosticsLog.append("appshortcuts", "could not create key watcher (Accessibility permission?)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        runLoopSource = src
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              let mine = byApp[bundleID] else { return Unmanaged.passUnretained(event) }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var mods: UInt32 = 0
        if flags.contains(.maskCommand) { mods |= Shortcut.cmd }
        if flags.contains(.maskAlternate) { mods |= Shortcut.opt }
        if flags.contains(.maskControl) { mods |= Shortcut.ctrl }
        if flags.contains(.maskShift) { mods |= Shortcut.shift }

        guard let match = mine.first(where: { $0.shortcut.keyCode == keyCode && $0.shortcut.modifiers == mods }),
              !nativeActive.contains(Self.key(match)) else { return Unmanaged.passUnretained(event) }

        // Ours: swallow the key and press the menu item (off the event tap's thread of control).
        let pid = front.processIdentifier
        DispatchQueue.main.async { Self.press(match, pid: pid) }
        return nil
    }

    private static func press(_ s: AppMenuShortcut, pid: pid_t) {
        guard let item = MenuReader.findItem(pid: pid, path: s.path) else {
            DiagnosticsLog.append("appshortcuts", "\(s.appName): menu item not found: \(s.pathDisplay)")
            NSSound.beep()
            return
        }
        guard MenuReader.isEnabled(item) else {
            NSSound.beep()  // same as pressing a greyed-out item's shortcut
            return
        }
        let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if err != .success {
            DiagnosticsLog.append("appshortcuts", "\(s.appName): pressing \(s.pathDisplay) failed (\(err.rawValue))")
        }
    }
}
