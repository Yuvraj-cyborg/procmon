// Shared model that every page observes. Owns the sampling loop.

import Foundation
import Observation

@MainActor
@Observable
final class Monitor {
    static let interval = Duration.seconds(1)
    /// Two minutes of history at one sample per second.
    static let historyLength = 120

    private(set) var latest: Snapshot?
    /// Number of samples taken so far; views key refreshes on it.
    private(set) var samples = 0
    private(set) var cpuHistory = History<Double>(capacity: historyLength)
    private(set) var memoryHistory = History<Double>(capacity: historyLength)
    private(set) var gpuHistory = History<Double>(capacity: historyLength)
    private(set) var receivedHistory = History<Double>(capacity: historyLength)
    private(set) var sentHistory = History<Double>(capacity: historyLength)

    @ObservationIgnored private var sampling: Task<Void, Never>?

    func start() {
        guard sampling == nil else { return }
        sampling = Task { [weak self] in
            let sampler = Sampler()
            while !Task.isCancelled {
                let snapshot = await sampler.sample()
                guard let self else { return }
                self.push(snapshot)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func push(_ snapshot: Snapshot) {
        cpuHistory.push(snapshot.cpu.total.value)
        memoryHistory.push(snapshot.memory.used.ratio(of: snapshot.memory.total).value)
        gpuHistory.push(snapshot.gpu?.utilization.value ?? 0)
        receivedHistory.push(Double(snapshot.network?.received.bytes.value ?? 0))
        sentHistory.push(Double(snapshot.network?.sent.bytes.value ?? 0))
        latest = snapshot
        samples += 1
    }

    func process(_ pid: PID) -> ProcessSample? {
        latest?.processes.first { $0.pid == pid }
    }
}
