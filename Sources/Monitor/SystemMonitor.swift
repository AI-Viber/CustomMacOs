import Combine
import Foundation

/// Polls every sampler on a timer and publishes the latest readings.
///
/// Sampling runs on a background queue so it never delays the main thread,
/// which matters when the host app also handles keyboard events there.
/// Only the finished result is handed to the main thread.
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = MonitorSnapshot()
    @Published private(set) var history = MonitorHistory()

    /// Called on the main thread after each refresh so icons can be redrawn.
    var onUpdate: (() -> Void)?

    private(set) var isRunning = false

    private let queue = DispatchQueue(label: "MenuPulse.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Touched only on `queue`.
    private var workingHistory = MonitorHistory()
    private let cpuSampler = CPUSampler()
    private let gpuSampler = GPUSampler()
    private let powerSampler = PowerSampler()
    private let memorySampler = MemorySampler()
    private let diskSampler = DiskSampler()
    private let networkSampler = NetworkSampler()

    func start(interval: TimeInterval) {
        stop()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            self?.sample()
        }
        source.resume()
        timer = source
        isRunning = true
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    /// Runs on `queue`.
    private func sample() {
        var next = MonitorSnapshot()
        next.cpu = cpuSampler.sample()
        next.gpus = gpuSampler.sample()
        next.power = powerSampler.sample()
        next.memory = memorySampler.sample()
        next.disk = diskSampler.sample()
        next.network = networkSampler.sample()

        workingHistory.push(\.cpu, next.cpu.total)
        workingHistory.push(\.gpu, next.gpuUtilization)
        workingHistory.push(\.ane, next.power.aneLoad)
        workingHistory.push(\.memory, next.memory.usedFraction)
        workingHistory.push(\.diskRead, next.disk.readRate)
        workingHistory.push(\.diskWrite, next.disk.writeRate)
        workingHistory.push(\.netIn, next.network.inRate)
        workingHistory.push(\.netOut, next.network.outRate)

        let result = next
        let updated = workingHistory
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = result
            self.history = updated
            self.onUpdate?()
        }
    }
}
