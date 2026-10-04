// The rules that decide what Clean Up may offer. Every rule is a pure
// function of what was measured, so each decision can be tested and explained.

import Foundation

/// A kind of disk clutter, and why removing it is safe.
enum JunkKind: String, CaseIterable, Identifiable, Sendable {
    case appCaches, developerCaches, logs, temporaryFiles, trash

    var id: Self { self }

    var title: String {
        switch self {
        case .appCaches: "App caches"
        case .developerCaches: "Developer caches"
        case .logs: "Old logs"
        case .temporaryFiles: "Old temporary files"
        case .trash: "Trash"
        }
    }

    var explanation: String {
        switch self {
        case .appCaches: "Apps rebuild these as needed. Only apps that are not running, and never macOS's own caches."
        case .developerCaches: "Build products and package downloads that tools fetch again. Skipped while the tool runs."
        case .logs: "Log files and crash reports older than a week."
        case .temporaryFiles: "Files apps left in your temporary folder and have not touched for three days."
        case .trash: "Everything in the Trash. It cannot be put back afterwards."
        }
    }

    var symbol: String {
        switch self {
        case .appCaches: "archivebox"
        case .developerCaches: "hammer"
        case .logs: "doc.text"
        case .temporaryFiles: "clock.arrow.circlepath"
        case .trash: "trash"
        }
    }

    /// Selected when the page opens. The Trash is the user's to empty.
    var isRecommended: Bool { self != .trash }
}

/// One file or folder Clean Up can remove.
struct JunkItem: Identifiable, Sendable {
    let path: String
    let name: String
    let size: Bytes
    let kind: JunkKind
    /// Removing this item must never reach outside this folder.
    let root: String
    /// Processes that must not be running when it is removed.
    let blockedBy: Set<String>

    var id: String { path }
}

struct JunkGroup: Identifiable, Sendable {
    let kind: JunkKind
    let items: [JunkItem]
    /// macOS would not let Procmon look inside, so "nothing" means "unknown".
    var isUnreadable = false

    var id: JunkKind { kind }
    var size: Bytes { items.map(\.size).sum() }
}

/// What is running right now, for the "never while in use" rules.
struct RunningSet: Sendable {
    /// Bundle identifiers, lowercased.
    let bundleIDs: Set<String>
    /// Process and app names, lowercased.
    let names: Set<String>

    /// Whether any of `keys` (process names or bundle ids, lowercased) is running.
    /// A key also matches a running app it extends, e.g. `com.foo.app.cache`.
    func isRunning(anyOf keys: Set<String>) -> Bool {
        keys.contains { key in
            names.contains(key) || bundleIDs.contains(where: { key == $0 || key.hasPrefix($0 + ".") })
        }
    }
}

enum CleanupRules {
    /// Things written this recently may be in use, whatever else is true.
    static let inUseWindow: TimeInterval = 10 * 60
    static let logAge: TimeInterval = 7 * 86_400
    static let temporaryAge: TimeInterval = 3 * 86_400

    /// Apple caches that belong to developer tools rather than the system.
    static let appleCacheExceptions: Set<String> = ["com.apple.dt.xcode", "com.apple.dt.instruments"]

    /// Caches without an Apple prefix that system services still rely on.
    static let protectedCacheNames: Set<String> = [
        "cloudkit", "metadata", "geoservices", "familycircle", "passkit", "siritts", "com.crashlytics",
        "temporaryitems", "tracking", "keyboard", "ls", "fscacheddata",
    ]

    /// Whether a folder directly in `~/Library/Caches` can go.
    static func isRemovableCache(named name: String, running: RunningSet, newest: Date, now: Date) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("com.apple.") && !appleCacheExceptions.contains(lower) { return false }
        if protectedCacheNames.contains(lower) { return false }
        // A running app owns its cache folder, and helpers extend its bundle id.
        if running.isRunning(anyOf: [lower]) { return false }
        return now.timeIntervalSince(newest) >= inUseWindow
    }

    static func isOldLog(newest: Date, now: Date) -> Bool {
        now.timeIntervalSince(newest) >= logAge
    }

    static func isStaleTemporary(named name: String, newest: Date, now: Date) -> Bool {
        // Apple's own temporary state and open sockets stay.
        guard !name.hasPrefix("com.apple."), !name.hasSuffix(".socket"), !name.hasSuffix(".sock") else { return false }
        return now.timeIntervalSince(newest) >= temporaryAge
    }

    /// A developer cache: where it lives in the home folder and which tools
    /// must be idle before it is removed.
    struct DeveloperCache: Sendable {
        let label: String
        let path: String
        let blockedBy: Set<String>
    }

    static let developerCaches: [DeveloperCache] = [
        DeveloperCache(label: "Xcode DerivedData", path: "Library/Developer/Xcode/DerivedData", blockedBy: ["xcode", "xcodebuild"]),
        DeveloperCache(label: "Simulator caches", path: "Library/Developer/CoreSimulator/Caches", blockedBy: ["simulator"]),
        DeveloperCache(label: "npm cache", path: ".npm/_cacache", blockedBy: ["npm"]),
        DeveloperCache(label: "Cargo downloads", path: ".cargo/registry/cache", blockedBy: ["cargo"]),
        DeveloperCache(label: "Gradle caches", path: ".gradle/caches", blockedBy: ["java", "gradle"]),
        DeveloperCache(label: "Bun cache", path: ".bun/install/cache", blockedBy: ["bun"]),
    ]

    /// Friendlier names for well-known cache folders.
    static let knownCacheNames: [String: String] = [
        "homebrew": "Homebrew downloads", "pip": "pip downloads", "yarn": "Yarn cache", "go-build": "Go build cache",
        "cocoapods": "CocoaPods cache", "org.swift.swiftpm": "Swift packages", "com.apple.dt.xcode": "Xcode",
        "ms-playwright": "Playwright browsers", "node-gyp": "node-gyp headers", "deno": "Deno cache",
    ]

    /// `path` lies strictly inside `root`, after resolving `..` and `.`.
    static func isInside(_ path: String, root: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        let base = (root as NSString).standardizingPath
        return standardized.hasPrefix(base + "/") && standardized != base
    }

    // MARK: Memory and CPU

    /// Apps are only suggested once watched for this long.
    static let observationWindow: TimeInterval = 60
    /// An app using less than this share of a core on average counts as idle.
    static let idleCPU = 3.0
    /// Sustained CPU, in percent of one core, that counts as running away.
    static let runawayCPU = 80.0

    /// macOS processes that keep the desktop working; never suggested.
    static let essentialProcesses: Set<String> = [
        "finder", "dock", "systemuiserver", "controlcenter", "windowmanager", "loginwindow", "notificationcenter",
        "spotlight", "textinputmenuagent", "universalcontrol", "windowserver", "coreaudiod", "launchd",
    ]

    /// Whether an idle app is worth quitting for its memory.
    static func isIdleMemoryHog(memory: Bytes, totalMemory: Bytes, averageCPU: Double, watched: TimeInterval, isActive: Bool) -> Bool {
        let threshold = max(Bytes(300 * 1024 * 1024).value, totalMemory.value / 50)
        return !isActive && watched >= observationWindow && averageCPU < idleCPU && memory.value >= threshold
    }

    /// Why a process counts as running away, or `nil` if it does not.
    static func runawayReason(averageCPU: Double, watched: TimeInterval, isSpinning: Bool, noise: [NoiseReason]) -> String? {
        if isSpinning { return "A thread has been spinning at full speed" }
        if watched >= 30, averageCPU >= runawayCPU {
            return String(format: "Averaging %.0f%% of a core for the last minute", averageCPU)
        }
        if let reason = noise.first { return reason.label }
        return nil
    }
}
