// Device inventory from `system_profiler`, `kmutil` and `systemextensionsctl`.
//
// These are Apple's supported, stable interfaces for this information. The
// JSON keys differ between macOS versions, so parsing is defensive and every
// field is optional.

import Foundation

private protocol Numbered {
    var ordinal: Int { get set }
}

extension Device: Numbered {}
extension Driver: Numbered {}

extension Array where Element: Numbered {
    /// Gives every entry a distinct ``Numbered/ordinal``, its position here.
    fileprivate func numbered() -> [Element] {
        enumerated().map { index, element in
            var element = element
            element.ordinal = index
            return element
        }
    }
}

enum DeviceInventory {
    private static let profilerTypes = [
        "SPUSBHostDataType", "SPUSBDataType", "SPThunderboltDataType", "SPBluetoothDataType",
        "SPDisplaysDataType", "SPAudioDataType", "SPCameraDataType", "SPNetworkDataType",
        "SPStorageDataType", "SPHardwareDataType",
    ]

    /// Collects the current inventory. Slow (a second or more); never call
    /// it on the main thread.
    static func collect() -> Inventory {
        var inventory = Inventory()
        do {
            let json = try Subprocess.run("/usr/sbin/system_profiler", ["-json", "-detailLevel", "mini"] + profilerTypes)
            if let report = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                inventory.devices = parseProfiler(report, activeInterfaces: InterfaceProbe.activeInterfaces())
                inventory.machineName = section(report, "SPHardwareDataType").first.flatMap { text($0, "machine_name") }
            }
        } catch {
            inventory.errors.append("system_profiler: \(error)")
        }
        do {
            inventory.drivers += parseKmutil(try Subprocess.run("/usr/bin/kmutil", ["showloaded", "--list-only"]))
        } catch {
            inventory.errors.append("\(error)")
        }
        do {
            inventory.drivers += parseSystemExtensions(try Subprocess.run("/usr/bin/systemextensionsctl", ["list"]))
        } catch {
            inventory.errors.append("\(error)")
        }
        inventory.drivers = inventory.drivers.numbered()
        return inventory
    }

    // MARK: JSON helpers

    typealias Object = [String: Any]

    private static func text(_ value: Object, _ keys: String...) -> String? {
        for key in keys {
            if let string = value[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func items(_ value: Object) -> [Object] {
        value["_items"] as? [Object] ?? []
    }

    private static func section(_ report: Object, _ key: String) -> [Object] {
        report[key] as? [Object] ?? []
    }

    /// Strips `system_profiler`'s enum-ish prefixes: `spdisplays_internal` → `internal`.
    private static func humanize(_ raw: String, prefix: String) -> String {
        (raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw).replacingOccurrences(of: "_", with: " ")
    }

    // MARK: system_profiler

    /// `activeInterfaces` are BSD names with an address; `system_profiler`'s
    /// short report does not say which interfaces are connected.
    static func parseProfiler(_ report: Object, activeInterfaces: Set<String> = []) -> [Device] {
        var devices: [Device] = []
        for key in ["SPUSBHostDataType", "SPUSBDataType"] {
            for bus in section(report, key) {
                collectUSB(bus, into: &devices)
            }
        }
        for bus in section(report, "SPThunderboltDataType") {
            collectThunderbolt(bus, into: &devices)
        }
        for controller in section(report, "SPBluetoothDataType") {
            collectBluetooth(controller, into: &devices)
        }
        for gpu in section(report, "SPDisplaysDataType") {
            collectDisplay(gpu, into: &devices)
        }
        for group in section(report, "SPAudioDataType") {
            devices += items(group).compactMap(audioDevice)
        }
        devices += section(report, "SPCameraDataType").compactMap(cameraDevice)
        devices += section(report, "SPNetworkDataType").compactMap { networkDevice($0, active: activeInterfaces) }
        devices += storageDevices(section(report, "SPStorageDataType"))
        return devices
            .sorted { ($0.deviceClass, $0.status, $0.name) < ($1.deviceClass, $1.status, $1.name) }
            .numbered()
    }

    /// USB buses are built into the Mac; only what hangs off them is interesting.
    private static func collectUSB(_ node: Object, into devices: inout [Device]) {
        for child in items(node) {
            if let name = text(child, "_name") {
                let facts = [text(child, "USBDeviceKeyVendorName", "manufacturer"), text(child, "USBDeviceKeyLinkSpeed", "device_speed")]
                    .compactMap { $0 }
                    .map { humanize($0, prefix: "usb_") }
                devices.append(Device(deviceClass: .usb, name: name, status: .connected, facts: facts, driver: text(child, "Driver")))
            }
            collectUSB(child, into: &devices)
        }
    }

    private static func collectThunderbolt(_ node: Object, into devices: inout [Device]) {
        for child in items(node) {
            if let name = text(child, "_name", "device_name_key") {
                let facts = [text(child, "vendor_name_key"), text(child, "mode_key")].compactMap { $0 }
                devices.append(Device(deviceClass: .thunderbolt, name: name, status: .connected, facts: facts, driver: nil))
            }
            collectThunderbolt(child, into: &devices)
        }
    }

    private static func collectBluetooth(_ controller: Object, into devices: inout [Device]) {
        for (key, status) in [("device_connected", DeviceStatus.connected), ("device_not_connected", .available)] {
            // Each entry is a single-key object: `{ "Device name": { ...props } }`.
            for entry in controller[key] as? [Object] ?? [] {
                for (name, value) in entry {
                    guard let props = value as? Object else { continue }
                    let battery = text(props, "device_batteryLevelMain", "device_batteryLevel").map { "Battery \($0)" }
                    let facts = [text(props, "device_minorType"), battery].compactMap { $0 }
                    devices.append(Device(deviceClass: .bluetooth, name: name, status: status, facts: facts, driver: nil))
                }
            }
        }
    }

    private static func collectDisplay(_ gpu: Object, into devices: inout [Device]) {
        if let name = text(gpu, "_name", "sppci_model") {
            let cores = text(gpu, "sppci_cores").map { "\($0) GPU cores" }
            let metal = text(gpu, "spdisplays_mtlgpufamilysupport")
                .map { humanize($0, prefix: "spdisplays_").replacingOccurrences(of: "metal", with: "Metal ") }
            devices.append(Device(deviceClass: .display, name: name, status: .connected, facts: [cores, metal].compactMap { $0 }, driver: nil))
        }
        for display in gpu["spdisplays_ndrvs"] as? [Object] ?? [] {
            guard let name = text(display, "_name") else { continue }
            let online = text(display, "spdisplays_online") != "spdisplays_no"
            let facts = [
                text(display, "_spdisplays_resolution", "spdisplays_resolution"),
                text(display, "spdisplays_connection_type").map { humanize($0, prefix: "spdisplays_") },
            ].compactMap { $0 }
            devices.append(Device(deviceClass: .display, name: name, status: online ? .connected : .faulty, facts: facts, driver: nil))
        }
    }

    private static func audioDevice(_ item: Object) -> Device? {
        guard let name = text(item, "_name") else { return nil }
        func channels(_ key: String) -> Bool { ((item[key] as? NSNumber)?.intValue ?? 0) > 0 }
        let direction: String? = switch (channels("coreaudio_device_input"), channels("coreaudio_device_output")) {
        case (true, true): "Input & output"
        case (true, false): "Input"
        case (false, true): "Output"
        case (false, false): nil
        }
        let transport = text(item, "coreaudio_device_transport")
            .map { humanize($0, prefix: "coreaudio_device_type_") }
            .flatMap { $0 == "unknown" ? nil : $0 }
        let isDefault = ["coreaudio_default_audio_input_device", "coreaudio_default_audio_output_device"]
            .contains { text(item, $0) == "spaudio_yes" }
        return Device(
            deviceClass: .audio, name: name, status: .connected,
            facts: [direction, transport, isDefault ? "Default" : nil].compactMap { $0 }, driver: nil
        )
    }

    private static func cameraDevice(_ item: Object) -> Device? {
        guard let name = text(item, "_name") else { return nil }
        return Device(deviceClass: .camera, name: name, status: .connected, facts: [text(item, "spcamera_model-id")].compactMap { $0 }, driver: nil)
    }

    private static func networkDevice(_ item: Object, active: Set<String>) -> Device? {
        guard let name = text(item, "_name") else { return nil }
        let interface = text(item, "interface")
        let hasAddress = !((item["ip_address"] as? [Any]) ?? []).isEmpty || interface.map(active.contains) == true
        let hardware = text(item, "hardware", "type").map { $0 == "AirPort" ? "Wi-Fi" : $0 }
        return Device(
            deviceClass: .network, name: name, status: hasAddress ? .connected : .available,
            facts: [interface, hardware].compactMap { $0 }, driver: nil
        )
    }

    /// One device per physical drive (volumes share drives); disk images are skipped.
    private static func storageDevices(_ volumes: [Object]) -> [Device] {
        var seen = Set<String>()
        return volumes.compactMap { volume -> Device? in
            guard let drive = volume["physical_drive"] as? Object,
                  text(drive, "protocol") != "Disk Image",
                  let name = text(drive, "device_name"),
                  seen.insert(name).inserted
            else { return nil }
            let smart = text(drive, "smart_status")
            let isInternal = text(drive, "is_internal_disk") == "yes"
            let facts = [
                text(drive, "protocol"),
                text(drive, "medium_type")?.uppercased(),
                isInternal ? "Internal" : "External",
                smart.map { "SMART \($0)" },
            ].compactMap { $0 }
            let status: DeviceStatus = if let smart, smart != "Verified" { .faulty } else { .connected }
            return Device(deviceClass: .storage, name: name, status: status, facts: facts, driver: nil)
        }
    }

    // MARK: kmutil and systemextensionsctl

    /// Parses `kmutil showloaded --list-only`:
    /// `Index Refs Address Size Wired Name (Version) UUID <Linked Against>`.
    static func parseKmutil(_ text: String) -> [Driver] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 6, Int(fields[0]) != nil else { return nil }
            let version = fields.count > 6 && fields[6].hasPrefix("(") && fields[6].hasSuffix(")")
                ? String(fields[6].dropFirst().dropLast())
                : nil
            return Driver(
                bundleID: String(fields[5]), name: nil, version: version,
                kind: .kernelExtension, state: .running, references: Int(fields[1])
            )
        }
    }

    /// Parses `systemextensionsctl list`, whose rows are tab-separated:
    /// `enabled  active  teamID  bundleID (version)  name  [state]`,
    /// grouped under `--- com.apple.system_extension.<category>` headers.
    static func parseSystemExtensions(_ text: String) -> [Driver] {
        var kind = DriverKind.systemExtension
        var drivers: [Driver] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("--- ") {
                kind = line.contains("driver_extension") ? .driverKit : .systemExtension
                continue
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 6, columns[0] != "enabled" else { continue }
            let identity = columns[3]
            let bundleID: Substring
            var version: String?
            if let open = identity.range(of: " (") {
                bundleID = identity[..<open.lowerBound]
                let rest = identity[open.upperBound...]
                version = rest.hasSuffix(")") ? String(rest.dropLast()) : String(rest)
            } else {
                bundleID = identity
            }
            let raw = columns[5].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let state: DriverState = switch raw {
            case "activated enabled": .running
            case let s where s.contains("waiting for user"): .awaitingApproval
            case let s where s.contains("disabled"): .disabled
            default: .other(raw)
            }
            let name = columns[4].trimmingCharacters(in: .whitespaces)
            drivers.append(Driver(
                bundleID: bundleID.trimmingCharacters(in: .whitespaces),
                name: name.isEmpty ? nil : name,
                version: version,
                kind: kind,
                state: state,
                references: nil
            ))
        }
        return drivers
    }
}
