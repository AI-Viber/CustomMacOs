import Foundation

/// A dedicated, high-priority thread for CustomMacOS's keyboard event taps.
///
/// Every key press passes through an event tap before reaching any app. If the tap ran on
/// the main thread, anything else the main thread was doing (redrawing menu bar icons,
/// moving windows, reading menus) would hold up typing, and a key release held up long
/// enough makes macOS start auto-repeating the key, giving double letters. On its own
/// thread, a tap answers immediately whatever the rest of the app is doing.
final class EventTapThread {
    static let shared = EventTapThread()

    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    private init() {
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            // A run loop with no sources returns at once; keep a port so it waits for work.
            let keepAlive = NSMachPort()
            RunLoop.current.add(keepAlive, forMode: .common)
            self?.ready.signal()
            while true {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "CustomMacOS key handling"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// Adds an event tap's run loop source. Safe to call from any thread.
    func add(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }

    /// Removes an event tap's run loop source. Safe to call from any thread.
    func remove(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }
}

/// A value shared between the main thread and the key-handling thread.
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&value)
        lock.unlock()
    }
}
