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
    private var storeObserver: AnyCancellable?
    private var activationObserver: Any?

    /// What the key handler needs, shared with the key-handling thread.
    private struct State {
        /// bundleID → shortcuts, for quick lookup on every key press.
        var byApp: [String: [AppMenuShortcut]] = [:]
        /// "bundleID|path" for shortcuts the app currently shows in its own menu (handled natively).
        var nativeActive: Set<String> = []
        /// The frontmost app, kept up to date from activation notifications.
        var frontBundleID: String?
        var frontPID: pid_t = 0
    }
    private let state = Locked(State())

    private var byApp: [String: [AppMenuShortcut]] { state.get().byApp }

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
            self.state.update { st in
                st.nativeActive = st.nativeActive.filter { !$0.hasPrefix(bundleID + "|") }.union(active)
            }
        }
    }

    private static func key(_ s: AppMenuShortcut) -> String {
        s.bundleID + "|" + s.path.joined(separator: "\u{1b}")
    }

    private func rebuildLookup() {
        let lookup = Dictionary(grouping: AppShortcutStore.shared.items, by: { $0.bundleID })
        state.update { $0.byApp = lookup }
    }

    /// Tracks the frontmost app (CustomMacOS included) for the key handler, which can't ask
    /// NSWorkspace from its own thread.
    private func trackFrontmostApp() {
        guard activationObserver == nil else { return }
        let setFront = { [weak self] (app: NSRunningApplication?) in
            self?.state.update {
                $0.frontBundleID = app?.bundleIdentifier
                $0.frontPID = app?.processIdentifier ?? 0
            }
        }
        setFront(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            setFront(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
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
        trackFrontmostApp()
        tap = newTap
        // Handle keys on their own thread, so nothing on the main thread can delay typing.
        if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) {
            runLoopSource = src
            EventTapThread.shared.add(src)
        }
        CGEvent.tapEnable(tap: newTap, enable: true)
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
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return Unmanaged.passUnretained(event) }
        let st = state.get()
        guard let bundleID = st.frontBundleID,
              let mine = st.byApp[bundleID] else { return Unmanaged.passUnretained(event) }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var mods: UInt32 = 0
        if flags.contains(.maskCommand) { mods |= Shortcut.cmd }
        if flags.contains(.maskAlternate) { mods |= Shortcut.opt }
        if flags.contains(.maskControl) { mods |= Shortcut.ctrl }
        if flags.contains(.maskShift) { mods |= Shortcut.shift }

        guard let match = mine.first(where: { $0.shortcut.keyCode == keyCode && $0.shortcut.modifiers == mods }),
              !st.nativeActive.contains(Self.key(match)) else { return Unmanaged.passUnretained(event) }

        // Ours: swallow the key and press the menu item on the main thread.
        let pid = st.frontPID
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
