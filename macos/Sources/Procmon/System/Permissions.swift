// Full Disk Access, asked for once instead of folder by folder.

import AppKit
import Darwin
import Foundation

enum Permissions {
    /// Whether Procmon can read everything. Only Full Disk Access opens the
    /// privacy database, and trying never shows a prompt.
    static var hasFullDiskAccess: Bool {
        let database = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(database, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// Opens Privacy & Security › Full Disk Access in System Settings.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Folders macOS asks about one at a time unless Procmon has Full Disk
    /// Access. A scan without it skips them, so no prompts appear.
    static func promptingFolders(home: String = NSHomeDirectory()) -> Set<String> {
        let relative = [
            "Desktop", "Documents", "Downloads",
            "Library/Mobile Documents", "Library/CloudStorage",
            "Library/Containers", "Library/Group Containers",
            "Pictures/Photos Library.photoslibrary",
        ]
        let homes = [home, "/System/Volumes/Data" + home]
        return Set(homes.flatMap { base in relative.map { base + "/" + $0 } })
    }

    /// Whether scanning `root` would reach a folder macOS asks about.
    static func touchesProtectedFolders(_ root: String, home: String = NSHomeDirectory()) -> Bool {
        let base = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        return promptingFolders(home: home).contains { folder in
            folder == base || folder.hasPrefix(base == "/" ? "/" : base + "/") || base.hasPrefix(folder + "/")
        }
    }
}
