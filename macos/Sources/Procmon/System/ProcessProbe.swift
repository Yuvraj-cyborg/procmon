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
    var resident: Bytes
    /// Energy used since the task started, in nanojoules.
    var energy: UInt64
}

/// One open file descriptor.
struct OpenFile: Identifiable, Sendable {
    enum Kind: Sendable { case file, socket, pipe }

    let descriptor: Int32
    let kind: Kind
    let name: String

    var id: Int32 { descriptor }
}

/// What the BSD layer and libproc report about a task we may inspect.
struct TaskReading: Sendable {
    let name: String
    let started: Date
    let uid: uid_t
    let parent: PID?
    let isTranslated: Bool
    let counters: TaskCounters
}

/// The BSD process table's view of a process, readable for every process.
struct KernelEntry: Sendable {
    let name: String
    let started: Date
    let uid: uid_t
    let parent: PID?
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
            uid: bsd.pbi_uid,
            parent: bsd.pbi_ppid > 0 ? PID(Int32(bsd.pbi_ppid)) : nil,
            isTranslated: bsd.pbi_flags & translatedFlag != 0,
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
                footprint: Bytes(usage?.ri_phys_footprint ?? task.pti_resident_size),
                resident: Bytes(task.pti_resident_size),
                energy: usage?.ri_energy_nj ?? 0
            )
        )
    }

    /// `P_TRANSLATED` from <sys/proc.h>: the process runs under Rosetta.
    private static let translatedFlag: UInt32 = 0x0002_0000

    private static func resourceUsage(_ pid: PID) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid.raw, RUSAGE_INFO_V6, $0)
            }
        }
        return status == 0 ? info : nil
    }

    static func executablePath(_ pid: PID) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid.raw, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Identity from the BSD process table, which, unlike libproc, is
    /// readable for every process.
    static func kernelEntry(_ pid: PID) -> KernelEntry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid.raw]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let parent = info.kp_eproc.e_ppid
        return KernelEntry(
            name: string(fromCTuple: info.kp_proc.p_comm),
            started: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6),
            uid: info.kp_eproc.e_ucred.cr_uid,
            parent: parent > 0 ? PID(parent) : nil
        )
    }

    /// Command-line arguments, from `KERN_PROCARGS2`; `nil` without permission.
    static func arguments(_ pid: PID) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid.raw]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (Int32), the executable path, NUL padding, then argc
        // NUL-terminated arguments followed by the environment.
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var cursor = MemoryLayout<Int32>.size
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        while arguments.count < argc, cursor < size {
            let end = buffer[cursor..<size].firstIndex(of: 0) ?? size
            arguments.append(String(decoding: buffer[cursor..<end], as: UTF8.self))
            cursor = end + 1
        }
        return arguments
    }

    /// Files and sockets a process has open; `nil` without permission.
    static func openFiles(_ pid: PID) -> [OpenFile]? {
        let bytes = proc_pidinfo(pid.raw, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
        let filled = proc_pidinfo(pid.raw, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride))
        guard filled > 0 else { return nil }
        return descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride).compactMap { descriptor in
            switch Int32(descriptor.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid.raw, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
                let path = string(fromCTuple: info.pvip.vip_path)
                return path.isEmpty ? nil : OpenFile(descriptor: descriptor.proc_fd, kind: .file, name: path)
            case PROX_FDTYPE_SOCKET:
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid.raw, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
                return OpenFile(descriptor: descriptor.proc_fd, kind: .socket, name: describe(info.psi))
            case PROX_FDTYPE_PIPE:
                return OpenFile(descriptor: descriptor.proc_fd, kind: .pipe, name: "pipe")
            default:
                return nil
            }
        }
    }

    /// e.g. "TCP 192.168.1.4:52013 → 140.82.112.4:443".
    private static func describe(_ socket: socket_info) -> String {
        switch socket.soi_kind {
        case Int32(SOCKINFO_TCP), Int32(SOCKINFO_IN):
            let inet = socket.soi_kind == Int32(SOCKINFO_TCP) ? socket.soi_proto.pri_tcp.tcpsi_ini : socket.soi_proto.pri_in
            let isV6 = inet.insi_vflag & UInt8(INI_IPV6) != 0
            func address(_ addr: in4in6_addr, _ addr6: in6_addr) -> String {
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if isV6 {
                    var value = addr6
                    inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count))
                } else {
                    var value = addr.i46a_addr4
                    inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count))
                }
                return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            let local = "\(address(inet.insi_laddr.ina_46, inet.insi_laddr.ina_6)):\(UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)))"
            let remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_fport))
            let proto = socket.soi_kind == Int32(SOCKINFO_TCP) ? "TCP" : "UDP"
            guard remotePort != 0 else { return "\(proto) \(local) (listening)" }
            return "\(proto) \(local) → \(address(inet.insi_faddr.ina_46, inet.insi_faddr.ina_6)):\(remotePort)"
        case Int32(SOCKINFO_UN):
            let path = withUnsafeBytes(of: socket.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return path.isEmpty ? "Unix socket" : "Unix socket \(path)"
        default:
            return "Socket"
        }
    }

    /// `PROC_PIDLISTTHREADIDS` and `PROC_PIDTHREADID64INFO` from
    /// <sys/proc_info.h>, which Swift does not import. They use system-wide
    /// thread ids, the same numbers `sample` and the debugger print.
    private static let listThreadIDs: Int32 = 28
    private static let threadIDInfo: Int32 = 15

    /// Every thread's run state and recent CPU share, or `nil` without permission.
    static func threads(_ pid: PID, hint: Int) -> [ThreadSample]? {
        var ids = [UInt64](repeating: 0, count: max(hint, 1))
        return threads(pid, ids: &ids)
    }

    /// As ``threads(_:hint:)``, listing thread ids into a caller-owned buffer.
    static func threads(_ pid: PID, ids: inout [UInt64]) -> [ThreadSample]? {
        let bytes = proc_pidinfo(pid.raw, listThreadIDs, 0, &ids, Int32(ids.count * MemoryLayout<UInt64>.size))
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<UInt64>.size
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        return ids.prefix(count).compactMap { id in
            var info = proc_threadinfo()
            guard proc_pidinfo(pid.raw, threadIDInfo, id, &info, size) == size else { return nil }
            let name = string(fromCTuple: info.pth_name)
            return ThreadSample(
                id: ThreadID(raw: id),
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
