// Acting on processes: asking them to quit, or killing them.

import Darwin
import Foundation

enum ProcessSignal: Sendable, CaseIterable {
    /// `SIGTERM`: ask the process to shut down cleanly.
    case terminate
    /// `SIGKILL`: stop it immediately; unsaved work is lost.
    case kill
    /// `SIGSTOP`: freeze it where it is, until resumed.
    case pause
    /// `SIGCONT`: let a paused process run again.
    case resume
    /// `SIGHUP`: many daemons reload their configuration on it.
    case hangUp
    /// `SIGINT`: what Control-C sends in Terminal.
    case interrupt

    fileprivate var raw: Int32 {
        switch self {
        case .terminate: SIGTERM
        case .kill: SIGKILL
        case .pause: SIGSTOP
        case .resume: SIGCONT
        case .hangUp: SIGHUP
        case .interrupt: SIGINT
        }
    }

    var label: String {
        switch self {
        case .terminate: "Quit (SIGTERM)"
        case .kill: "Force Quit (SIGKILL)"
        case .pause: "Pause (SIGSTOP)"
        case .resume: "Resume (SIGCONT)"
        case .hangUp: "Hang Up (SIGHUP)"
        case .interrupt: "Interrupt (SIGINT)"
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
    /// Runs `/usr/bin/sample` on `pid` for a few seconds and returns its
    /// report: every thread's call stacks, as Activity Monitor's "Sample Process".
    static func sample(_ pid: PID, seconds: Int = 3) throws(Subprocess.Failure) -> String {
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("procmon-sample-\(pid.raw)-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: report) }
        _ = try Subprocess.run("/usr/bin/sample", [String(pid.raw), String(seconds), "-mayDie", "-file", report.path])
        guard let text = try? String(contentsOf: report, encoding: .utf8) else {
            throw Subprocess.Failure(description: "sample did not write a report")
        }
        return text
    }

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
