// Collects snapshots. Holds the previous readings needed to turn cumulative
// kernel counters into per-second rates.

import Dispatch
import Foundation

actor Sampler {
    /// Walking every thread of every process costs thousands of syscalls, so
    /// thread states are probed on every other sample.
    private static let threadProbeEvery = 2
    /// Network totals come from spawning `nettop`; every third sample is
    /// plenty because rates are computed over the real elapsed time.
    private static let networkProbeEvery = 3

    // The probes block on syscalls and child processes, so the actor runs on
    // its own queue instead of tying up a thread in Swift's cooperative pool.
    private let queue = DispatchSerialQueue(label: "procmon.sampler", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Facts about a process that do not change while it runs.
    private struct Identity {
        /// The kernel's short name, compared each pass to notice an `exec`.
        let shortName: String
        let name: String
        let app: String
        let executable: String?
        let started: Date?
    }

    private let clock = ContinuousClock()
    private var lastSample: ContinuousClock.Instant
    private var passes = 0
    private var identities: [PID: Identity] = [:]
    private var counters: [PID: TaskCounters] = [:]
    private var coreTicks: [CoreTicks] = []
    private var threads = ThreadTracker()
    private var threadAlerts: [ThreadAlert] = []
    private var network = NetworkProbe()
    private var networkRates: [PID: NetworkRates] = [:]
    private var interfaces = InterfaceProbe()

    init() {
        lastSample = clock.now
        coreTicks = Host.coreTicks() ?? []
    }

    func sample() -> Snapshot {
        let now = clock.now
        let elapsed = now - lastSample
        lastSample = now
        let wallNow = Date()

        let probeThreads = passes % Self.threadProbeEvery == 0
        if passes % Self.networkProbeEvery == 0 {
            networkRates = network.sample(at: now)
        }
        passes += 1

        var coverage = ProbeCoverage()
        var alerts: [ThreadAlert] = []
        var nextCounters: [PID: TaskCounters] = [:]
        var nextIdentities: [PID: Identity] = [:]
        let pids = ProcessProbe.allPIDs()
        nextCounters.reserveCapacity(pids.count)
        nextIdentities.reserveCapacity(pids.count)

        var processes: [ProcessSample] = []
        processes.reserveCapacity(pids.count)
        for pid in pids {
            let reading = ProcessProbe.task(pid)
            var known = identities[pid]
            if let identity = known, let reading, reading.name != identity.shortName || reading.started != identity.started {
                // `exec` keeps the PID but runs a new program (launchd services
                // start as xpcproxy). A new start time means the PID was reused,
                // so the old counters say nothing about this process.
                if reading.started != identity.started {
                    counters[pid] = nil
                }
                known = nil
            }
            guard let identity = known ?? identify(pid, reading: reading) else { continue }
            nextIdentities[pid] = identity

            var metrics: ProcessMetrics?
            if let reading {
                coverage.inspected += 1
                let current = reading.counters
                nextCounters[pid] = current
                let before = counters[pid]
                metrics = ProcessMetrics(
                    memory: current.footprint,
                    cpu: before.map { Self.cpu(from: $0.cpuTime, to: current.cpuTime, over: elapsed) } ?? .zero,
                    threads: current.threads,
                    diskRead: before.map { .between($0.diskRead, current.diskRead, over: elapsed) } ?? .zero,
                    diskWrite: before.map { .between($0.diskWritten, current.diskWritten, over: elapsed) } ?? .zero,
                    activity: before.map { Self.activity(from: $0, to: current, over: elapsed) }
                )
                if probeThreads,
                   let samples = ProcessProbe.threads(pid, hint: current.threads + ProcessProbe.threadSlack) {
                    alerts += threads.observe(pid: pid, process: identity.name, samples: samples, at: now)
                }
            } else {
                coverage.denied += 1
            }
            processes.append(ProcessSample(
                pid: pid,
                name: identity.name,
                app: identity.app,
                executable: identity.executable,
                runTime: identity.started.map { .seconds(max(0, wallNow.timeIntervalSince($0))) },
                metrics: metrics,
                network: networkRates[pid]
            ))
        }
        counters = nextCounters
        identities = nextIdentities
        if probeThreads {
            threads.finishPass(at: now)
            threadAlerts = alerts.sorted { $0.duration > $1.duration }
        }

        return Snapshot(
            memory: memoryStats(),
            cpu: cpuStats(),
            gpu: GPUProbe.sample(),
            network: interfaces.sample(at: now),
            processes: processes,
            threadAlerts: threadAlerts,
            coverage: coverage
        )
    }

    private func identify(_ pid: PID, reading: TaskReading?) -> Identity? {
        let executable = ProcessProbe.executablePath(pid)
        let entry = reading == nil ? ProcessProbe.kernelEntry(pid) : nil
        guard let shortName = reading?.name ?? entry?.name else { return nil }
        // `pbi_name` is cut at 32 bytes; the executable's file name is complete.
        let name = executable.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? shortName
        return Identity(
            shortName: shortName,
            name: name,
            app: ProcessProbe.appName(executable: executable, processName: name),
            executable: executable,
            started: reading?.started ?? entry?.started
        )
    }

    private func memoryStats() -> MemoryStats {
        let total = Host.physicalMemory
        let breakdown = Host.memoryBreakdown()
            ?? MemoryBreakdown(app: .zero, wired: .zero, compressed: .zero, cached: .zero, free: .zero)
        let swap = Host.swap()
        let used = breakdown.used
        return MemoryStats(
            total: total,
            used: used,
            available: total - used,
            swapTotal: swap.total,
            swapUsed: swap.used,
            breakdown: breakdown,
            pressure: Host.memoryPressure()
        )
    }

    private func cpuStats() -> CPUStats {
        let current = Host.coreTicks() ?? []
        let cores = zip(current, coreTicks).map { now, before in now.load(since: before) }
        coreTicks = current
        let total = cores.isEmpty ? Ratio.zero : Ratio(cores.map(\.value).reduce(0, +) / Double(cores.count))
        return CPUStats(total: total, cores: cores, load: Host.loadAverage())
    }

    static func cpu(from before: Duration, to now: Duration, over elapsed: Duration) -> Percent {
        let wall = elapsed.seconds
        guard wall > 0, now >= before else { return .zero }
        return Percent((now - before).seconds / wall * 100)
    }

    static func activity(from before: TaskCounters, to now: TaskCounters, over elapsed: Duration) -> ActivityRates {
        ActivityRates(
            syscalls: .between(before.syscalls, now.syscalls, over: elapsed),
            contextSwitches: .between(before.contextSwitches, now.contextSwitches, over: elapsed),
            machMessages: .between(before.machMessages, now.machMessages, over: elapsed),
            idleWakeups: .between(before.idleWakeups, now.idleWakeups, over: elapsed),
            pageFaults: .between(before.pageFaults, now.pageFaults, over: elapsed)
        )
    }
}
