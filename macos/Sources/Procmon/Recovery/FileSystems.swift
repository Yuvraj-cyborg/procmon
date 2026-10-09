// Deleted files with their names, from FAT and exFAT: the file systems on
// almost every memory card, camera and USB stick.
//
// Deleting a file there only marks its directory entry as free and releases
// its clusters. Until something new is written over them, the entry still
// holds the name, size, date and first cluster, and the clusters still hold
// the data. Live files are reported too, as ranges the content scan can skip.

import Foundation

/// A partition, or the whole disk when it has no partition table.
struct Partition: Equatable, Sendable {
    let offset: UInt64
    let length: UInt64
}

enum PartitionTable {
    /// Partitions from an MBR or GPT; the whole disk when there is neither,
    /// as on cards formatted without one.
    static func partitions(_ reader: Reader, sectorSize: UInt64 = 512) -> [Partition] {
        let whole = [Partition(offset: 0, length: reader.size)]
        guard reader.u16le(510) == 0xAA55 else { return whole }
        if isBootSector(reader, at: 0) { return whole }
        var partitions: [Partition] = []
        for index in 0..<4 {
            let entry = 446 + UInt64(index) * 16
            guard let type = reader.byte(at: entry + 4), type != 0,
                  let first = reader.u32le(entry + 8), let count = reader.u32le(entry + 12), count > 0
            else { continue }
            if type == 0xEE {
                return gpt(reader, sectorSize: sectorSize) ?? whole
            }
            if type == 0x05 || type == 0x0F { continue }
            let offset = UInt64(first) * sectorSize
            guard offset < reader.size else { continue }
            partitions.append(Partition(offset: offset, length: min(UInt64(count) * sectorSize, reader.size - offset)))
        }
        return partitions.isEmpty ? whole : partitions
    }

    private static func gpt(_ reader: Reader, sectorSize: UInt64) -> [Partition]? {
        guard reader.ascii("EFI PART", at: sectorSize),
              let table = reader.u64le(sectorSize + 72), let count = reader.u32le(sectorSize + 80),
              let entrySize = reader.u32le(sectorSize + 84), entrySize >= 128, count <= 1024
        else { return nil }
        var partitions: [Partition] = []
        for index in 0..<UInt64(count) {
            let entry = table * sectorSize + index * UInt64(entrySize)
            guard let type = reader.bytes(at: entry, count: 16), type.contains(where: { $0 != 0 }),
                  let first = reader.u64le(entry + 32), let last = reader.u64le(entry + 40), last >= first
            else { continue }
            let offset = first * sectorSize
            guard offset < reader.size else { continue }
            partitions.append(Partition(offset: offset, length: min((last - first + 1) * sectorSize, reader.size - offset)))
        }
        return partitions
    }

    /// A FAT or exFAT boot sector, rather than a partition table.
    static func isBootSector(_ reader: Reader, at offset: UInt64) -> Bool {
        reader.ascii("EXFAT   ", at: offset + 3) || FATVolume(reader, at: offset) != nil
    }
}

/// What the directory pass learned about one volume.
struct DirectoryScan: Sendable {
    /// Deleted files, by their old names. `id` is assigned later.
    var files: [FoundFile] = []
    /// Byte ranges on the disk that live files occupy.
    var allocated: [Range<UInt64>] = []
    var volumeName: String?
    var format = ""
}

// MARK: - FAT12, FAT16, FAT32

struct FATVolume {
    enum Kind { case fat12, fat16, fat32 }

    let kind: Kind
    let clusterSize: UInt64
    /// Disk offsets of the first FAT, the FAT12/16 root folder and cluster 2.
    let fatOffset: UInt64
    let rootOffset: UInt64
    let rootEntries: UInt64
    let rootCluster: UInt32
    let dataOffset: UInt64
    let clusterCount: UInt32
    let end: UInt64

    init?(_ reader: Reader, at start: UInt64) {
        guard let jump = reader.byte(at: start), jump == 0xEB || jump == 0xE9,
              let sectorSize = reader.u16le(start + 11), [512, 1024, 2048, 4096].contains(sectorSize),
              let perCluster = reader.byte(at: start + 13), perCluster > 0, perCluster & (perCluster - 1) == 0,
              let reserved = reader.u16le(start + 14), reserved > 0,
              let fats = reader.byte(at: start + 16), (1...2).contains(fats),
              let rootEntries = reader.u16le(start + 17), let small = reader.u16le(start + 19),
              let fatSmall = reader.u16le(start + 22), let large = reader.u32le(start + 32), let fatLarge = reader.u32le(start + 36),
              let rootCluster = reader.u32le(start + 44), reader.u16le(start + 510) == 0xAA55
        else { return nil }
        let sector = UInt64(sectorSize)
        let total = small != 0 ? UInt64(small) : UInt64(large)
        let fatSectors = fatSmall != 0 ? UInt64(fatSmall) : UInt64(fatLarge)
        let rootSectors = (UInt64(rootEntries) * 32 + sector - 1) / sector
        let firstData = UInt64(reserved) + UInt64(fats) * fatSectors + rootSectors
        guard total > firstData, fatSectors > 0 else { return nil }
        let clusters = (total - firstData) / UInt64(perCluster)
        kind = clusters < 4085 ? .fat12 : clusters < 65525 ? .fat16 : .fat32
        guard kind != .fat32 || (fatSmall == 0 && rootEntries == 0) else { return nil }
        clusterSize = sector * UInt64(perCluster)
        fatOffset = start + UInt64(reserved) * sector
        rootOffset = fatOffset + UInt64(fats) * fatSectors * sector
        self.rootEntries = UInt64(rootEntries)
        self.rootCluster = rootCluster
        dataOffset = start + firstData * sector
        clusterCount = UInt32(min(clusters, UInt64(UInt32.max - 16)))
        end = start + total * sector
        guard end <= reader.size + sector else { return nil }
    }

    var formatName: String {
        switch kind {
        case .fat12: "FAT12"
        case .fat16: "FAT16"
        case .fat32: "FAT32"
        }
    }

    func isCluster(_ cluster: UInt32) -> Bool { cluster >= 2 && cluster < clusterCount + 2 }

    func offset(of cluster: UInt32) -> UInt64 { dataOffset + UInt64(cluster - 2) * clusterSize }

    /// The FAT entry for `cluster`: 0 free, a cluster number, or end of chain.
    func entry(_ cluster: UInt32, _ reader: Reader) -> UInt32? {
        switch kind {
        case .fat32: reader.u32le(fatOffset + UInt64(cluster) * 4).map { $0 & 0x0FFF_FFFF }
        case .fat16: reader.u16le(fatOffset + UInt64(cluster) * 2).map(UInt32.init)
        case .fat12:
            reader.u16le(fatOffset + UInt64(cluster) + UInt64(cluster / 2)).map { cluster & 1 == 1 ? UInt32($0 >> 4) : UInt32($0 & 0xFFF) }
        }
    }

    /// Every cluster in use, as merged byte ranges on the disk.
    func allocated(_ source: ByteSource) -> [Range<UInt64>] {
        let width: UInt64 = kind == .fat32 ? 4 : kind == .fat16 ? 2 : 0
        var ranges: [Range<UInt64>] = []
        func mark(_ cluster: UInt32) {
            let start = offset(of: cluster)
            if let last = ranges.last, last.upperBound == start {
                ranges[ranges.count - 1] = last.lowerBound..<(start + clusterSize)
            } else {
                ranges.append(start..<(start + clusterSize))
            }
        }
        if width == 0 {
            let reader = Reader(source)
            for cluster in 2..<(clusterCount + 2) where (entry(cluster, reader) ?? 0) != 0 {
                mark(cluster)
            }
            return ranges
        }
        // Read the table in large pieces: a 64 GB card has millions of entries.
        let chunk = 1 << 20
        var cluster: UInt32 = 0
        let last = clusterCount + 2
        while cluster < last {
            guard let bytes = source.bytes(at: fatOffset + UInt64(cluster) * width, count: chunk) else { break }
            let entries = bytes.count / Int(width)
            guard entries > 0 else { break }
            bytes.withUnsafeBytes { raw in
                for index in 0..<entries where cluster + UInt32(index) < last {
                    let value: UInt32 = width == 4
                        ? raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian & 0x0FFF_FFFF
                        : UInt32(raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self).littleEndian)
                    if value != 0, cluster + UInt32(index) >= 2 {
                        mark(cluster + UInt32(index))
                    }
                }
            }
            cluster += UInt32(entries)
        }
        return ranges
    }
}

/// FAT dates are local time, packed into 16 bits each.
func fatDate(date: UInt16, time: UInt16) -> Date? {
    var parts = DateComponents()
    parts.year = 1980 + Int(date >> 9)
    parts.month = Int(date >> 5 & 0x0F)
    parts.day = Int(date & 0x1F)
    parts.hour = Int(time >> 11)
    parts.minute = Int(time >> 5 & 0x3F)
    parts.second = Int(time & 0x1F) * 2
    guard (1...12).contains(parts.month ?? 0), (1...31).contains(parts.day ?? 0) else { return nil }
    return Calendar(identifier: .gregorian).date(from: parts)
}

enum DirectoryScanner {
    /// Folders macOS and other systems fill with their own bookkeeping.
    static let skippedFolders: Set<String> = [".Spotlight-V100", ".fseventsd", ".TemporaryItems", "System Volume Information"]

    /// Copies macOS leaves next to each file, and other metadata nobody misses.
    static func isNoise(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini"
    }

    /// Reads a FAT or exFAT volume at `offset`, if there is one.
    static func scan(_ source: ByteSource, partition: Partition, cancelled: () -> Bool) -> DirectoryScan? {
        let reader = Reader(source)
        if let volume = ExFATVolume(reader, at: partition.offset) {
            return volume.scan(source, reader: reader, cancelled: cancelled)
        }
        if let volume = FATVolume(reader, at: partition.offset) {
            return scanFAT(volume, source: source, reader: reader, cancelled: cancelled)
        }
        return nil
    }

    // MARK: FAT

    private struct Pending {
        let cluster: UInt32
        let path: String
        let deleted: Bool
        let depth: Int
    }

    private static func scanFAT(_ volume: FATVolume, source: ByteSource, reader: Reader, cancelled: () -> Bool) -> DirectoryScan {
        var result = DirectoryScan(format: volume.formatName)
        let allocated = volume.allocated(source)
        result.allocated = allocated
        var visited: Set<UInt32> = []
        var queue: [Pending] = []
        var entriesRead = 0

        func visit(_ entries: [UInt8], path: String, deleted parentDeleted: Bool, depth: Int) {
            // Short entries with the long name entries stored before each.
            var records: [(entry: [UInt8], longName: [(order: UInt8, checksum: UInt8, text: [UInt16])])] = []
            var longName: [(order: UInt8, checksum: UInt8, text: [UInt16])] = []
            var index = 0
            while index + 32 <= entries.count, entriesRead < 500_000 {
                let entry = Array(entries[index..<(index + 32)])
                index += 32
                entriesRead += 1
                if entry[0] == 0x00 { break }
                if entry[11] == 0x0F {
                    longName.append((entry[0], entry[13], longNameCharacters(entry)))
                } else {
                    records.append((entry, longName))
                    longName = []
                }
            }
            let liveNames = records.filter { $0.entry[0] != 0xE5 }.map { shortName($0.entry) }

            for (entry, longName) in records {
                let attributes = entry[11]
                if attributes & 0x08 != 0 { continue }
                let deleted = parentDeleted || entry[0] == 0xE5
                let short = shortName(entry)
                if short == "." || short == ".." { continue }
                // A deleted short name lost its first letter to the 0xE5 mark.
                let fallback = entry[0] == 0xE5 ? restoreFirstLetter(shortName([0x5F] + entry[1...]), siblings: liveNames) : short
                let name = assembleName(short: entry, longName: longName, deleted: entry[0] == 0xE5) ?? fallback
                let low = UInt32(entry[26]) | UInt32(entry[27]) << 8
                let high = volume.kind == .fat32 ? (UInt32(entry[20]) | UInt32(entry[21]) << 8) << 16 : 0
                let cluster = high | low
                let size = UInt64(entry[28]) | UInt64(entry[29]) << 8 | UInt64(entry[30]) << 16 | UInt64(entry[31]) << 24
                let modified = fatDate(date: UInt16(entry[24]) | UInt16(entry[25]) << 8, time: UInt16(entry[22]) | UInt16(entry[23]) << 8)

                if attributes & 0x10 != 0 {
                    guard volume.isCluster(cluster), depth < 32, !skippedFolders.contains(name) else { continue }
                    queue.append(Pending(cluster: cluster, path: path + name + "/", deleted: deleted, depth: depth + 1))
                    continue
                }
                guard deleted, size > 0, volume.isCluster(cluster), !isNoise(name) else { continue }
                // FAT forgets a deleted file's cluster chain; cameras write
                // files in one piece, so the data most likely follows on.
                let start = volume.offset(of: cluster)
                let length = min(size, volume.end > start ? volume.end - start : 0)
                guard length > 0 else { continue }
                let overwritten = overlaps(start..<(start + length), allocated)
                result.files.append(FoundFile(
                    id: 0, format: nil, kind: RecoveredKind.guess(fromName: name),
                    extents: [Extent(offset: start, length: length)],
                    name: name, folder: path, date: modified,
                    condition: overwritten ? .overwritten : length < size ? .damaged : .good,
                    origin: .directory
                ))
            }
        }

        if volume.kind == .fat32 {
            queue.append(Pending(cluster: volume.rootCluster, path: "/", deleted: false, depth: 0))
        } else if let root = reader.bytes(at: volume.rootOffset, count: Int(volume.rootEntries * 32)) {
            visit(root, path: "/", deleted: false, depth: 0)
        }
        while let next = queue.popLast(), !cancelled() {
            guard visited.insert(next.cluster).inserted else { continue }
            let bytes = next.deleted
                ? deletedFolder(volume, start: next.cluster, reader: reader)
                : chain(volume, start: next.cluster, reader: reader)
            visit(bytes, path: next.path, deleted: next.deleted, depth: next.depth)
        }
        return result
    }

    /// A live folder's clusters, following the FAT.
    private static func chain(_ volume: FATVolume, start: UInt32, reader: Reader) -> [UInt8] {
        var bytes: [UInt8] = []
        var cluster = start
        var seen: Set<UInt32> = []
        while volume.isCluster(cluster), seen.insert(cluster).inserted, bytes.count < 8 << 20,
              let data = reader.bytes(at: volume.offset(of: cluster), count: Int(volume.clusterSize)) {
            bytes += data
            guard let next = volume.entry(cluster, reader) else { break }
            cluster = next
        }
        return bytes
    }

    /// A deleted folder's chain is gone: read on while the clusters still
    /// look like folder entries.
    private static func deletedFolder(_ volume: FATVolume, start: UInt32, reader: Reader) -> [UInt8] {
        var bytes: [UInt8] = []
        var cluster = start
        while volume.isCluster(cluster), bytes.count < 1 << 20,
              let data = reader.bytes(at: volume.offset(of: cluster), count: Int(volume.clusterSize)),
              bytes.isEmpty || looksLikeFolder(data) {
            bytes += data
            cluster += 1
        }
        return bytes
    }

    private static func looksLikeFolder(_ data: [UInt8]) -> Bool {
        guard data.count >= 32 else { return false }
        let first = data[0]
        let attributes = data[11]
        return (first == 0xE5 || first >= 0x20) && (attributes == 0x0F || attributes & 0xC0 == 0)
    }

    /// The 8.3 name. Windows and macOS keep all-lowercase names short and
    /// note the case in two flag bits instead of writing a long name.
    private static func shortName(_ entry: [UInt8]) -> String {
        var base = entry[0..<8].map { $0 }
        if base[0] == 0x05 { base[0] = 0xE5 }
        var name = String(decoding: base, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        var ext = String(decoding: entry[8..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if entry.count > 12 {
            if entry[12] & 0x08 != 0 { name = name.lowercased() }
            if entry[12] & 0x10 != 0 { ext = ext.lowercased() }
        }
        return ext.isEmpty ? name : name + "." + ext
    }

    /// Camera file names, for putting back a lost first letter.
    private static let cameraPrefixes = ["IMG_", "DSC_", "DSCF", "DSCN", "MVI_", "VID_", "GOPR", "PXL_", "DJI_", "MOV_"]

    /// `_MG_0002.JPG` next to `IMG_0001.JPG` was `IMG_0002.JPG`. Siblings
    /// sharing the next three letters decide; failing that, the usual camera
    /// prefixes; failing both, the underscore stays.
    static func restoreFirstLetter(_ name: String, siblings: [String]) -> String {
        let rest = name.dropFirst()
        guard rest.count >= 3 else { return name }
        let letters = Set(siblings.compactMap { sibling -> Character? in
            guard sibling.count == name.count, let first = sibling.first, first != "_",
                  sibling.dropFirst().prefix(3).lowercased() == rest.prefix(3).lowercased()
            else { return nil }
            return first
        })
        if letters.count == 1, let letter = letters.first {
            return String(letter) + rest
        }
        if let prefix = cameraPrefixes.first(where: { rest.uppercased().hasPrefix($0.dropFirst()) }), let letter = prefix.first {
            let restored = String(letter)
            return (rest.first?.isLowercase == true ? restored.lowercased() : restored) + rest
        }
        return name
    }

    private static func longNameCharacters(_ entry: [UInt8]) -> [UInt16] {
        let ranges = [1..<11, 14..<26, 28..<32]
        var characters: [UInt16] = []
        for range in ranges {
            for index in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                characters.append(UInt16(entry[index]) | UInt16(entry[index + 1]) << 8)
            }
        }
        return characters
    }

    /// The long name stored before a short entry, or `nil` without one. A
    /// deleted entry lost its first letter; the checksum in the long name
    /// tells which letter it was. The checksum is only 8 bits, so the long
    /// name's own first letter, the usual source of the short one, goes first.
    private static func assembleName(short entry: [UInt8], longName: [(order: UInt8, checksum: UInt8, text: [UInt16])], deleted: Bool) -> String? {
        var raw = Array(entry[0..<11])
        if deleted {
            guard let checksum = longName.first?.checksum else { return nil }
            let hint = longName.last?.text.first
                .flatMap(Unicode.Scalar.init)
                .flatMap { String(Character($0)).uppercased().utf8.first }
            let candidates = (hint.map { [$0] } ?? []) + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$%'-@~!(){}^#&".utf8)
            guard let letter = candidates.first(where: { candidate in
                raw[0] = candidate
                return shortChecksum(raw) == checksum
            }) else { return nil }
            raw[0] = letter
        }
        guard !longName.isEmpty, longName.allSatisfy({ $0.checksum == shortChecksum(raw) }) else {
            return deleted ? shortName(raw + entry[11...]) : nil
        }
        // Long name entries are stored last part first.
        let characters = longName.reversed().flatMap(\.text).prefix { $0 != 0 && $0 != 0xFFFF }
        return String(decoding: Array(characters), as: UTF16.self)
    }

    private static func shortChecksum(_ name: [UInt8]) -> UInt8 {
        name.prefix(11).reduce(UInt8(0)) { sum, byte in ((sum & 1) << 7 | sum >> 1) &+ byte }
    }

    static func overlaps(_ range: Range<UInt64>, _ sorted: [Range<UInt64>]) -> Bool {
        // Binary search for the first range ending after `range` starts.
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle].upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
        }
        return low < sorted.count && sorted[low].lowerBound < range.upperBound
    }
}

// MARK: - exFAT

struct ExFATVolume {
    let clusterSize: UInt64
    let fatOffset: UInt64
    let heapOffset: UInt64
    let clusterCount: UInt32
    let rootCluster: UInt32
    let end: UInt64

    init?(_ reader: Reader, at start: UInt64) {
        guard reader.ascii("EXFAT   ", at: start + 3),
              let fat = reader.u32le(start + 80), let heap = reader.u32le(start + 88),
              let clusters = reader.u32le(start + 92), let root = reader.u32le(start + 96),
              let length = reader.u64le(start + 72),
              let sectorShift = reader.byte(at: start + 108), let clusterShift = reader.byte(at: start + 109),
              (9...12).contains(sectorShift), clusterShift <= 25 - sectorShift, clusters > 0
        else { return nil }
        let sector = UInt64(1) << sectorShift
        clusterSize = sector << clusterShift
        fatOffset = start + UInt64(fat) * sector
        heapOffset = start + UInt64(heap) * sector
        clusterCount = clusters
        rootCluster = root
        end = start + length * sector
        guard isCluster(root) else { return nil }
    }

    func isCluster(_ cluster: UInt32) -> Bool { cluster >= 2 && cluster < clusterCount + 2 }

    func offset(of cluster: UInt32) -> UInt64 { heapOffset + UInt64(cluster - 2) * clusterSize }

    /// Clusters of a chain: contiguous when the entry says so, else through the FAT.
    func clusters(from first: UInt32, length: UInt64, contiguous: Bool, reader: Reader) -> [UInt32] {
        let needed = Int((length + clusterSize - 1) / clusterSize)
        guard isCluster(first), needed > 0 else { return [] }
        if contiguous {
            return (0..<needed).map { first + UInt32($0) }.filter(isCluster)
        }
        var chain: [UInt32] = []
        var cluster = first
        var seen: Set<UInt32> = []
        while chain.count < needed, isCluster(cluster), seen.insert(cluster).inserted {
            chain.append(cluster)
            guard let next = reader.u32le(fatOffset + UInt64(cluster) * 4) else { break }
            cluster = next
        }
        return chain
    }

    /// Clusters as merged extents on the disk.
    func extents(_ clusters: [UInt32], length: UInt64) -> [Extent] {
        var extents: [Extent] = []
        var remaining = length
        for cluster in clusters where remaining > 0 {
            let take = min(clusterSize, remaining)
            let start = offset(of: cluster)
            if let last = extents.last, last.end == start {
                extents[extents.count - 1] = Extent(offset: last.offset, length: last.length + take)
            } else {
                extents.append(Extent(offset: start, length: take))
            }
            remaining -= take
        }
        return extents
    }

    func scan(_ source: ByteSource, reader: Reader, cancelled: () -> Bool) -> DirectoryScan {
        var result = DirectoryScan(format: "exFAT")
        var bitmap: [UInt8] = []
        var queue: [(clusters: [UInt32], path: String, deleted: Bool, depth: Int)] = [
            (clusters(from: rootCluster, length: 64 << 20, contiguous: false, reader: reader), "/", false, 0),
        ]
        var visited: Set<UInt32> = []
        var found: [FoundFile] = []
        var entriesRead = 0

        while let folder = queue.popLast(), !cancelled() {
            guard let first = folder.clusters.first, visited.insert(first).inserted else { continue }
            var bytes: [UInt8] = []
            for cluster in folder.clusters where bytes.count < 64 << 20 {
                guard let data = reader.bytes(at: offset(of: cluster), count: Int(clusterSize)) else { break }
                bytes += data
            }
            var index = 0
            while index + 32 <= bytes.count, entriesRead < 500_000 {
                let type = bytes[index]
                entriesRead += 1
                if type == 0x00 { break }
                if type == 0x81, folder.depth == 0, bitmap.isEmpty {
                    let start = UInt32(littleEndian: load(bytes, index + 20))
                    let length = UInt64(littleEndian: load(bytes, index + 24))
                    for cluster in clusters(from: start, length: length, contiguous: true, reader: reader) {
                        bitmap += reader.bytes(at: offset(of: cluster), count: Int(clusterSize)) ?? []
                    }
                    bitmap = Array(bitmap.prefix(Int(length)))
                }
                // A file is a primary entry, then its stream and name entries.
                guard type == 0x85 || type == 0x05 else {
                    index += 32
                    continue
                }
                let secondary = Int(bytes[index + 1])
                let deleted = folder.deleted || type == 0x05
                guard secondary >= 2, index + 32 * (secondary + 1) <= bytes.count else {
                    index += 32
                    continue
                }
                let attributes = UInt16(littleEndian: load(bytes, index + 4))
                let modified = UInt32(littleEndian: load(bytes, index + 12))
                let stream = index + 32
                guard bytes[stream] & 0x7F == 0x40 else {
                    index += 32
                    continue
                }
                let flags = bytes[stream + 1]
                let nameLength = Int(bytes[stream + 3])
                let firstCluster = UInt32(littleEndian: load(bytes, stream + 20))
                let dataLength = UInt64(littleEndian: load(bytes, stream + 24))
                var units: [UInt16] = []
                for part in 0..<(secondary - 1) {
                    let entry = stream + 32 * (part + 1)
                    guard bytes[entry] & 0x7F == 0x41 else { break }
                    for character in 0..<15 {
                        units.append(UInt16(littleEndian: load(bytes, entry + 2 + character * 2)))
                    }
                }
                let name = String(decoding: units.prefix(nameLength), as: UTF16.self)
                index += 32 * (secondary + 1)
                guard !name.isEmpty else { continue }
                let contiguous = flags & 0x02 != 0
                if attributes & 0x10 != 0 {
                    guard folder.depth < 32, !DirectoryScanner.skippedFolders.contains(name), isCluster(firstCluster) else { continue }
                    let chain = clusters(from: firstCluster, length: max(dataLength, clusterSize), contiguous: contiguous, reader: reader)
                    queue.append((chain, folder.path + name + "/", deleted, folder.depth + 1))
                    continue
                }
                guard deleted, dataLength > 0, isCluster(firstCluster), !DirectoryScanner.isNoise(name) else { continue }
                // A deleted file's FAT chain may already be reused; trust it
                // only when it is long enough, else assume one piece.
                var chain = clusters(from: firstCluster, length: dataLength, contiguous: contiguous, reader: reader)
                let needed = Int((dataLength + clusterSize - 1) / clusterSize)
                if chain.count < needed {
                    chain = clusters(from: firstCluster, length: dataLength, contiguous: true, reader: reader)
                }
                let extents = extents(chain, length: dataLength)
                let recovered = extents.reduce(0) { $0 + $1.length }
                guard recovered > 0 else { continue }
                found.append(FoundFile(
                    id: 0, format: nil, kind: RecoveredKind.guess(fromName: name), extents: extents,
                    name: name, folder: folder.path,
                    date: fatDate(date: UInt16(modified >> 16), time: UInt16(modified & 0xFFFF)),
                    condition: recovered < dataLength ? .damaged : .good, origin: .directory
                ))
            }
        }

        // The allocation bitmap: one bit per cluster, set while in use.
        var ranges: [Range<UInt64>] = []
        for (byteIndex, byte) in bitmap.enumerated() where byte != 0 {
            for bit in 0..<8 where byte >> bit & 1 == 1 {
                let cluster = UInt32(byteIndex * 8 + bit) + 2
                guard isCluster(cluster) else { continue }
                let start = offset(of: cluster)
                if let last = ranges.last, last.upperBound == start {
                    ranges[ranges.count - 1] = last.lowerBound..<(start + clusterSize)
                } else {
                    ranges.append(start..<(start + clusterSize))
                }
            }
        }
        result.allocated = ranges
        result.files = found.map { file in
            var file = file
            if file.condition == .good, file.extents.contains(where: { DirectoryScanner.overlaps($0.offset..<$0.end, ranges) }) {
                file.condition = .overwritten
            }
            return file
        }
        return result
    }

    private func load<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: Int) -> T {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}
