// State of the Storage page: the volume list, a running scan, and navigation
// through a finished one.

import Dispatch
import Foundation
import Observation

/// Runs blocking work on a global queue instead of Swift's cooperative pool.
func offMain<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            continuation.resume(returning: work())
        }
    }
}

@MainActor
@Observable
final class StorageModel {
    /// How many files the "Largest files" view lists.
    nonisolated static let largestLimit = 100

    enum Phase {
        case idle
        case scanning(root: String, progress: ScanProgress)
        case failed(root: String, message: String)
        case ready
    }

    enum Mode: String, CaseIterable, Identifiable {
        case map, largest

        var id: Self { self }
        var label: String { self == .map ? "Map" : "Largest files" }
    }

    /// Why a Storage action could not run.
    enum ActionError: LocalizedError {
        /// The scan changed (or finished again) while the question was open.
        case scanChanged

        var errorDescription: String? { "the scan changed, so nothing was moved. Try again." }
    }

    struct Browser {
        /// Which scan this browser shows; see ``StorageModel/generation``.
        let generation: Int
        var tree: FileTree
        /// Folder shown in the map.
        var current: NodeID = .root
        /// File or folder the footer actions apply to.
        var selected: NodeID?
        var mode: Mode = .map
        var largest: [NodeID]
        /// Bumped whenever the tree changes shape, so layouts can be cached.
        var revision = 0

        /// What the actions act on: the selection, else the open folder.
        var target: NodeID { selected ?? current }
    }

    private(set) var volumes: [Volume] = Volume.all()
    private(set) var phase: Phase = .idle
    /// Bumped by every scan, so node ids from an older tree are never used
    /// against a newer one.
    private(set) var generation = 0
    var browser: Browser?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var isScanning: Bool {
        if case .scanning = phase { true } else { false }
    }

    func scan(_ path: String) {
        // Scanning `/` would stop at the sealed system volume; user files live
        // on the Data volume (see ``Volume``).
        let dataVolume = "/System/Volumes/Data"
        let root = path == "/" && FileManager.default.fileExists(atPath: dataVolume) ? dataVolume : path
        cancel()
        let progress = ScanProgress()
        generation += 1
        let generation = generation
        phase = .scanning(root: root, progress: progress)
        browser = nil
        scanTask = Task {
            let result = await offMain {
                Result { () throws(ScanError) -> (FileTree, [NodeID]) in
                    // Without Full Disk Access, macOS would stop the scan to ask
                    // about each protected folder; leave those out instead.
                    let excluded = Permissions.hasFullDiskAccess ? [] : Permissions.promptingFolders()
                    let tree = try Scanner.scan(root: root, progress: progress, excluding: excluded)
                    return (tree, tree.largestFiles(limit: Self.largestLimit))
                }
            }
            // A newer scan may have replaced this one while it ran.
            guard case .scanning(_, let active) = phase, active === progress else { return }
            switch result {
            case .success(let (tree, largest)):
                browser = Browser(generation: generation, tree: tree, largest: largest)
                phase = .ready
            case .failure(.cancelled):
                phase = .idle
            case .failure(let error):
                phase = .failed(root: root, message: error.description)
            }
            refreshVolumes()
        }
    }

    /// Scans the last root again, if there is one.
    func rescan() {
        switch phase {
        case .ready: if let root = browser?.tree.rootPath { scan(root) }
        case .failed(let root, _): scan(root)
        case .idle, .scanning: break
        }
    }

    func cancel() {
        if case .scanning(_, let progress) = phase {
            progress.cancel()
            phase = .idle
        }
    }

    func refreshVolumes() {
        volumes = Volume.all()
    }

    // MARK: Browsing

    /// Shows `node` in the map: folders are opened, files are selected in
    /// their folder.
    func focus(_ node: NodeID) {
        guard var browser else { return }
        let target = browser.tree[node]
        if target.isContainer {
            browser.current = node
            browser.selected = nil
        } else {
            browser.current = target.parent ?? .root
            browser.selected = node
        }
        browser.mode = .map
        self.browser = browser
    }

    func select(_ node: NodeID?) {
        browser?.selected = node
    }

    func goUp() {
        guard let parent = browser.flatMap({ $0.tree[$0.current].parent }) else { return }
        focus(parent)
    }

    func setMode(_ mode: Mode) {
        browser?.mode = mode
    }

    /// Moves `node` to the Trash and drops it from the tree. `path` and
    /// `generation` are what the user confirmed; if the scan has changed
    /// since, nothing is moved.
    func trash(_ node: NodeID, path: String, generation: Int) throws {
        guard var browser, browser.generation == generation, node != .root, browser.tree.path(of: node) == path else {
            throw ActionError.scanChanged
        }
        try Finder.moveToTrash(path)
        // Release the stored copy first so the tree is edited in place.
        self.browser = nil
        let lineage = browser.tree.lineage(browser.current)
        if lineage.contains(node) {
            browser.current = browser.tree[node].parent ?? .root
        }
        if browser.selected.map({ browser.tree.lineage($0).contains(node) }) ?? false {
            browser.selected = nil
        }
        browser.tree.remove(node)
        browser.largest = browser.tree.largestFiles(limit: Self.largestLimit)
        browser.revision += 1
        self.browser = browser
        refreshVolumes()
    }
}

@MainActor
@Observable
final class DevicesModel {
    private(set) var inventory: Inventory?
    private(set) var isLoading = false

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            inventory = await offMain(qos: .utility) { DeviceInventory.collect() }
            isLoading = false
        }
    }
}
