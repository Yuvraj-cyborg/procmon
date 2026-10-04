// Immutable, UI-agnostic readings produced by the sampler.

import Foundation

/// Everything measured in one sampling pass.
struct Snapshot: Sendable {
    let memory: MemoryStats
    let cpu: CPUStats
    /// `nil` when no GPU reports utilisation.
    let gpu: GPUStats?
    /// Whole-machine network traffic; `nil` on the first pass.
    let network: InterfaceRates?
    /// Whole-machine disk traffic; `nil` on the first pass.
    let disk: DiskActivity?
    let energy: EnergyStats
    let processes: [ProcessSample]
    /// ``processes`` rolled up by app, computed off the main thread.
    let apps: [AppUsage]
    let threadAlerts: [ThreadAlert]
    let coverage: ProbeCoverage

    var threadCount: Int { processes.reduce(0) { $0 + ($1.metrics?.threads ?? 0) } }
}

// MARK: - Memory

struct MemoryStats: Sendable, Equatable {
    let total: Bytes
    let used: Bytes
    let available: Bytes
    let swapTotal: Bytes
    let swapUsed: Bytes
    let breakdown: MemoryBreakdown
    let pressure: MemoryPressure
}

/// Where physical memory is going, as reported by the VM subsystem.
struct MemoryBreakdown: Sendable, Equatable {
    /// Anonymous memory owned by apps, minus purgeable pages.
    let app: Bytes
    /// Kernel-locked memory that can never be paged out.
    let wired: Bytes
    /// Pages held by the memory compressor.
    let compressed: Bytes
    /// File-backed and purgeable pages the OS can reclaim instantly.
    let cached: Bytes
    let free: Bytes

    /// Activity Monitor defines "used" as app + wired + compressed.
    var used: Bytes { app + wired + compressed }
}

enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical, unknown

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }
}

// MARK: - CPU, GPU, network

struct CPUStats: Sendable, Equatable {
    /// Whole-machine utilisation.
    let total: Ratio
    /// The part of ``total`` spent in apps and in the kernel.
    let user: Ratio
    let system: Ratio
    let cores: [Ratio]
    let load: LoadAverage

    var idle: Ratio { Ratio(1 - total.value) }
}

struct LoadAverage: Sendable, Equatable {
    let one: Double
    let five: Double
    let fifteen: Double
}

struct GPUStats: Sendable, Equatable {
    let name: String
    let utilization: Ratio
}

/// Whole-machine network traffic across every non-loopback interface.
struct InterfaceRates: Sendable, Equatable {
    let received: Throughput
    let sent: Throughput
}

/// Network activity of one process: rates since the last reading, and
/// totals while its sockets were open.
struct NetworkRates: Sendable, Equatable {
    let received: Throughput
    let sent: Throughput
    let packets: Rate
    let receivedTotal: Bytes
    let sentTotal: Bytes
}

/// Whole-machine disk traffic, across physical drives.
struct DiskActivity: Sendable, Equatable {
    let read: Throughput
    let written: Throughput
}

struct EnergyStats: Sendable, Equatable {
    /// `nil` on Macs without a battery.
    let battery: BatteryStatus?
    /// Summed over the processes Procmon may inspect, in watts.
    let processPower: Double
    /// Processes holding a power assertion that keeps the Mac awake.
    let sleepPreventers: [PID: [String]]
}

struct BatteryStatus: Sendable, Equatable {
    let level: Ratio
    let isCharging: Bool
    let onPower: Bool
    /// `nil` while macOS is still estimating.
    let timeRemaining: Duration?
    let cycleCount: Int?
    /// Full charge today relative to when new.
    let health: Ratio?
    /// macOS's verdict, e.g. "Good" or "Check Battery".
    let condition: String?
    /// Watts flowing out of (negative) or into the battery.
    let power: Double?
    let temperature: Double?
}

// MARK: - Processes

struct ProcessSample: Identifiable, Sendable {
    let pid: PID
    let parent: PID?
    let name: String
    /// Application the process belongs to (its outermost `.app` bundle), or
    /// the process name for plain executables.
    let app: String
    let executable: String?
    let user: String
    /// Whether the process belongs to the person running Procmon.
    let isOwn: Bool
    /// Running an Intel binary through Rosetta.
    let isTranslated: Bool
    /// Holds a power assertion that keeps the Mac awake.
    let preventsSleep: Bool
    /// Threads stuck in the kernel or suspended at the last thread probe.
    let blockedThreads: Int
    let runTime: Duration?
    /// `nil` when the process belongs to another user (usually root) and
    /// macOS will not let an unprivileged app inspect it.
    let metrics: ProcessMetrics?
    /// `nil` when the process had no sockets in the last interval.
    let network: NetworkRates?

    var id: PID { pid }
    var isRestricted: Bool { metrics == nil }
    var memory: Bytes? { metrics?.memory }
    var cpu: Percent? { metrics?.cpu }
    var activity: ActivityRates? { metrics?.activity }

    /// Packets per second above which a process is flagged as flooding the network.
    static let packetFlood = 5_000.0

    var kind: String { isTranslated ? "Intel" : "Apple" }

    var noiseReasons: [NoiseReason] {
        var reasons = activity?.noiseReasons ?? []
        if let network, network.packets.perSecond >= Self.packetFlood {
            reasons.append(.packets)
        }
        return reasons
    }

    /// Ranks processes by how hard they are hammering the kernel and network.
    var intensity: Double {
        (activity?.intensity ?? 0) + (network.map { $0.packets.perSecond / Self.packetFlood } ?? 0)
    }
}

/// Readings that need permission to inspect the task.
struct ProcessMetrics: Sendable {
    /// Physical footprint: what Activity Monitor calls "Memory".
    let memory: Bytes
    /// Relative to a single core: 200% means two cores fully busy.
    let cpu: Percent
    /// CPU time used since the process started.
    let cpuTime: Duration
    /// Resident set size, "Real Memory" in Activity Monitor.
    let resident: Bytes
    let threads: Int
    let diskRead: Throughput
    let diskWrite: Throughput
    let diskReadTotal: Bytes
    let diskWriteTotal: Bytes
    /// Power drawn since the last reading, in watts; `nil` on the first one.
    let power: Double?
    /// Kernel counter rates; `nil` until the process has been seen twice.
    let activity: ActivityRates?
}

/// Resource usage of all processes belonging to one application.
struct AppUsage: Identifiable, Sendable {
    let name: String
    let processes: [PID]
    let memory: Bytes
    let cpu: Percent
    let threads: Int

    var id: String { name }
}

extension Sequence where Element == ProcessSample {
    /// Rolls processes up by ``ProcessSample/app``, largest memory first.
    func groupedByApp() -> [AppUsage] {
        var groups: [String: (pids: [PID], memory: Bytes, cpu: Percent, threads: Int)] = [:]
        for process in self {
            var group = groups[process.app] ?? ([], .zero, .zero, 0)
            group.pids.append(process.pid)
            group.memory += process.memory ?? .zero
            group.cpu = group.cpu + (process.cpu ?? .zero)
            group.threads += process.metrics?.threads ?? 0
            groups[process.app] = group
        }
        return groups
            .map { AppUsage(name: $0.key, processes: $0.value.pids, memory: $0.value.memory, cpu: $0.value.cpu, threads: $0.value.threads) }
            .sorted { ($0.memory, $1.name) > ($1.memory, $0.name) }
    }
}

// MARK: - Kernel activity

/// How chatty a process is with the kernel, per second.
struct ActivityRates: Sendable, Equatable {
    var syscalls: Rate = .zero
    var contextSwitches: Rate = .zero
    var machMessages: Rate = .zero
    var idleWakeups: Rate = .zero
    var pageFaults: Rate = .zero

    // Thresholds above which a single process is considered to be hammering
    // the kernel. Tuned so that a busy-but-healthy browser stays under them.
    static let syscallLimit = 50_000.0
    static let contextSwitchLimit = 20_000.0
    static let machMessageLimit = 20_000.0
    static let wakeupLimit = 1_000.0
    static let pageFaultLimit = 100_000.0

    var noiseReasons: [NoiseReason] {
        [
            (syscalls, Self.syscallLimit, NoiseReason.syscalls),
            (contextSwitches, Self.contextSwitchLimit, .contextSwitches),
            (machMessages, Self.machMessageLimit, .machMessages),
            (idleWakeups, Self.wakeupLimit, .wakeups),
            (pageFaults, Self.pageFaultLimit, .pageFaults),
        ]
        .filter { rate, limit, _ in rate.perSecond >= limit }
        .map(\.2)
    }

    /// A single number to rank processes by kernel chatter.
    var intensity: Double {
        syscalls.perSecond / Self.syscallLimit
            + contextSwitches.perSecond / Self.contextSwitchLimit
            + machMessages.perSecond / Self.machMessageLimit
            + idleWakeups.perSecond / Self.wakeupLimit
            + pageFaults.perSecond / Self.pageFaultLimit
    }
}

/// Why a process was flagged as noisy.
enum NoiseReason: Sendable, Equatable {
    case syscalls, contextSwitches, machMessages, wakeups, pageFaults, packets

    var label: String {
        switch self {
        case .syscalls: "Syscall storm"
        case .contextSwitches: "Context-switch thrash"
        case .machMessages: "IPC flood"
        case .wakeups: "Frequent wakeups"
        case .pageFaults: "Page-fault storm"
        case .packets: "Packet flood"
        }
    }
}

// MARK: - Threads

enum ThreadRunState: Int, Sendable, Comparable {
    // Declared in the order a thread list is sorted: problems first.
    case uninterruptible, stopped, running, waiting, halted, unknown

    init(raw: Int32) {
        // `TH_STATE_*` from <mach/thread_info.h>.
        switch raw {
        case 1: self = .running
        case 2: self = .stopped
        case 3: self = .waiting
        case 4: self = .uninterruptible
        case 5: self = .halted
        default: self = .unknown
        }
    }

    static func < (lhs: ThreadRunState, rhs: ThreadRunState) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .uninterruptible: "Blocked"
        case .stopped: "Stopped"
        case .halted: "Halted"
        case .unknown: "Unknown"
        }
    }
}

struct ThreadSample: Identifiable, Sendable {
    let id: ThreadID
    let name: String?
    let state: ThreadRunState
    /// Share of one core this thread used recently.
    let cpu: Ratio

    var displayName: String { name ?? "Thread \(id)" }
}

/// A thread that has been in a suspicious state across several samples.
struct ThreadAlert: Identifiable, Sendable {
    let pid: PID
    let process: String
    let thread: ThreadID
    let threadName: String?
    let kind: ThreadAlertKind
    let duration: Duration

    var id: String { "\(pid.raw)-\(thread.raw)" }
}

enum ThreadAlertKind: Sendable, Equatable {
    /// Stuck in an uninterruptible kernel wait (typically I/O or a lock).
    case blocked
    /// Suspended, e.g. by a debugger or SIGSTOP.
    case stopped
    /// Pegging a core without pause.
    case spinning(cpu: Ratio)

    var label: String {
        switch self {
        case .blocked: "Blocked"
        case .stopped: "Stopped"
        case .spinning: "Spinning"
        }
    }
}

/// How much of the system the task probes could actually see.
struct ProbeCoverage: Sendable, Equatable {
    var inspected = 0
    var denied = 0
}
