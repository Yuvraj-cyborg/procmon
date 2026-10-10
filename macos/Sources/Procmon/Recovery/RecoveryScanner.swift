// One recovery scan from start to finish: deleted files with their names
// from the directories first, since that is quick, then the whole disk by
// content, which finds what the directories no longer list.

import Foundation
import Synchronization

final class RecoveryScanner: Sendable {
    let source: ByteSource
    let progress = RecoveryProgress()
    private let pending = Mutex<[FoundFile]>([])
    private let lastID = Atomic<Int>(0)
    /// What the directory pass learned, for the page to describe the disk.
    private let volumes = Mutex<[String]>([])

    init(source: ByteSource) {
        self.source = source
    }

    /// Runs the scan on the calling thread. Ends early, without an error,
    /// when cancelled; throws only when the disk goes away.
    func run() throws(ReadError) {
        progress.begin(.directories, total: source.size)
        let reader = Reader(source)
        var allocated: [Range<UInt64>] = []
        var named: Set<UInt64> = []
        for partition in PartitionTable.partitions(reader, sectorSize: UInt64(source.blockSize)) {
            guard !progress.isCancelled,
                  let scan = DirectoryScanner.scan(source, partition: partition, cancelled: { progress.isCancelled })
            else { continue }
            volumes.withLock { $0.append(scan.format) }
            allocated += scan.allocated
            for var file in scan.files {
                Self.identify(&file, reader: reader)
                file = FoundFile(
                    id: nextID(), format: file.format, kind: file.kind, extents: file.extents, name: file.name,
                    folder: file.folder, date: file.date, condition: file.condition, details: file.details, origin: file.origin
                )
                named.insert(file.offset)
                publish(file)
            }
        }
        guard !progress.isCancelled else { return }

        progress.begin(.contents)
        allocated.sort { $0.lowerBound < $1.lowerBound }
        try Carver.scan(source, skipping: allocated, progress: progress) { carved, offset in
            // Listed already, with its name.
            guard !named.contains(offset) else { return }
            publish(FoundFile(
                id: nextID(), format: carved.format, kind: carved.format.kind,
                extents: [Extent(offset: offset, length: carved.length)], date: carved.date,
                condition: carved.condition, details: carved.details, origin: .contents
            ))
        }
        if !progress.isCancelled {
            progress.begin(.finished)
        }
    }

    /// Files found since the last call, for the page to show.
    func collect() -> [FoundFile] {
        pending.withLock { files in
            defer { files = [] }
            return files
        }
    }

    /// File systems the directory pass read, e.g. `["FAT32"]`.
    var fileSystems: [String] { volumes.withLock { $0 } }

    private func publish(_ file: FoundFile) {
        pending.withLock { $0.append(file) }
    }

    private func nextID() -> Int {
        lastID.add(1, ordering: .relaxed).newValue
    }

    /// Checks a directory entry against its contents: the format they hold,
    /// what they say about themselves, and whether they are still there.
    static func identify(_ file: inout FoundFile, reader: Reader) {
        guard let first = file.extents.first, let head = reader.bytes(at: first.offset, count: 32) else { return }
        let expected = RecoveredFormat.allCases.first { $0.extensions.contains(file.fileExtension.lowercased()) }
        guard let parse = head.withUnsafeBytes({ Carver.parser(for: $0) }) else {
            // Named like a photo or video, but holding something else: its
            // clusters were reused after it was deleted.
            if expected != nil, file.condition == .good {
                file.condition = .overwritten
            }
            return
        }
        file.format = expected
        // Parsers read the disk straight through, so only a file in one piece can be measured.
        guard file.extents.count == 1 else { return }
        guard let carved = parse(reader, first.offset) else {
            if file.condition == .good { file.condition = .damaged }
            return
        }
        file.format = carved.format
        file.kind = carved.format.kind
        file.details = carved.details
        file.date = file.date ?? carved.date
        if carved.condition == .damaged, file.condition == .good {
            file.condition = .damaged
        }
    }
}
