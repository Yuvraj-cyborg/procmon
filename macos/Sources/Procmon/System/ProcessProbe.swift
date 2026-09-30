// Per-process readings from libproc and the BSD process table.

import Darwin
import Foundation

/// Cumulative kernel counters for one task. Differencing two readings gives rates.
struct TaskCounters: Sendable, Equatable {
    var syscalls: UInt64
    var contextSwitches: UInt64
    var machMessages: UInt64
    var pageFaults: UInt64
    var idleWakeups: UInt64
    var diskRead: UInt64
    var diskWritten: UInt64
    /// User plus system CPU time.
    var cpuTime: Duration
    var threads: Int
    /// Physical footprint, what Activity Monitor shows as "Memory".
    var footprint: Bytes
}

/// What the BSD layer and libproc report about a task we may inspect.
struct TaskReading: Sendable {
    let name: String
    let started: Date
    let counters: TaskCounters
}

enum ProcessProbe {
    /// `TH_USAGE_SCALE` from <mach/thread_info.h>: `pth_cpu_usage` of 1000 is one full core.
    private static let threadUsageScale = 1000.0

    /// Extra room in thread-list buffers for threads spawned between asking how
    /// many threads a task has and listing them.
    static let threadSlack = 16

    static func allPIDs() -> [PID] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }.map(PID.init)
    }

    /// Counters and identity for `pid`, or `nil` without permission (other
    /// users' processes, unless running as root).
    static func task(_ pid: PID) -> TaskReading? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(pid.raw, PROC_PIDTASKALLINFO, 0, &info, size) == size else { return nil }
        let usage = resourceUsage(pid)
        let task = info.ptinfo
        let bsd = info.pbsd
        // The kernel's 32-bit counters wrap; widening keeps rates correct until
        // the next wrap, where `Rate.between` reports zero instead of garbage.
        func counter(_ value: Int32) -> UInt64 { UInt64(UInt32(bitPattern: value)) }
        let name = string(fromCTuple: bsd.pbi_name)
        return TaskReading(
            name: name.isEmpty ? string(fromCTuple: bsd.pbi_comm) : name,
            started: Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6),
            counters: TaskCounters(
                syscalls: counter(task.pti_syscalls_unix) + counter(task.pti_syscalls_mach),
                contextSwitches: counter(task.pti_csw),
                machMessages: counter(task.pti_messages_sent) + counter(task.pti_messages_received),
                pageFaults: counter(task.pti_faults),
                idleWakeups: usage?.ri_pkg_idle_wkups ?? 0,
                diskRead: usage?.ri_diskio_bytesread ?? 0,
                diskWritten: usage?.ri_diskio_byteswritten ?? 0,
                cpuTime: MachTime.duration(ticks: task.pti_total_user &+ task.pti_total_system),
                threads: Int(max(task.pti_threadnum, 0)),
                footprint: Bytes(usage?.ri_phys_footprint ?? task.pti_resident_size)
            )
        )
    }

    private static func resourceUsage(_ pid: PID) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid.raw, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info : nil
    }

    static func executablePath(_ pid: PID) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid.raw, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Name and start time from the BSD process table, which, unlike libproc,
    /// is readable for every process.
    static func kernelEntry(_ pid: PID) -> (name: String, started: Date)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid.raw]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return (
            string(fromCTuple: info.kp_proc.p_comm),
            Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
        )
    }

    /// Every thread's run state and recent CPU share, or `nil` without permission.
    static func threads(_ pid: PID, hint: Int) -> [ThreadSample]? {
        var handles = [UInt64](repeating: 0, count: max(hint, 1))
        let bytes = proc_pidinfo(pid.raw, PROC_PIDLISTTHREADS, 0, &handles, Int32(handles.count * MemoryLayout<UInt64>.size))
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<UInt64>.size
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        return handles.prefix(count).compactMap { handle in
            var info = proc_threadinfo()
            guard proc_pidinfo(pid.raw, PROC_PIDTHREADINFO, handle, &info, size) == size else { return nil }
            let name = string(fromCTuple: info.pth_name)
            return ThreadSample(
                id: ThreadID(raw: handle),
                name: name.isEmpty ? nil : name,
                state: ThreadRunState(raw: info.pth_run_state),
                cpu: Ratio(Double(info.pth_cpu_usage) / threadUsageScale)
            )
        }
    }

    /// Current threads of one process, sized from its thread count.
    static func inspectThreads(_ pid: PID) -> [ThreadSample]? {
        let hint = task(pid)?.counters.threads ?? 64
        return threads(pid, hint: hint + threadSlack)
    }

    /// The outermost `.app` bundle an executable lives in, so helpers like
    /// `Foo.app/Contents/Frameworks/Foo Helper (Renderer).app/…` roll up to "Foo".
    /// Falls back to the process name for non-bundled executables.
    static func appName(executable: String?, processName: String) -> String {
        guard let executable else { return processName }
        for component in executable.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return processName
    }
}
