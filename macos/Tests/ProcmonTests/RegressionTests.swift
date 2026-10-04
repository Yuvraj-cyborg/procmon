import CoreGraphics
import Foundation
import Testing
@testable import Procmon

@Suite struct RegressionTests {
    @Test func symlinkedScanRootIsFollowed() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("procmon-target-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("procmon-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        try Data(repeating: 1, count: 8192).write(to: target.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let tree = try Scanner.scan(root: link.path, progress: ScanProgress())
        #expect(tree[.root].files == 1)
    }

    @Test func omittedChildrenKeepTheirShareOfTheMap() {
        var tree = FileTree(rootPath: "/r", rootSize: Bytes(200 * 100), rootFiles: 200)
        let children = (0..<200).map { index in
            tree.append(name: "f\(index)", size: Bytes(100), category: .other, files: 1, parent: .root)
        }
        tree.setChildren(children, of: .root)

        let tiles = TreemapLayout.tiles(tree, current: .root, in: CGSize(width: 1000, height: 1000))
        let overflow = tiles.filter(\.isOverflow)
        #expect(overflow.count == 1)
        #expect(tiles.count == TreemapLayout.maxTiles + 1)
        // 50 of 200 equal children are folded away: a quarter of the map, less gaps.
        let share = (overflow[0].rect.width + TreemapLayout.gap) * (overflow[0].rect.height + TreemapLayout.gap) / 1_000_000
        #expect(abs(share - 0.25) < 0.01)
    }

    @Test func identicalDevicesGetDistinctIDs() {
        let hub: [String: Any] = ["_name": "USB Hub", "manufacturer": "Acme"]
        let report: [String: Any] = ["SPUSBHostDataType": [["_name": "Bus", "_items": [hub, hub]]]]
        let devices = DeviceInventory.parseProfiler(report)
        #expect(devices.count == 2)
        #expect(Set(devices.map(\.id)).count == 2)
    }

    @MainActor @Test func trashRefusesWhenTheScanChanged() {
        var tree = FileTree(rootPath: "/r", rootSize: .zero, rootFiles: 0)
        let node = tree.append(name: "x", size: .zero, category: .other, files: 1, parent: .root)
        let storage = StorageModel()
        #expect(throws: StorageModel.ActionError.self) {
            try storage.trash(node, path: "/r/x", generation: storage.generation)
        }
    }
}

@Suite struct PermissionTests {
    @Test func excludedFoldersAreNotEntered() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("procmon-exclude-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        for folder in ["open", "private"] {
            try FileManager.default.createDirectory(atPath: base + "/" + folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: base + "/" + folder + "/file"))
        }
        let tree = try Scanner.scan(root: base, progress: ScanProgress(), excluding: [base + "/private"])
        #expect(tree[.root].files == 1)
        #expect(tree.skipped == 1)
    }

    @Test func promptingFoldersCoverBothHomePaths() {
        let folders = Permissions.promptingFolders(home: "/Users/me")
        #expect(folders.contains("/Users/me/Documents"))
        #expect(folders.contains("/System/Volumes/Data/Users/me/Desktop"))
        #expect(!folders.contains("/Users/me/Library/Caches"))
    }

    @Test func onlyScansReachingProtectedFoldersAsk() {
        #expect(Permissions.touchesProtectedFolders("/", home: "/Users/me"))
        #expect(Permissions.touchesProtectedFolders("/Users/me", home: "/Users/me"))
        #expect(Permissions.touchesProtectedFolders("/Users/me/Documents/Work", home: "/Users/me"))
        #expect(Permissions.touchesProtectedFolders("/System/Volumes/Data", home: "/Users/me"))
        #expect(!Permissions.touchesProtectedFolders("/Users/me/Library/Caches", home: "/Users/me"))
        #expect(!Permissions.touchesProtectedFolders("/Applications", home: "/Users/me"))
        #expect(!Permissions.touchesProtectedFolders("/Users/me/Doc", home: "/Users/me"))
    }
}
