// Battery state, power assertions and physical disk traffic, from IOKit's
// public interfaces.

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

enum PowerProbe {
    /// Assertion types that keep the Mac (or its display) awake.
    private static let preventingSleep: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep", "NoIdleSleepAssertion",
        "NoDisplaySleepAssertion",
    ]

    /// Processes holding a sleep-preventing assertion, with the reasons they gave.
    static func sleepPreventers() -> [PID: [String]] {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let byProcess = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [:] }
        var result: [PID: [String]] = [:]
        for (pid, list) in byProcess {
            let reasons = list.compactMap { assertion -> String? in
                guard let type = assertion["AssertType"] as? String, preventingSleep.contains(type) else { return nil }
                return (assertion["AssertName"] as? String) ?? type
            }
            if !reasons.isEmpty {
                result[PID(pid.int32Value)] = reasons
            }
        }
        return result
    }

    /// `nil` on Macs without a battery.
    static func battery() -> BatteryStatus? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        guard let description = sources.lazy
            .compactMap({ IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] })
            .first(where: { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType })
        else { return nil }

        let current = (description[kIOPSCurrentCapacityKey] as? Int) ?? 0
        let maximum = max((description[kIOPSMaxCapacityKey] as? Int) ?? 100, 1)
        let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
        let onPower = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        // Minutes; -1 while macOS is still estimating, 0 when not applicable.
        let minutes = charging ? description[kIOPSTimeToFullChargeKey] as? Int : description[kIOPSTimeToEmptyKey] as? Int

        let registry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { if registry != 0 { IOObjectRelease(registry) } }
        func number(_ key: String) -> Double? {
            guard registry != 0 else { return nil }
            return (IORegistryEntryCreateCFProperty(registry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.doubleValue
        }
        let design = number("DesignCapacity")
        let full = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity")
        let health = design.flatMap { design in full.map { Ratio($0 / design) } }
        let power = number("Voltage").flatMap { volts in number("InstantAmperage").map { volts * $0 / 1_000_000 } }

        return BatteryStatus(
            level: Ratio(Double(current) / Double(maximum)),
            isCharging: charging,
            onPower: onPower,
            timeRemaining: minutes.flatMap { $0 > 0 ? .seconds($0 * 60) : nil },
            cycleCount: number("CycleCount").map(Int.init),
            health: health,
            condition: description["BatteryHealth"] as? String,
            power: power,
            temperature: number("Temperature").map { $0 / 100 }
        )
    }
}

/// Bytes read and written by physical drives. Disk images are skipped: their
/// traffic already shows up on the drive holding the image file.
struct DiskActivityProbe {
    private var previous: (read: UInt64, written: UInt64)?
    private var previousAt: ContinuousClock.Instant?

    mutating func sample(at now: ContinuousClock.Instant) -> DiskActivity? {
        let totals = Self.totals()
        defer {
            previous = totals
            previousAt = now
        }
        guard let previous, let previousAt else { return nil }
        let elapsed = now - previousAt
        return DiskActivity(
            read: .between(previous.read, totals.read, over: elapsed),
            written: .between(previous.written, totals.written, over: elapsed)
        )
    }

    static func totals() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        var driver = IOIteratorNext(iterator)
        while driver != 0 {
            defer {
                IOObjectRelease(driver)
                driver = IOIteratorNext(iterator)
            }
            guard !isDiskImage(driver),
                  let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? [String: Any]
            else { continue }
            read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, written)
    }

    /// Disk images are driven by `IOHDIXHDDrive…` providers.
    private static func isDiskImage(_ driver: io_object_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        var name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(parent, &name)
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("HDIX")
    }
}
