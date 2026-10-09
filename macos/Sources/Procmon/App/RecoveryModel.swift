// State of the Recovery page: which disk is being read, what has been found
// so far, which of it is chosen, and saving the chosen files elsewhere.

import AppKit
import DiskArbitration
import Foundation
import Observation

@MainActor
@Observable
final class RecoveryModel {
    enum Phase: Equatable {
        case choosing
        /// Waiting for the disk to open, and for the password if one is needed.
        case opening
        case scanning
        case finished
        case failed(String)
    }

    enum Sort: String, CaseIterable, Identifiable {
        case found, name, size, date

        var id: Self { self }

        var label: String {
            switch self {
            case .found: "Disk order"
            case .name: "Name"
            case .size: "Size"
            case .date: "Date"
            }
        }
    }

    /// Smaller files are mostly icons and thumbnail caches.
    nonisolated static let smallFile = Bytes(16 * 1024)

    private(set) var disks: [RecoveryDisk] = []
    private(set) var phase: Phase = .choosing
    /// What is being read, e.g. "SanDisk Ultra" or an image's file name.
    private(set) var sourceName = ""
    /// The physical disk being read, so recovered files are never saved onto it.
    private(set) var sourceDisk: String?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var files: [FoundFile] = []
    /// ``files`` after the filters, in the chosen order.
    private(set) var visible: [FoundFile] = []
    private(set) var counts: [RecoveredKind: Int] = [:]
    var kind: RecoveredKind? { didSet { arrange() } }
    var sort = Sort.found { didSet { arrange() } }
    var hideSmall = true { didSet { arrange() } }
    var selection: Set<Int> = []
    /// Set while chosen files are being saved.
    private(set) var saving: ExportProgress?
    private(set) var savingTotal = Bytes.zero

    @ObservationIgnored private(set) var scanner: RecoveryScanner?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored let thumbnails = ThumbnailCache()
    @ObservationIgnored private var session: DASession?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    var progress: RecoveryProgress? { scanner?.progress }
    var isBusy: Bool { phase == .opening || phase == .scanning }

    var selected: [FoundFile] { files.filter { selection.contains($0.id) } }

    func refreshDisks() {
        Task {
            disks = await offMain(qos: .utility) { RecoverySources.disks() }
        }
    }

    /// Keeps ``disks`` current as cards and drives come and go. A damaged
    /// card often cannot be mounted, so this listens for disks, not volumes.
    func watchDisks() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        let changed: DADiskAppearedCallback = { _, context in
            guard let context else { return }
            let model = Unmanaged<RecoveryModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.disksChanged() }
        }
        DARegisterDiskAppearedCallback(session, nil, changed, context)
        DARegisterDiskDisappearedCallback(session, nil, changed, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        refreshDisks()
    }

    /// A card brings its partitions with it: one refresh for the lot.
    private func disksChanged() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            refreshDisks()
        }
    }

    // MARK: Scanning

    func scan(_ disk: RecoveryDisk) {
        let prompt = "Procmon wants to read “\(disk.name)” block by block to find deleted files. It only reads: nothing on the disk is changed."
        let path = disk.devicePath
        start(name: disk.name, disk: disk.bsdName) { () throws -> RawDevice in
            try DiskAccess.open(path, prompt: prompt)
        }
    }

    /// A disk image or a copy of a card made with `dd`.
    func scanImage(_ url: URL) {
        let path = url.path
        start(name: url.lastPathComponent, disk: nil) { () throws -> RawDevice in
            try RawDevice(path: path)
        }
    }

    private func start(name: String, disk: String?, open: @escaping @Sendable () throws -> RawDevice) {
        stop()
        files = []
        visible = []
        counts = [:]
        selection = []
        thumbnails.removeAll()
        sourceName = name
        sourceDisk = disk
        startedAt = nil
        finishedAt = nil
        phase = .opening
        task = Task {
            let opened = await offMain(qos: .userInitiated) { Result { try open() } }
            guard !Task.isCancelled else { return }
            let device: RawDevice
            switch opened {
            case .success(let opened):
                device = opened
            case .failure(let error):
                phase = (error as? DiskAccessError) == .cancelled ? .choosing : .failed(String(describing: error))
                return
            }
            let scanner = RecoveryScanner(source: device)
            self.scanner = scanner
            startedAt = .now
            phase = .scanning
            // Results arrive in batches, so the grid grows a few times a second.
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self, self.scanner === scanner, !Task.isCancelled else { break }
                    self.absorb(scanner.collect())
                }
            }
            let failure = await offMain(qos: .userInitiated) { () -> ReadError? in
                do throws(ReadError) {
                    try scanner.run()
                    return nil
                } catch {
                    return error
                }
            }
            poller.cancel()
            // Reset while it ran: the page has moved on.
            guard !Task.isCancelled, self.scanner === scanner else { return }
            absorb(scanner.collect())
            finishedAt = .now
            if let failure {
                phase = files.isEmpty ? .failed(failure.description) : .finished
            } else {
                phase = .finished
            }
        }
    }

    /// Stops the scan; what was found so far stays.
    func stop() {
        scanner?.progress.cancel()
    }

    /// Back to the list of disks.
    func reset() {
        stop()
        task?.cancel()
        scanner = nil
        files = []
        visible = []
        counts = [:]
        selection = []
        thumbnails.removeAll()
        phase = .choosing
        refreshDisks()
    }

    private func absorb(_ found: [FoundFile]) {
        guard !found.isEmpty else { return }
        files += found
        for file in found {
            counts[file.kind, default: 0] += 1
        }
        arrange()
    }

    /// Adds what a preview learned (EXIF date, size) to a found file.
    func learn(_ facts: PreviewFacts, about id: Int) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        var file = files[index]
        if file.details.pixelWidth == nil, let width = facts.pixelWidth, let height = facts.pixelHeight {
            file.details.pixelWidth = width
            file.details.pixelHeight = height
        }
        if file.date == nil { file.date = facts.date }
        guard file != files[index] else { return }
        files[index] = file
        if let position = visible.firstIndex(where: { $0.id == id }) {
            visible[position] = file
        }
    }

    private func arrange() {
        var shown = files.filter { file in
            (kind == nil || file.kind == kind) && (!hideSmall || file.size >= Self.smallFile || file.origin == .directory)
        }
        switch sort {
        case .found: shown.sort { $0.offset < $1.offset }
        case .name: shown.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .size: shown.sort { $0.size > $1.size }
        case .date: shown.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        visible = shown
    }

    func selectAllVisible() {
        selection.formUnion(visible.map(\.id))
    }

    // MARK: Saving

    /// Why `folder` is a bad place to save, if it is one.
    func problem(savingTo folder: URL) -> String? {
        guard let sourceDisk, let target = RecoverySources.physicalDisk(holding: folder.path), target == sourceDisk else { return nil }
        return "That folder is on “\(sourceName)”, the disk being recovered. Saving there can overwrite the very files you want back. Choose a folder on another disk."
    }

    func save(_ chosen: [FoundFile], to folder: URL, report: @escaping (String, Toast.Kind) -> Void) {
        guard let scanner, saving == nil, !chosen.isEmpty else { return }
        let source = scanner.source
        let progress = ExportProgress()
        let name = sourceName
        saving = progress
        savingTotal = chosen.map(\.size).sum()
        Task {
            let result = await offMain(qos: .userInitiated) {
                Result { try Exporter.export(chosen, from: source, sourceName: name, to: folder, progress: progress) }
            }
            saving = nil
            switch result {
            case .success(let saved):
                var message = "Saved \(Format.count(saved.saved, "file")) to “\(saved.folder.lastPathComponent)”."
                if saved.unreadable > .zero { message += " \(saved.unreadable.decimal) couldn't be read and was left blank." }
                if !saved.failures.isEmpty { message += " \(saved.failures.count) failed." }
                report(message, saved.failures.isEmpty ? .success : .failure)
                NSWorkspace.shared.activateFileViewerSelecting([saved.folder])
            case .failure(let error):
                report("Couldn't save: \(error.localizedDescription)", .failure)
            }
        }
    }
}
