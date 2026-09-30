import CoreGraphics
import Foundation
import Testing
@testable import Procmon

@Suite struct TreemapTests {
    private let epsilon: CGFloat = 1e-3

    private func within(_ rect: CGRect, _ bounds: CGRect) -> Bool {
        rect.minX >= bounds.minX - epsilon && rect.minY >= bounds.minY - epsilon
            && rect.maxX <= bounds.maxX + epsilon && rect.maxY <= bounds.maxY + epsilon
    }

    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX + epsilon < b.maxX && b.minX + epsilon < a.maxX && a.minY + epsilon < b.maxY && b.minY + epsilon < a.maxY
    }

    @Test func areasAreProportionalAndFillBounds() {
        let weights = [6.0, 6, 4, 3, 2, 2, 1]
        let bounds = CGRect(x: 0, y: 0, width: 6, height: 4)
        let rects = Treemap.squarify(weights, in: bounds)
        let total = weights.reduce(0, +)
        for (weight, rect) in zip(weights, rects) {
            let expected = weight / total * 24
            #expect(abs(Double(rect.width * rect.height) - expected) < 1e-2)
            #expect(within(rect, bounds))
        }
        let covered = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(covered - 24) < 1e-2)
    }

    @Test func rectanglesDoNotOverlap() {
        let weights = (1...40).reversed().map(Double.init)
        let rects = Treemap.squarify(weights, in: CGRect(x: 10, y: 20, width: 800, height: 300))
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                #expect(!overlaps(a, b), "\(a) overlaps \(b)")
            }
        }
    }

    @Test func classicPaperExampleIsReasonablySquare() {
        let rects = Treemap.squarify([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 6, height: 4))
        for rect in rects {
            #expect(max(rect.width / rect.height, rect.height / rect.width) < 3)
        }
    }

    @Test func degenerateInputsAreEmpty() {
        #expect(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 1, height: 1)).isEmpty)
        let rects = Treemap.squarify([0, 5], in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(rects[0].width * rects[0].height == 0)
        #expect(abs(rects[1].width * rects[1].height - 1) < epsilon)
        #expect(Treemap.squarify([1], in: CGRect(x: 0, y: 0, width: 0, height: 5))[0].width == 0)
    }
}

@Suite struct FileTreeTests {
    private func node(_ name: String, _ size: UInt64, _ category: FileCategory, _ parent: NodeID?, files: UInt64? = nil) -> FileNode {
        FileNode(name: name, size: Bytes(size), category: category, files: files ?? (category == .folder ? 0 : 1), parent: parent, children: [])
    }

    /// root (1000) ─ a/ (900) ─ big.mov (600), small.txt (300)
    ///             └ c.zip (100)
    private func sample() -> (FileTree, a: NodeID, c: NodeID, big: NodeID, small: NodeID) {
        var tree = FileTree(rootPath: "/r", root: node("r", 1000, .folder, nil, files: 3))
        let a = tree.append(node("a", 900, .folder, .root, files: 2))
        let c = tree.append(node("c.zip", 100, .archive, .root))
        let big = tree.append(node("big.mov", 600, .video, a))
        let small = tree.append(node("small.txt", 300, .document, a))
        tree[.root].children = [a, c]
        tree[a].children = [big, small]
        return (tree, a, c, big, small)
    }

    @Test func largestFilesSkipsFolders() {
        let (tree, _, c, big, small) = sample()
        #expect(tree.largestFiles(limit: 10) == [big, small, c])
        #expect(tree.largestFiles(limit: 1) == [big])
    }

    @Test func removeUpdatesAncestorsAndResorts() {
        var (tree, a, c, big, _) = sample()
        tree.remove(big)
        #expect(tree[a].size == Bytes(300))
        #expect(tree[a].files == 1)
        #expect(tree[.root].size == Bytes(400))
        #expect(tree[.root].files == 2)
        #expect(!tree.largestFiles(limit: 10).contains(big))

        tree.remove(a)
        #expect(tree[.root].children == [c])
        #expect(tree[.root].size == Bytes(100))
    }

    @Test func pathsFollowLineage() {
        let (tree, a, _, big, _) = sample()
        #expect(tree.path(of: big) == "/r/a/big.mov")
        #expect(tree.lineage(big) == [.root, a, big])
        #expect(tree.title(of: .root) == "r")
    }

    @Test func classifiesCommonTypes() {
        #expect(FileCategory.classify(name: "Safari.app", isDirectory: true) == .application)
        #expect(FileCategory.classify(name: "src", isDirectory: true) == .folder)
        #expect(FileCategory.classify(name: "IMG_0001.HEIC", isDirectory: false) == .image)
        #expect(FileCategory.classify(name: "backup.tar.gz", isDirectory: false) == .archive)
        #expect(FileCategory.classify(name: "Makefile", isDirectory: false) == .other)
    }
}

@Suite struct ScannerTests {
    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("procmon-scan-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sizesRollUpAndChildrenAreSorted() throws {
        let root = try temporaryDirectory("rollup")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("big"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 256 * 1024).write(to: root.appendingPathComponent("big/blob.bin"))
        try Data("hi".utf8).write(to: root.appendingPathComponent("small.txt"))

        let tree = try Scanner.scan(root: root.path, progress: ScanProgress())
        let top = tree[.root]
        #expect(top.files == 2)
        let first = tree[top.children[0]]
        #expect(first.name == "big")
        #expect(first.size >= Bytes(256 * 1024))
        #expect(top.size >= top.children.map { tree[$0].size }.sum())
        #expect(tree.path(of: first.children[0]) == root.appendingPathComponent("big/blob.bin").path)
    }

    @Test func hardLinksCountOnceAndSymlinksAreSkipped() throws {
        let root = try temporaryDirectory("links")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("a.bin")
        try Data(repeating: 1, count: 64 * 1024).write(to: original)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("b.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("c.bin"), withDestinationURL: original)

        let tree = try Scanner.scan(root: root.path, progress: ScanProgress())
        #expect(tree[.root].files == 1)
    }

    @Test func longTailOfFilesIsFolded() throws {
        let root = try temporaryDirectory("fold")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<(Scanner.filesPerFolder + 10) {
            try Data(repeating: 0, count: 4096 + index).write(to: root.appendingPathComponent("f\(index)"))
        }
        let tree = try Scanner.scan(root: root.path, progress: ScanProgress())
        let top = tree[.root]
        #expect(top.children.count == Scanner.filesPerFolder + 1)
        #expect(top.files == UInt64(Scanner.filesPerFolder + 10))
        let remainder = try #require(top.children.first { tree[$0].category == .remainder })
        #expect(tree[remainder].files == 10)
        #expect(tree.path(of: remainder) == nil)
    }

    @Test func deepTreesAreScannedInParallel() throws {
        let root = try temporaryDirectory("deep")
        defer { try? FileManager.default.removeItem(at: root) }
        for branch in 0..<8 {
            var path = root.appendingPathComponent("b\(branch)")
            for depth in 0..<6 {
                path = path.appendingPathComponent("d\(depth)")
            }
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(repeating: 2, count: 8192).write(to: path.appendingPathComponent("leaf"))
        }
        let tree = try Scanner.scan(root: root.path, progress: ScanProgress())
        #expect(tree[.root].files == 8)
        #expect(tree[.root].children.count == 8)
    }

    @Test func cancelledScanReportsCancellation() throws {
        let root = try temporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let progress = ScanProgress()
        progress.cancel()
        #expect(throws: ScanError.cancelled) { try Scanner.scan(root: root.path, progress: progress) }
    }

    @Test func missingRootIsAnError() {
        #expect(throws: ScanError.self) { try Scanner.scan(root: "/definitely/not/here", progress: ScanProgress()) }
    }

    /// `SCAN_ROOT=$HOME swift test -c release --filter scanLive`
    @Test(.enabled(if: Foundation.ProcessInfo.processInfo.environment["SCAN_ROOT"] != nil))
    func scanLive() throws {
        let root = Foundation.ProcessInfo.processInfo.environment["SCAN_ROOT"]!
        let clock = ContinuousClock()
        let started = clock.now
        let tree = try Scanner.scan(root: root, progress: ScanProgress())
        print("\(tree[.root].files) files, \(tree[.root].size.decimal) on disk, \(tree.count) nodes, \(tree.unreadable) unreadable, in \(clock.now - started)")
    }
}

@Suite struct DeviceParsingTests {
    @Test func parsesKmutilRows() {
        let text = """
                3  228 0                  0          0          com.apple.kpi.bsd (25.6.0) B445A6D8 <>
            121    0 0xfffffe0007 0x4000 0x4000 com.example.driver (1.2.3) ABCD <3 5>

            """
        let drivers = DeviceInventory.parseKmutil(text)
        #expect(drivers.count == 2)
        #expect(drivers[0].bundleID == "com.apple.kpi.bsd")
        #expect(drivers[0].references == 228)
        #expect(drivers[1].version == "1.2.3")
        #expect(drivers[1].isThirdParty)
    }

    @Test func parsesSystemExtensionStates() {
        let text = "2 extension(s)\n"
            + "--- com.apple.system_extension.cmio (Go to 'System Settings')\n"
            + "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n"
            + "\t*\t2MMRE5MTB8\tcom.obsproject.obs-studio.mac-camera-extension (31.1.2/165)\tOBS Virtual Camera\t[activated waiting for user]\n"
            + "--- com.apple.system_extension.driver_extension\n"
            + "*\t*\tABCDE12345\tcom.vendor.usbdriver (2.0)\tVendor USB\t[activated enabled]\n"
        let drivers = DeviceInventory.parseSystemExtensions(text)
        #expect(drivers.count == 2)
        #expect(drivers[0].state == .awaitingApproval)
        #expect(drivers[0].displayName == "OBS Virtual Camera")
        #expect(drivers[0].version == "31.1.2/165")
        #expect(drivers[1].kind == .driverKit)
        #expect(drivers[1].state.isHealthy)
    }

    @Test func parsesProfilerSections() throws {
        let json = """
            {
              "SPUSBHostDataType": [{"_name": "USB 3.1 Bus", "_items": [
                {"_name": "Keyboard", "USBDeviceKeyVendorName": "Keychron", "Driver": "AppleUSBHostHIDDevice",
                 "_items": [{"_name": "Hub child"}]}
              ]}],
              "SPBluetoothDataType": [{
                "device_connected": [{"AirPods": {"device_minorType": "Headphones", "device_batteryLevelMain": "80%"}}],
                "device_not_connected": [{"Mouse": {"device_minorType": "Mouse"}}]
              }],
              "SPDisplaysDataType": [{"_name": "Apple M4", "sppci_cores": "10",
                "spdisplays_ndrvs": [{"_name": "Color LCD", "spdisplays_online": "spdisplays_no"}]}],
              "SPStorageDataType": [
                {"physical_drive": {"device_name": "SSD", "protocol": "Apple Fabric", "smart_status": "Verified", "is_internal_disk": "yes"}},
                {"physical_drive": {"device_name": "SSD", "protocol": "Apple Fabric"}},
                {"physical_drive": {"device_name": "Disk Image", "protocol": "Disk Image"}},
                {"physical_drive": {"device_name": "Old HDD", "protocol": "USB", "smart_status": "Failing"}}
              ]
            }
            """
        let report = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let devices = DeviceInventory.parseProfiler(report)
        func find(_ name: String) -> Device? { devices.first { $0.name == name } }

        #expect(find("Keyboard")?.driver == "AppleUSBHostHIDDevice")
        #expect(find("Hub child")?.deviceClass == .usb)
        #expect(find("USB 3.1 Bus") == nil)
        #expect(find("AirPods")?.facts == ["Headphones", "Battery 80%"])
        #expect(find("Mouse")?.status == .available)
        #expect(find("Color LCD")?.status == .faulty)
        #expect(devices.count { $0.name == "SSD" } == 1)
        #expect(find("Disk Image") == nil)
        #expect(find("Old HDD")?.status == .faulty)
    }
}
