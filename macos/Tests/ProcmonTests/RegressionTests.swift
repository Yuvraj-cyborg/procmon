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
        var tree = FileTree(rootPath: "/r", root: FileNode(
            name: "r", size: Bytes(200 * 100), category: .folder, files: 200, parent: nil, children: []
        ))
        var children: [NodeID] = []
        for index in 0..<200 {
            children.append(tree.append(FileNode(
                name: "f\(index)", size: Bytes(100), category: .other, files: 1, parent: .root, children: []
            )))
        }
        tree[.root].children = children

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
        var tree = FileTree(rootPath: "/r", root: FileNode(name: "r", size: .zero, category: .folder, files: 0, parent: nil, children: []))
        let node = tree.append(FileNode(name: "x", size: .zero, category: .other, files: 1, parent: .root, children: []))
        let storage = StorageModel()
        #expect(throws: StorageModel.ActionError.self) {
            try storage.trash(node, path: "/r/x", generation: storage.generation)
        }
    }
}
