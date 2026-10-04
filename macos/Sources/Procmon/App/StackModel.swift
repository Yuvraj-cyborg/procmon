// Captures what every thread of the inspected process is doing, on request.

import Foundation
import Observation

@MainActor
@Observable
final class StackModel {
    enum State {
        case loading
        case loaded([ThreadID: ThreadStack], at: Date)
        case failed(String)
    }

    /// Latest capture per process.
    private(set) var captures: [PID: State] = [:]

    func state(for pid: PID) -> State? { captures[pid] }

    /// Samples `pid` for a second. `sample` is Apple's tool and may inspect
    /// any process owned by the same user; root processes need sudo.
    func capture(_ pid: PID) {
        if case .loading = captures[pid] { return }
        captures[pid] = .loading
        Task {
            let result = await offMain(qos: .userInitiated) {
                Result { () throws(Subprocess.Failure) in try ThreadStacks.capture(pid, seconds: 1) }
            }
            switch result {
            case .success(let stacks): captures[pid] = .loaded(stacks, at: Date())
            case .failure(let error): captures[pid] = .failed(error.description)
            }
        }
    }
}
