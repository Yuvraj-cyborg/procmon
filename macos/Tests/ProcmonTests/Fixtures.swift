@testable import Procmon

extension ProcessSample {
    /// A process for tests; `memory: nil` makes it one Procmon may not inspect.
    static func fixture(
        pid: Int32 = 1,
        name: String,
        app: String? = nil,
        parent: Int32? = nil,
        memory: UInt64? = 0,
        cpu: Double = 0,
        threads: Int = 1,
        user: String = "me",
        isOwn: Bool = true,
        blocked: Int = 0,
        gpu: Double? = nil
    ) -> ProcessSample {
        ProcessSample(
            pid: PID(pid), parent: parent.map(PID.init), name: name, app: app ?? name, executable: nil, user: user,
            isOwn: isOwn, isTranslated: false, preventsSleep: false, blockedThreads: blocked, runTime: nil,
            metrics: memory.map {
                ProcessMetrics(
                    memory: Bytes($0), cpu: Percent(cpu), cpuTime: .zero, resident: Bytes($0), threads: threads,
                    diskRead: .zero, diskWrite: .zero, diskReadTotal: .zero, diskWriteTotal: .zero, power: nil, activity: nil
                )
            },
            network: nil,
            gpu: gpu.map { GPUUsage(share: Percent($0), total: .zero) }
        )
    }
}
