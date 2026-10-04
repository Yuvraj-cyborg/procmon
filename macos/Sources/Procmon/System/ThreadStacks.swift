// What each thread of a process is doing, from its call stacks.
//
// `/usr/bin/sample` interrupts the process a thousand times a second and
// records every thread's stack; it is Apple's own tool and may inspect any
// process of the same user. From its report we keep each thread's dominant
// stack and judge, by rules on where that stack ends, what the thread waits on.

import Foundation

/// One frame of a call stack.
struct StackFrame: Sendable, Equatable {
    let symbol: String
    /// Binary the code lives in, e.g. "libsystem_kernel.dylib".
    let library: String?
}

/// What a thread spends its time doing.
enum ThreadActivity: Sendable, Equatable {
    /// A run loop with nothing to do: the healthy state for most threads.
    case idle
    /// A pool thread parked until work arrives.
    case idleWorker
    /// Blocked on a message from another process or the kernel, outside a
    /// run loop: typically waiting for an XPC reply.
    case waitingForReply
    case waitingForLock
    case waitingOnCondition
    case waitingOnSemaphore
    case waitingForEvents
    case fileIO
    case network
    case sleeping
    case waitingForChild
    /// On a core, running this function.
    case running(String)
    case unknown

    var summary: String {
        switch self {
        case .idle: "Idle, waiting for events"
        case .idleWorker: "Idle worker"
        case .waitingForReply: "Waiting for a reply from another process"
        case .waitingForLock: "Waiting for a lock"
        case .waitingOnCondition: "Waiting on a condition"
        case .waitingOnSemaphore: "Waiting on a semaphore"
        case .waitingForEvents: "Waiting for events"
        case .fileIO: "Reading or writing files"
        case .network: "Waiting on the network"
        case .sleeping: "Sleeping"
        case .waitingForChild: "Waiting for a child process"
        case .running(let function): "Running \(function)"
        case .unknown: "Unknown"
        }
    }

    /// Waiting on something that may never come: the states worth a look
    /// when a thread has sat in them for long.
    var mayBeStuck: Bool {
        switch self {
        case .waitingForReply, .waitingForLock, .waitingOnCondition, .waitingOnSemaphore, .fileIO, .network, .waitingForChild:
            true
        default:
            false
        }
    }
}

/// One thread's dominant stack over the sample.
struct ThreadStack: Sendable {
    let thread: ThreadID
    let name: String?
    /// Outermost call first.
    let frames: [StackFrame]
    /// Samples on this path, out of the thread's total.
    let samples: Int
    let total: Int

    var activity: ThreadActivity { ThreadStacks.classify(frames) }
}

enum ThreadStacks {
    /// Samples `pid` for `seconds` and returns each thread's dominant stack.
    static func capture(_ pid: PID, seconds: Int = 1) throws(Subprocess.Failure) -> [ThreadID: ThreadStack] {
        parse(try ProcessControl.sample(pid, seconds: seconds))
    }

    // MARK: Parsing

    /// Reads the "Call graph" section of a `sample` report.
    static func parse(_ report: String) -> [ThreadID: ThreadStack] {
        var stacks: [ThreadID: ThreadStack] = [:]
        var inGraph = false
        var current: (id: ThreadID, name: String?, total: Int)?
        var path: [StackFrame] = []
        var pathSamples = 0
        var lastDepth = -1
        var pathClosed = false

        func finish() {
            if let current {
                stacks[current.id] = ThreadStack(
                    thread: current.id, name: current.name, frames: path, samples: pathSamples, total: current.total
                )
            }
            current = nil
            path = []
            pathSamples = 0
            lastDepth = -1
            pathClosed = false
        }

        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Call graph:") {
                inGraph = true
                continue
            }
            guard inGraph else { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("Total number in stack") {
                finish()
                if !line.hasPrefix("    ") { inGraph = false }
                continue
            }
            if let header = threadHeader(line) {
                finish()
                current = header
                continue
            }
            guard current != nil, !pathClosed, let (depth, count, frame) = frameLine(line) else { continue }
            // Children are listed heaviest first, so the dominant stack is the
            // run of lines whose depth keeps growing.
            if depth > lastDepth {
                path.append(frame)
                pathSamples = count
                lastDepth = depth
            } else {
                pathClosed = true
            }
        }
        finish()
        return stacks
    }

    /// `    865 Thread_10238: com.apple.NSEventThread` or
    /// `    865 Thread_10150   DispatchQueue_1: com.apple.main-thread  (serial)`.
    private static func threadHeader(_ line: Substring) -> (id: ThreadID, name: String?, total: Int)? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count == 4, let space = trimmed.firstIndex(of: " "),
              let total = Int(trimmed[..<space])
        else { return nil }
        let rest = trimmed[trimmed.index(after: space)...]
        guard rest.hasPrefix("Thread_") else { return nil }
        let digits = rest.dropFirst("Thread_".count).prefix { $0.isNumber }
        guard let raw = UInt64(digits) else { return nil }
        var name = rest.dropFirst("Thread_".count + digits.count).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix(":") { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let queue = name.range(of: #"DispatchQueue_\d+: "#, options: .regularExpression) {
            name = String(name[queue.upperBound...])
        }
        if let serial = name.range(of: "  (") { name = String(name[..<serial.lowerBound]) }
        return (ThreadID(raw: raw), name.isEmpty ? nil : name, total)
    }

    /// `    +   865 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x18b5b7c34]`,
    /// returning the column where the count starts as the depth.
    private static func frameLine(_ line: Substring) -> (depth: Int, count: Int, frame: StackFrame)? {
        guard line.hasPrefix("    +") else { return nil }
        guard let start = line.firstIndex(where: { $0.isNumber }) else { return nil }
        let depth = line.distance(from: line.startIndex, to: start)
        let digits = line[start...].prefix { $0.isNumber }
        guard let count = Int(digits) else { return nil }
        let text = line[line.index(start, offsetBy: digits.count)...].trimmingCharacters(in: .whitespaces)
        var symbol = text
        var library: String?
        if let open = text.range(of: "  (in ") {
            symbol = String(text[..<open.lowerBound])
            let after = text[open.upperBound...]
            if let close = after.firstIndex(of: ")") {
                library = String(after[..<close])
            }
        }
        return (depth, count, StackFrame(symbol: symbol, library: library))
    }

    // MARK: Classification

    /// Judges a stack by the system call or runtime function it ends in.
    static func classify(_ frames: [StackFrame]) -> ThreadActivity {
        guard let leaf = frames.last?.symbol else { return .unknown }
        let symbols = Set(frames.map(\.symbol))
        func inPath(_ names: String...) -> Bool { names.contains { symbols.contains($0) } }

        switch leaf {
        case "mach_msg2_trap", "mach_msg_trap", "mach_msg", "mach_msg_overwrite":
            return inPath("__CFRunLoopServiceMachPort", "_dispatch_mach_msg_invoke") ? .idle : .waitingForReply
        case "__psynch_mutexwait", "__ulock_wait", "__ulock_wait2":
            return .waitingForLock
        case "__psynch_cvwait":
            return .waitingOnCondition
        case "semaphore_wait_trap", "semaphore_timedwait_trap":
            return .waitingOnSemaphore
        case "__semwait_signal", "__semwait_signal_nocancel":
            return inPath("nanosleep", "usleep", "sleep") ? .sleeping : .waitingOnSemaphore
        case "__workq_kernreturn":
            return .idleWorker
        case "kevent", "kevent64", "kevent_id", "kevent_qos":
            return .waitingForEvents
        case "read", "pread", "readv", "write", "pwrite", "writev", "__read_nocancel", "__write_nocancel", "__pread_nocancel",
             "fsync", "__open", "__open_nocancel", "open", "stat", "lstat", "fstat", "fstatat", "getattrlist", "getattrlistbulk",
             "__getdirentries64", "fcntl", "__fcntl":
            return .fileIO
        case "select", "__select", "poll", "__poll", "recvfrom", "__recvfrom", "recvmsg", "__recvmsg", "accept", "__accept",
             "connect", "__connect", "sendto", "__sendto":
            return .network
        case "__wait4", "wait4", "waitpid", "__wait4_nocancel":
            return .waitingForChild
        case "__sigsuspend", "__pause":
            return .sleeping
        default:
            // Not parked in the kernel: name the innermost frame that has one.
            let named = frames.last { $0.symbol != "???" && !$0.symbol.hasPrefix("<") }
            return .running(named?.symbol ?? leaf)
        }
    }
}
