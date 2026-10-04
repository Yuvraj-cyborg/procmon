// User preferences persisted in UserDefaults.

import AppKit
import Observation

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    fileprivate var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// How often the numbers refresh, as in Activity Monitor's View menu.
enum UpdateSpeed: String, CaseIterable, Identifiable {
    case fast, normal, slow

    var id: Self { self }

    var interval: Duration {
        switch self {
        case .fast: .seconds(1)
        case .normal: .seconds(2)
        case .slow: .seconds(5)
        }
    }

    var label: String {
        switch self {
        case .fast: "Every second"
        case .normal: "Every 2 seconds"
        case .slow: "Every 5 seconds"
        }
    }
}

@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let appearance = "appearance"
        static let groupByApp = "groupByApp"
        static let showAppleDrivers = "showAppleDrivers"
        static let updateSpeed = "updateSpeed"
        static let askedForDiskAccess = "askedForDiskAccess"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    /// Memory page: roll helper processes up into the app that owns them.
    var groupByApp: Bool {
        didSet { defaults.set(groupByApp, forKey: Key.groupByApp) }
    }

    /// Devices page: include Apple's own kernel extensions.
    var showAppleDrivers: Bool {
        didSet { defaults.set(showAppleDrivers, forKey: Key.showAppleDrivers) }
    }

    var updateSpeed: UpdateSpeed {
        didSet { defaults.set(updateSpeed.rawValue, forKey: Key.updateSpeed) }
    }

    /// Storage: the Full Disk Access question was answered once, so scans
    /// never ask again (they leave protected folders out instead).
    var askedForDiskAccess: Bool {
        didSet { defaults.set(askedForDiskAccess, forKey: Key.askedForDiskAccess) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        groupByApp = defaults.object(forKey: Key.groupByApp) as? Bool ?? true
        showAppleDrivers = defaults.bool(forKey: Key.showAppleDrivers)
        askedForDiskAccess = defaults.bool(forKey: Key.askedForDiskAccess)
        // Every two seconds keeps graphs smooth at half the cost of every second.
        updateSpeed = defaults.string(forKey: Key.updateSpeed).flatMap(UpdateSpeed.init) ?? .normal
    }

    /// Sets the whole app's appearance; `nil` follows the system.
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}
