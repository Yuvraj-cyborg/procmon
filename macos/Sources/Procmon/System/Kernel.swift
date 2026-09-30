// Thin, typed wrappers over the Mach and BSD calls the sampler needs.

import Darwin
import Foundation

enum Sysctl {
    /// Reads a fixed-size value by name, e.g. `hw.memsize`.
    static func value<T: BitwiseCopyable>(_ name: String, zero: T) -> T? {
        var value = zero
        var size = MemoryLayout<T>.size
        let status = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
        guard status == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }

    static func int32(_ name: String) -> Int32? { value(name, zero: Int32(0)) }
    static func uint64(_ name: String) -> UInt64? { value(name, zero: UInt64(0)) }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Converts Mach absolute-time ticks to wall-clock durations. On Apple
/// silicon a tick is 125/3 ns, so raw task times must never be used as-is.
enum MachTime {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    static func duration(ticks: UInt64) -> Duration {
        let (high, low) = ticks.multipliedFullWidth(by: timebase.numer)
        let nanoseconds = timebase.denom.dividingFullWidth((high, low)).quotient
        return .nanoseconds(Int64(clamping: nanoseconds))
    }
}

/// A C string stored inline in a fixed-size tuple, such as `pbi_name`.
func string<Tuple>(fromCTuple tuple: Tuple) -> String {
    withUnsafeBytes(of: tuple) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

enum Host {
    /// Cached: every call to `mach_host_self()` adds a send right to the port.
    private static let port = mach_host_self()

    static var physicalMemory: Bytes { Bytes(Sysctl.uint64("hw.memsize") ?? 0) }

    static var pageSize: UInt64 { UInt64(Sysctl.int32("hw.pagesize") ?? 4096) }

    static func memoryBreakdown() -> MemoryBreakdown? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(port, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let page = pageSize
        func pages(_ count: UInt64) -> Bytes { Bytes(count.multipliedReportingOverflow(by: page).partialValue) }
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        return MemoryBreakdown(
            app: pages(anonymous > purgeable ? anonymous - purgeable : 0),
            wired: pages(UInt64(stats.wire_count)),
            compressed: pages(UInt64(stats.compressor_page_count)),
            cached: pages(UInt64(stats.external_page_count) + purgeable),
            free: pages(UInt64(stats.free_count))
        )
    }

    static func memoryPressure() -> MemoryPressure {
        switch Sysctl.int32("kern.memorystatus_vm_pressure_level") {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: .unknown
        }
    }

    static func swap() -> (total: Bytes, used: Bytes) {
        guard let usage = Sysctl.value("vm.swapusage", zero: xsw_usage()) else { return (.zero, .zero) }
        return (Bytes(usage.xsu_total), Bytes(usage.xsu_used))
    }

    static func loadAverage() -> LoadAverage {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return LoadAverage(one: 0, five: 0, fifteen: 0) }
        return LoadAverage(one: loads[0], five: loads[1], fifteen: loads[2])
    }

    /// Cumulative busy and total ticks for every logical core.
    static func coreTicks() -> [CoreTicks]? {
        var processors: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(port, PROCESSOR_CPU_LOAD_INFO, &processors, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        return (0..<Int(processors)).map { cpu in
            let base = cpu * Int(CPU_STATE_MAX)
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            let busy = ticks(CPU_STATE_USER) &+ ticks(CPU_STATE_SYSTEM) &+ ticks(CPU_STATE_NICE)
            return CoreTicks(busy: busy, total: busy &+ ticks(CPU_STATE_IDLE))
        }
    }

    static var bootTime: Date? {
        guard let boot = Sysctl.value("kern.boottime", zero: timeval()) else { return nil }
        return Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
    }
}

/// One core's cumulative scheduler ticks. The kernel counters are 32-bit and
/// wrap, so differences use wrapping arithmetic.
struct CoreTicks: Sendable, Equatable {
    let busy: UInt32
    let total: UInt32

    func load(since previous: CoreTicks) -> Ratio {
        let total = total &- previous.total
        return total == 0 ? .zero : Ratio(Double(busy &- previous.busy) / Double(total))
    }
}

/// Runs a system tool to completion and returns its standard output.
enum Subprocess {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ path: String, _ arguments: [String]) throws(Failure) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure(description: "\(path): \(error.localizedDescription)")
        }
        // Drain before waiting, or a full pipe would deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\((path as NSString).lastPathComponent) exited with status \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
