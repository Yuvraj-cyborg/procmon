// GPU utilisation from the IOAccelerator's public performance statistics.

import Foundation
import IOKit

enum GPUProbe {
    /// The busiest GPU, or `nil` when none reports utilisation.
    static func sample() -> GPUStats? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var busiest: GPUStats?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let statistics = property(service, "PerformanceStatistics") as? [String: Any],
                  let utilization = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
            else { continue }
            let name = (property(service, "model") as? String) ?? "GPU"
            let reading = GPUStats(name: name, utilization: Ratio(utilization / 100))
            if busiest.map({ reading.utilization > $0.utilization }) ?? true {
                busiest = reading
            }
        }
        return busiest
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
