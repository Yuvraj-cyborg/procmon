// Mounted volumes, and the Finder actions Procmon offers on scanned items.

import AppKit
import Foundation

struct Volume: Identifiable, Sendable {
    let name: String
    let mountPoint: String
    /// Where a scan of this volume starts (see ``Volume/all()``).
    let scanPath: String
    let format: String
    let total: Bytes
    let available: Bytes
    let isRemovable: Bool

    var id: String { mountPoint }
    var used: Bytes { total - available }

    /// On macOS the startup disk appears as `/`, the sealed read-only system
    /// snapshot. Every user file lives on `/System/Volumes/Data`, a separate
    /// APFS volume that a same-filesystem scan of `/` would never enter.
    private static let dataVolume = "/System/Volumes/Data"

    /// Mounted volumes worth showing to a person, internal ones first.
    static func all() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let hasDataVolume = FileManager.default.fileExists(atPath: dataVolume)
        let volumes = urls.compactMap { url -> Volume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            // "Important usage" counts purgeable space as free, like Finder does.
            let available = values.volumeAvailableCapacityForImportantUsage.map(Int.init) ?? values.volumeAvailableCapacity ?? 0
            let isRoot = values.volumeIsRootFileSystem ?? (url.path == "/")
            return Volume(
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                mountPoint: url.path,
                scanPath: isRoot && hasDataVolume ? dataVolume : url.path,
                format: values.volumeLocalizedFormatDescription ?? "",
                total: Bytes(UInt64(total)),
                available: Bytes(UInt64(max(0, available))),
                isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            )
        }
        return volumes.sorted { ($0.isRemovable ? 1 : 0, $1.total) < ($1.isRemovable ? 1 : 0, $0.total) }
    }

    /// The volume holding the user's files.
    static func startup(in volumes: [Volume]) -> Volume? {
        volumes.first { $0.mountPoint == "/" } ?? volumes.first
    }
}

enum Finder {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Moves `path` to the user's Trash, where Finder can put it back.
    static func moveToTrash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
}
