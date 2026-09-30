// Acting on processes: asking them to quit, or killing them.

import Darwin

enum ProcessSignal: Sendable {
    /// `SIGTERM`: ask the process to shut down cleanly.
    case terminate
    /// `SIGKILL`: stop it immediately; unsaved work is lost.
    case kill

    fileprivate var raw: Int32 {
        switch self {
        case .terminate: SIGTERM
        case .kill: SIGKILL
        }
    }
}

enum SignalError: Error, Equatable, CustomStringConvertible {
    /// PID 0/1 and Procmon itself are never signalled.
    case protected
    case notPermitted
    case noSuchProcess
    case other(errno: Int32)

    var description: String {
        switch self {
        case .protected: "this process is protected"
        case .notPermitted: "permission denied, it belongs to another user or to the system"
        case .noSuchProcess: "the process has already exited"
        case .other(let code): String(cString: strerror(code))
        }
    }
}

enum ProcessControl {
    static func send(_ signal: ProcessSignal, to pid: PID) throws(SignalError) {
        guard pid.raw > 1, pid.raw != getpid() else { throw .protected }
        guard Darwin.kill(pid.raw, signal.raw) == 0 else {
            switch errno {
            case EPERM: throw .notPermitted
            case ESRCH: throw .noSuchProcess
            case let code: throw .other(errno: code)
            }
        }
    }
}
