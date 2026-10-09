// GPU readings from the IOAccelerator's public performance statistics, and
// each process's GPU time from the accelerator's user clients. Both are plain
// registry properties: no privileges needed, about a millisecond to read.

import Foundation
import IOKit

enum GPUProbe {
    /// The busiest GPU, or `nil` when none reports utilisation.
    static func sample() -> GPUStats? {
        var busiest: GPUStats?
        forEachAccelerator { service in
            guard let statistics = property(service, "PerformanceStatistics") as? [String: Any],
                  let utilization = number(statistics, "Device Utilization %")
            else { return }
            let percent = { (key: String) in number(statistics, key).map { Ratio($0 / 100) } }
            let bytes = { (key: String) in number(statistics, key).map { Bytes(UInt64(max(0, $0))) } }
            let reading = GPUStats(
                name: (property(service, "model") as? String) ?? "GPU",
                cores: (property(service, "gpu-core-count") as? NSNumber)?.intValue,
                utilization: Ratio(utilization / 100),
                renderer: percent("Renderer Utilization %"),
                tiler: percent("Tiler Utilization %"),
                memoryInUse: bytes("In use system memory"),
                memoryAllocated: bytes("Alloc system memory"),
                recoveries: number(statistics, "recoveryCount").map(Int.init) ?? 0
            )
            if busiest.map({ reading.utilization > $0.utilization }) ?? true {
                busiest = reading
            }
        }
        return busiest
    }

    /// GPU time each process has used, in nanoseconds, summed over every
    /// connection it opened. Processes that never touched the GPU are absent.
    static func processTimes() -> [PID: UInt64] {
        var times: [PID: UInt64] = [:]
        forEachAccelerator { service in
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(children) }
            var client = IOIteratorNext(children)
            while client != 0 {
                defer {
                    IOObjectRelease(client)
                    client = IOIteratorNext(children)
                }
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let pid = creatorPID(creator),
                      let usage = property(client, "AppUsage") as? [[String: Any]]
                else { continue }
                let total = usage.reduce(UInt64(0)) { $0 &+ ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                times[pid, default: 0] &+= total
            }
        }
        return times
    }

    /// `IOUserClientCreator` reads like `pid 632, WindowServer`.
    static func creatorPID(_ creator: String) -> PID? {
        guard creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ",") else { return nil }
        return Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]).map(PID.init)
    }

    private static func forEachAccelerator(_ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private static func number(_ dictionary: [String: Any], _ key: String) -> Double? {
        (dictionary[key] as? NSNumber)?.doubleValue
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
