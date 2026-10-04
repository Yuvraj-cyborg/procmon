// Collects snapshots. Holds the previous readings needed to turn cumulative
// kernel counters into per-second rates.
//
// Almost all of the sampler's cost is time inside the kernel answering
// `proc_pidinfo`, so the policy below is about asking less often, not about
// making each call cheaper.

import Dispatch
import Foundation

/// What the UI needs from the next pass.
struct SampleOptions: Sendable {
    /// Per-process network traffic costs a `nettop` run; only fetch it
    /// while something on screen shows it.
    var processNetwork = false
    /// Whether the window can be seen. Hidden, the sampler does the minimum.
    var visible = true
}

actor Sampler {
    /// Every thread of every process is walked this often: thousands of calls.
    private static let fullThreadProbe = Duration.seconds(6)
    private static let hiddenThreadProbe = Duration.seconds(30)
    /// Between full walks, processes this busy are re-probed each pass,
    /// since only they can hold a spinning thread.
    private static let hotProcess = 50.0
    /// Network totals come from spawning `nettop`.
    private static let networkProbe = Duration.seconds(4)
    /// Battery and power assertions change slowly.
    private static let powerProbe = Duration.seconds(10)

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
        let uid: uid_t
        let parent: PID?
    }

    private let clock = ContinuousClock()
    private let myUID = getuid()
    private var lastSample: ContinuousClock.Instant
    private var identities: [PID: Identity] = [:]
    private var counters: [PID: TaskCounters] = [:]
    private var users: [uid_t: String] = [:]
    private var coreTicks: [CoreTicks] = []
    private var threads = ThreadTracker()
    private var alerts: [PID: [ThreadAlert]] = [:]
    /// Blocked or stopped threads per process, as of its last thread probe.
    private var blocked: [PID: Int] = [:]
    private var lastFullThreadProbe: ContinuousClock.Instant?
    /// Reused between calls: one allocation instead of one per process.
    private var threadIDs = [UInt64](repeating: 0, count: 256)
    private var network = NetworkProbe()
    private var networkRates: [PID: NetworkRates] = [:]
    private var lastNetworkProbe: ContinuousClock.Instant?
    private var interfaces = InterfaceProbe()
    private var disks = DiskActivityProbe()
    private var battery: BatteryStatus?
    private var sleepPreventers: [PID: [String]] = [:]
    private var lastPowerProbe: ContinuousClock.Instant?

    init() {
        lastSample = clock.now
        coreTicks = Host.coreTicks() ?? []
    }

    func sample(_ options: SampleOptions = SampleOptions()) -> Snapshot {
        let now = clock.now
        let elapsed = now - lastSample
        lastSample = now
        let wallNow = Date()

        let fullProbeInterval = options.visible ? Self.fullThreadProbe : Self.hiddenThreadProbe
        let fullThreadPass = lastFullThreadProbe.map { now - $0 >= fullProbeInterval } ?? true
        if fullThreadPass {
            lastFullThreadProbe = now
        }
        if options.processNetwork, lastNetworkProbe.map({ now - $0 >= Self.networkProbe }) ?? true {
            networkRates = network.sample(at: now)
            lastNetworkProbe = now
        } else if !options.processNetwork {
            networkRates = [:]
            lastNetworkProbe = nil
        }
        if lastPowerProbe.map({ now - $0 >= Self.powerProbe }) ?? true {
            battery = PowerProbe.battery()
            sleepPreventers = PowerProbe.sleepPreventers()
            lastPowerProbe = now
        }

        var coverage = ProbeCoverage()
        var probed = Set<PID>()
        var alive = Set<PID>()
        var nextCounters: [PID: TaskCounters] = [:]
        var nextIdentities: [PID: Identity] = [:]
        var processPower = 0.0
        let pids = ProcessProbe.allPIDs()
        nextCounters.reserveCapacity(pids.count)
        nextIdentities.reserveCapacity(pids.count)
        alive.reserveCapacity(pids.count)

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
            alive.insert(pid)

            var metrics: ProcessMetrics?
            if let reading {
                coverage.inspected += 1
                let current = reading.counters
                nextCounters[pid] = current
                let before = counters[pid]
                let cpu = before.map { Self.cpu(from: $0.cpuTime, to: current.cpuTime, over: elapsed) } ?? .zero
                let power = before.flatMap { Self.power(from: $0.energy, to: current.energy, over: elapsed) }
                processPower += power ?? 0
                metrics = ProcessMetrics(
                    memory: current.footprint,
                    cpu: cpu,
                    cpuTime: current.cpuTime,
                    resident: current.resident,
                    threads: current.threads,
                    diskRead: before.map { .between($0.diskRead, current.diskRead, over: elapsed) } ?? .zero,
                    diskWrite: before.map { .between($0.diskWritten, current.diskWritten, over: elapsed) } ?? .zero,
                    diskReadTotal: Bytes(current.diskRead),
                    diskWriteTotal: Bytes(current.diskWritten),
                    power: power,
                    activity: before.map { Self.activity(from: $0, to: current, over: elapsed) }
                )
                let hot = options.visible && cpu.value >= Self.hotProcess
                if fullThreadPass || hot, let samples = probeThreads(pid, hint: current.threads) {
                    probed.insert(pid)
                    alerts[pid] = threads.observe(pid: pid, process: identity.name, samples: samples, at: now)
                    blocked[pid] = samples.count { $0.state == .uninterruptible || $0.state == .stopped }
                }
            } else {
                coverage.denied += 1
            }
            processes.append(ProcessSample(
                pid: pid,
                parent: reading?.parent ?? identity.parent,
                name: identity.name,
                app: identity.app,
                executable: identity.executable,
                user: userName(identity.uid),
                isOwn: identity.uid == myUID,
                isTranslated: reading?.isTranslated ?? false,
                preventsSleep: sleepPreventers[pid] != nil,
                blockedThreads: blocked[pid] ?? 0,
                runTime: identity.started.map { .seconds(max(0, wallNow.timeIntervalSince($0))) },
                metrics: metrics,
                network: networkRates[pid]
            ))
        }
        counters = nextCounters
        identities = nextIdentities
        threads.finishPass(at: now, probed: probed, alive: alive)
        alerts = alerts.filter { alive.contains($0.key) }
        blocked = blocked.filter { alive.contains($0.key) }

        return Snapshot(
            memory: memoryStats(),
            cpu: cpuStats(),
            gpu: GPUProbe.sample(),
            network: interfaces.sample(at: now),
            disk: disks.sample(at: now),
            energy: EnergyStats(battery: battery, processPower: processPower, sleepPreventers: sleepPreventers),
            processes: processes,
            apps: processes.groupedByApp(),
            threadAlerts: alerts.values.joined().sorted { $0.duration > $1.duration },
            coverage: coverage
        )
    }

    /// Thread states for one process, into the shared id buffer.
    private func probeThreads(_ pid: PID, hint: Int) -> [ThreadSample]? {
        let needed = hint + ProcessProbe.threadSlack
        if threadIDs.count < needed {
            threadIDs = [UInt64](repeating: 0, count: needed * 2)
        }
        return ProcessProbe.threads(pid, ids: &threadIDs)
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
            started: reading?.started ?? entry?.started,
            uid: reading?.uid ?? entry?.uid ?? 0,
            parent: reading?.parent ?? entry?.parent
        )
    }

    private func userName(_ uid: uid_t) -> String {
        if let known = users[uid] { return known }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        let name = getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0 && result != nil
            ? String(cString: entry.pw_name)
            : String(uid)
        users[uid] = name
        return name
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
        let pairs = Array(zip(current, coreTicks))
        let cores = pairs.map { now, before in now.load(since: before) }
        var (user, system, total): (Double, Double, Double) = (0, 0, 0)
        for (now, before) in pairs {
            let split = now.split(since: before)
            user += Double(split.user)
            system += Double(split.system)
            total += Double(split.total)
        }
        coreTicks = current
        return CPUStats(
            total: cores.isEmpty ? .zero : Ratio(cores.map(\.value).reduce(0, +) / Double(cores.count)),
            user: total > 0 ? Ratio(user / total) : .zero,
            system: total > 0 ? Ratio(system / total) : .zero,
            cores: cores,
            load: Host.loadAverage()
        )
    }

    static func cpu(from before: Duration, to now: Duration, over elapsed: Duration) -> Percent {
        let wall = elapsed.seconds
        guard wall > 0, now >= before else { return .zero }
        return Percent((now - before).seconds / wall * 100)
    }

    /// Watts, from two readings of a nanojoule counter.
    static func power(from before: UInt64, to now: UInt64, over elapsed: Duration) -> Double? {
        let seconds = elapsed.seconds
        guard seconds > 0, now >= before else { return nil }
        return Double(now - before) / 1e9 / seconds
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
