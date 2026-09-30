// Facts about this Mac that do not change while Procmon runs.

import Foundation

struct SystemInfo: Sendable {
    /// e.g. "Apple M4 Pro".
    let chip: String
    /// e.g. "Mac16,8".
    let modelIdentifier: String
    /// e.g. "macOS 26.6".
    let osVersion: String
    let memory: Bytes
    let logicalCores: Int
    let performanceCores: Int?
    let efficiencyCores: Int?
    let bootTime: Date?

    static let current: SystemInfo = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return SystemInfo(
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Unknown processor",
            modelIdentifier: Sysctl.string("hw.model") ?? "Mac",
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion)\(patch)",
            memory: Host.physicalMemory,
            logicalCores: ProcessInfo.processInfo.processorCount,
            performanceCores: Sysctl.int32("hw.perflevel0.logicalcpu").map(Int.init),
            efficiencyCores: Sysctl.int32("hw.perflevel1.logicalcpu").map(Int.init),
            bootTime: Host.bootTime
        )
    }()

    /// e.g. "10 cores" or "4P + 6E cores".
    var coreSummary: String {
        if let performanceCores, let efficiencyCores, efficiencyCores > 0 {
            return "\(performanceCores)P + \(efficiencyCores)E cores"
        }
        return "\(logicalCores) cores"
    }

    var uptime: Duration? {
        bootTime.map { .seconds(max(0, Date().timeIntervalSince($0))) }
    }
}
