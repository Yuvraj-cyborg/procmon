// What the user typed into a process filter box.

import Foundation

/// A case-insensitive substring of the process or app name, or an exact PID.
struct ProcessQuery: Equatable, Sendable {
    private let needle: String
    private let pid: PID?

    init(_ input: String) {
        needle = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        pid = Int32(needle).map(PID.init)
    }

    var isEmpty: Bool { needle.isEmpty }

    private func matchesName(_ name: String) -> Bool {
        name.lowercased().contains(needle)
    }

    func matches(_ process: ProcessSample) -> Bool {
        isEmpty || pid == process.pid || matchesName(process.name) || matchesName(process.app)
    }

    func matches(_ app: AppUsage) -> Bool {
        isEmpty || matchesName(app.name)
    }
}

/// Fixed-capacity ring of recent values, oldest first.
struct History<Value: Sendable>: Sendable {
    let capacity: Int
    private(set) var values: [Value] = []

    init(capacity: Int) {
        self.capacity = capacity
        values.reserveCapacity(capacity)
    }

    mutating func push(_ value: Value) {
        if values.count == capacity {
            values.removeFirst()
        }
        values.append(value)
    }
}
