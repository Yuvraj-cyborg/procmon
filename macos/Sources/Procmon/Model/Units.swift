// Strongly-typed quantities used throughout the app.
//
// Raw integers and doubles from the OS are converted into these at the edge
// (in the probes) so the UI can never confuse bytes with pages, or a
// percentage with a 0...1 ratio.

import Foundation

/// A number of bytes.
struct Bytes: Hashable, Comparable, Sendable {
    var value: UInt64

    static let zero = Bytes(0)

    init(_ value: UInt64) {
        self.value = value
    }

    static func < (lhs: Bytes, rhs: Bytes) -> Bool { lhs.value < rhs.value }

    /// Saturating addition: sizes never wrap around.
    static func + (lhs: Bytes, rhs: Bytes) -> Bytes {
        let (sum, overflow) = lhs.value.addingReportingOverflow(rhs.value)
        return Bytes(overflow ? .max : sum)
    }

    static func += (lhs: inout Bytes, rhs: Bytes) { lhs = lhs + rhs }

    /// Saturating subtraction: never goes below zero.
    static func - (lhs: Bytes, rhs: Bytes) -> Bytes {
        Bytes(lhs.value > rhs.value ? lhs.value - rhs.value : 0)
    }

    /// Fraction of `total` this value represents, clamped to `0...1`.
    func ratio(of total: Bytes) -> Ratio {
        total.value == 0 ? .zero : Ratio(Double(value) / Double(total.value))
    }

    /// Formats with 1024-based steps (how RAM is conventionally reported).
    var binary: String { Self.format(value, step: 1024) }

    /// Formats with 1000-based steps (how disk vendors and Finder report storage).
    var decimal: String { Self.format(value, step: 1000) }

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    private static func format(_ raw: UInt64, step: Double) -> String {
        var value = Double(raw)
        var unit = 0
        while value >= step && unit < units.count - 1 {
            value /= step
            unit += 1
        }
        switch unit {
        case 0: return "\(raw) B"
        case _ where value >= 100: return String(format: "%.0f %@", value, units[unit])
        case _ where value >= 10: return String(format: "%.1f %@", value, units[unit])
        default: return String(format: "%.2f %@", value, units[unit])
        }
    }
}

extension Sequence where Element == Bytes {
    func sum() -> Bytes { reduce(.zero, +) }
}

/// A fraction in `0.0...1.0`.
struct Ratio: Hashable, Comparable, Sendable {
    let value: Double

    static let zero = Ratio(0)

    init(_ value: Double) {
        self.value = value.isNaN ? 0 : min(max(value, 0), 1)
    }

    static func < (lhs: Ratio, rhs: Ratio) -> Bool { lhs.value < rhs.value }

    var percent: Percent { Percent(value * 100) }
}

/// A percentage. Unlike ``Ratio`` this may exceed 100: per-process CPU usage
/// is reported relative to one core, so a process using four cores is 400%.
struct Percent: Hashable, Comparable, Sendable, CustomStringConvertible {
    let value: Double

    static let zero = Percent(0)

    init(_ value: Double) {
        self.value = value.isNaN || value < 0 ? 0 : value
    }

    static func < (lhs: Percent, rhs: Percent) -> Bool { lhs.value < rhs.value }

    static func + (lhs: Percent, rhs: Percent) -> Percent { Percent(lhs.value + rhs.value) }

    /// Converts to a ratio relative to `fullScale` percent (e.g. `100 * cores`).
    func ratio(of fullScale: Double) -> Ratio {
        fullScale <= 0 ? .zero : Ratio(value / fullScale)
    }

    var description: String {
        value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }
}

/// An event count per second, derived from two cumulative counter samples.
struct Rate: Hashable, Comparable, Sendable, CustomStringConvertible {
    let perSecond: Double

    static let zero = Rate(perSecond: 0)

    init(perSecond: Double) {
        self.perSecond = perSecond.isFinite && perSecond > 0 ? perSecond : 0
    }

    /// Rate between two readings of a monotonically increasing counter.
    /// Counter resets (e.g. PID reuse) yield zero rather than a bogus spike.
    static func between(_ previous: UInt64, _ current: UInt64, over elapsed: Duration) -> Rate {
        let seconds = elapsed.seconds
        guard seconds > 0, current >= previous else { return .zero }
        return Rate(perSecond: Double(current - previous) / seconds)
    }

    static func < (lhs: Rate, rhs: Rate) -> Bool { lhs.perSecond < rhs.perSecond }

    static func + (lhs: Rate, rhs: Rate) -> Rate { Rate(perSecond: lhs.perSecond + rhs.perSecond) }

    var description: String {
        switch perSecond {
        case 1_000_000...: String(format: "%.1fM/s", perSecond / 1_000_000)
        case 1_000...: String(format: "%.1fk/s", perSecond / 1_000)
        default: String(format: "%.0f/s", perSecond)
        }
    }
}

/// Bytes transferred per second.
struct Throughput: Hashable, Comparable, Sendable, CustomStringConvertible {
    let bytes: Bytes

    static let zero = Throughput(bytes: .zero)

    init(bytes: Bytes) {
        self.bytes = bytes
    }

    /// Throughput between two readings of a cumulative byte counter.
    static func between(_ previous: UInt64, _ current: UInt64, over elapsed: Duration) -> Throughput {
        Throughput(bytes: Bytes(UInt64(Rate.between(previous, current, over: elapsed).perSecond)))
    }

    static func < (lhs: Throughput, rhs: Throughput) -> Bool { lhs.bytes < rhs.bytes }

    static func + (lhs: Throughput, rhs: Throughput) -> Throughput { Throughput(bytes: lhs.bytes + rhs.bytes) }

    var description: String { "\(bytes.binary)/s" }
}

/// Process identifier.
struct PID: Hashable, Comparable, Sendable, CustomStringConvertible {
    let raw: Int32

    init(_ raw: Int32) {
        self.raw = raw
    }

    static func < (lhs: PID, rhs: PID) -> Bool { lhs.raw < rhs.raw }

    var description: String { String(raw) }
}

/// Thread handle from `PROC_PIDLISTTHREADS`: unique within its process only,
/// so it is always paired with a PID.
struct ThreadID: Hashable, Sendable, CustomStringConvertible {
    let raw: UInt64

    var description: String { "0x" + String(raw, radix: 16) }
}

extension Duration {
    /// Whole and fractional seconds as a `Double`.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// Formats compactly, e.g. `3d 4h`, `12m 5s`.
    var compact: String {
        let total = max(Int64(0), components.seconds)
        let (days, hours, minutes, seconds) = (total / 86_400, (total / 3600) % 24, (total / 60) % 60, total % 60)
        switch (days, hours, minutes) {
        case (0, 0, 0): return "\(seconds)s"
        case (0, 0, _): return "\(minutes)m \(seconds)s"
        case (0, _, _): return "\(hours)h \(minutes)m"
        default: return "\(days)d \(hours)h"
        }
    }
}
