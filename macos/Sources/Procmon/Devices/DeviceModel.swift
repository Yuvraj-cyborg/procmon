// Connected hardware and loaded drivers.

/// Hardware family, used for grouping and icons.
enum DeviceClass: Int, Sendable, CaseIterable, Comparable {
    case usb, thunderbolt, bluetooth, display, audio, camera, network, storage

    static func < (lhs: DeviceClass, rhs: DeviceClass) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .usb: "USB"
        case .thunderbolt: "Thunderbolt / USB4"
        case .bluetooth: "Bluetooth"
        case .display: "Displays & GPU"
        case .audio: "Audio"
        case .camera: "Cameras"
        case .network: "Network"
        case .storage: "Storage"
        }
    }

    var symbol: String {
        switch self {
        case .usb: "cable.connector"
        case .thunderbolt: "bolt.horizontal"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .display: "display"
        case .audio: "speaker.wave.2"
        case .camera: "camera"
        case .network: "network"
        case .storage: "internaldrive"
        }
    }
}

/// Whether a device is present and healthy.
enum DeviceStatus: Int, Sendable, Comparable {
    /// Something is wrong (e.g. SMART failing, display offline).
    case faulty
    case connected
    /// Known to the system (paired, configured) but not currently attached.
    case available

    static func < (lhs: DeviceStatus, rhs: DeviceStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .faulty: "Problem"
        case .connected: "Connected"
        case .available: "Not connected"
        }
    }
}

struct Device: Sendable, Equatable, Identifiable {
    let deviceClass: DeviceClass
    let name: String
    let status: DeviceStatus
    /// Short facts shown under the name, e.g. "Apple Inc.", "40 Gb/s".
    let facts: [String]
    /// Kernel driver bound to the device, when the OS reports one.
    let driver: String?
    /// Position in the inventory. Two identical hubs share every other field.
    var ordinal = 0

    var id: Int { ordinal }
}

enum DriverKind: Sendable, Equatable {
    /// Classic kernel extension loaded into the kernel.
    case kernelExtension
    /// User-space system extension (network, endpoint security, camera, …).
    case systemExtension
    /// User-space hardware driver (DriverKit `.dext`).
    case driverKit

    var label: String {
        switch self {
        case .kernelExtension: "Kernel extension"
        case .systemExtension: "System extension"
        case .driverKit: "DriverKit"
        }
    }
}

enum DriverState: Sendable, Equatable {
    /// Loaded, or activated and enabled: working.
    case running
    /// Installed but blocked until the user approves it in System Settings.
    case awaitingApproval
    /// Installed but switched off.
    case disabled
    /// Anything else the OS reports, verbatim.
    case other(String)

    var isHealthy: Bool { self == .running }

    var label: String {
        switch self {
        case .running: "Running"
        case .awaitingApproval: "Needs approval"
        case .disabled: "Disabled"
        case .other(let state): state
        }
    }
}

struct Driver: Sendable, Equatable, Identifiable {
    let bundleID: String
    /// Human-readable name when the OS provides one.
    let name: String?
    let version: String?
    let kind: DriverKind
    let state: DriverState
    /// How many other kexts link against this one; a rough "importance".
    let references: Int?
    /// Position in the inventory: the same bundle can be listed twice, e.g.
    /// an old copy waiting to uninstall next to the active one.
    var ordinal = 0

    var id: Int { ordinal }
    var isThirdParty: Bool { !bundleID.hasPrefix("com.apple.") }
    var displayName: String { name ?? bundleID }
}

/// Everything collected in one pass of the device probe.
struct Inventory: Sendable {
    var devices: [Device] = []
    var drivers: [Driver] = []
    /// Marketing name of this Mac, e.g. "MacBook Pro".
    var machineName: String?
    /// Probes that failed, so the UI can say what it could not see.
    var errors: [String] = []

    var problems: Int {
        devices.count { $0.status == .faulty } + drivers.count { !$0.state.isHealthy }
    }

    var connected: Int { devices.count { $0.status != .available } }
}
