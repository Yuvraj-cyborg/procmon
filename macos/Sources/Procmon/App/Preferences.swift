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

@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let appearance = "appearance"
        static let groupByApp = "groupByApp"
        static let showAppleDrivers = "showAppleDrivers"
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        groupByApp = defaults.object(forKey: Key.groupByApp) as? Bool ?? true
        showAppleDrivers = defaults.bool(forKey: Key.showAppleDrivers)
    }

    /// Sets the whole app's appearance; `nil` follows the system.
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}
