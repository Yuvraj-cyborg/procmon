import Darwin
import Foundation
import Testing
@testable import Procmon

/// A FAT32 volume built in memory: 512-byte sectors and clusters.
private struct FAT32Image {
    static let reserved = 32
    static let clusters = 65_600
    static let fatSectors = ((clusters + 2) * 4 + 511) / 512
    static let dataSector = reserved + 2 * fatSectors

    var bytes = [UInt8](repeating: 0, count: (dataSector + clusters) * 512)

    init() {
        bytes[0] = 0xEB; bytes[1] = 0x58; bytes[2] = 0x90
        put16(11, 512); bytes[13] = 1; put16(14, UInt16(Self.reserved)); bytes[16] = 2; bytes[21] = 0xF8
        put32(32, UInt32(Self.dataSector + Self.clusters)); put32(36, UInt32(Self.fatSectors)); put32(44, 2)
        bytes.replaceSubrange(82..<90, with: Array("FAT32   ".utf8))
        bytes[510] = 0x55; bytes[511] = 0xAA
        setFAT(0, 0x0FFF_FFF8); setFAT(1, 0x0FFF_FFFF)
        setFAT(2, 0x0FFF_FFFF)
    }

    func offset(_ cluster: Int) -> Int { (Self.dataSector + cluster - 2) * 512 }

    mutating func put16(_ at: Int, _ value: UInt16) { bytes.replaceSubrange(at..<(at + 2), with: Fixture.le16(value)) }
    mutating func put32(_ at: Int, _ value: UInt32) { bytes.replaceSubrange(at..<(at + 4), with: Fixture.le32(value)) }

    mutating func setFAT(_ cluster: Int, _ value: UInt32) {
        put32(Self.reserved * 512 + cluster * 4, value)
    }

    /// Writes `content` from `cluster` on; a live file also gets its chain.
    mutating func store(_ content: [UInt8], at cluster: Int, live: Bool) {
        bytes.replaceSubrange(offset(cluster)..<(offset(cluster) + content.count), with: content)
        guard live else { return }
        let count = (content.count + 511) / 512
        for index in 0..<count {
            setFAT(cluster + index, index == count - 1 ? 0x0FFF_FFFF : UInt32(cluster + index + 1))
        }
    }

    /// A 32-byte short entry; `deleted` replaces the first letter with 0xE5.
    static func shortEntry(_ name: String, cluster: Int, size: Int, folder: Bool = false, deleted: Bool = false, lowercase: Bool = false) -> [UInt8] {
        let parts = name == "." ? ["."] : name.split(separator: ".", maxSplits: 1).map(String.init)
        var raw = Array(parts[0].padding(toLength: 8, withPad: " ", startingAt: 0).utf8)
            + Array((parts.count > 1 ? parts[1] : "").padding(toLength: 3, withPad: " ", startingAt: 0).utf8)
        if deleted { raw[0] = 0xE5 }
        var entry = raw + [folder ? 0x10 : 0x20, lowercase ? 0x18 : 0x00] + [UInt8](repeating: 0, count: 19)
        entry.replaceSubrange(20..<22, with: Fixture.le16(UInt16(cluster >> 16)))
        // 14 July 2024, 18:22:30.
        entry.replaceSubrange(22..<24, with: Fixture.le16(UInt16(18 << 11 | 22 << 5 | 15)))
        entry.replaceSubrange(24..<26, with: Fixture.le16(UInt16((2024 - 1980) << 9 | 7 << 5 | 14)))
        entry.replaceSubrange(26..<28, with: Fixture.le16(UInt16(cluster & 0xFFFF)))
        entry.replaceSubrange(28..<32, with: Fixture.le32(UInt32(size)))
        return entry
    }

    /// Long name entries for `name`, last part first, as stored on disk.
    static func longEntries(_ name: String, short: String, deleted: Bool) -> [UInt8] {
        let raw = shortEntry(short, cluster: 0, size: 0).prefix(11)
        let checksum = raw.reduce(UInt8(0)) { sum, byte in ((sum & 1) << 7 | sum >> 1) &+ byte }
        var units = Array(name.utf16) + [0]
        while units.count % 13 != 0 { units.append(0xFFFF) }
        let parts = units.count / 13
        var entries: [UInt8] = []
        for part in (0..<parts).reversed() {
            let chunk = units[(part * 13)..<(part * 13 + 13)]
            var entry = [UInt8](repeating: 0, count: 32)
            entry[0] = deleted ? 0xE5 : UInt8(part + 1) | (part == parts - 1 ? 0x40 : 0)
            entry[11] = 0x0F
            entry[13] = checksum
            for (index, unit) in chunk.enumerated() {
                let position = index < 5 ? 1 + index * 2 : index < 11 ? 14 + (index - 5) * 2 : 28 + (index - 11) * 2
                entry[position] = UInt8(unit & 0xFF)
                entry[position + 1] = UInt8(unit >> 8)
            }
            entries += entry
        }
        return entries
    }
}

@Suite struct FATRecoveryTests {
    @Test func deletedFilesComeBackWithTheirNames() throws {
        var image = FAT32Image()
        let photo = Fixture.jpeg()
        let clip = Fixture.mp3()
        // Live: a photo that reused cluster 10, where OLD.PNG used to be.
        image.store(photo, at: 10, live: true)
        image.store(photo, at: 100, live: false)
        image.store(photo, at: 200, live: false)
        image.store(clip, at: 300, live: false)
        image.store(photo, at: 500, live: false)

        var root = FAT32Image.shortEntry("LIVE.JPG", cluster: 10, size: photo.count)
        root += FAT32Image.shortEntry("IMG_0002.JPG", cluster: 100, size: photo.count, deleted: true)
        root += FAT32Image.longEntries("Holiday photo.jpg", short: "HOLIDA~1.JPG", deleted: true)
        root += FAT32Image.shortEntry("HOLIDA~1.JPG", cluster: 200, size: photo.count, deleted: true)
        root += FAT32Image.shortEntry("SONG.MP3", cluster: 300, size: clip.count, deleted: true, lowercase: true)
        root += FAT32Image.shortEntry("OLD.PNG", cluster: 10, size: 4096, deleted: true)
        root += FAT32Image.longEntries("._IMG_0002.JPG", short: "_IMG_0~1.JPG", deleted: true)
        root += FAT32Image.shortEntry("_IMG_0~1.JPG", cluster: 700, size: 4096, deleted: true)
        root += FAT32Image.shortEntry("TRIP", cluster: 400, size: 0, folder: true, deleted: true)
        image.bytes.replaceSubrange(image.offset(2)..<(image.offset(2) + root.count), with: root)
        // Root needs two clusters for all those entries.
        image.setFAT(2, 3)
        image.setFAT(3, 0x0FFF_FFFF)
        let trip = FAT32Image.shortEntry(".", cluster: 400, size: 0, folder: true)
            + FAT32Image.shortEntry("DSC_0001.JPG", cluster: 500, size: photo.count, deleted: true)
        image.bytes.replaceSubrange(image.offset(400)..<(image.offset(400) + trip.count), with: trip)

        let source = MemorySource(image.bytes)
        let scan = try #require(DirectoryScanner.scan(source, partition: Partition(offset: 0, length: source.size), cancelled: { false }))
        #expect(scan.format == "FAT32")
        let byName = Dictionary(scan.files.map { ($0.name ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        #expect(Set(byName.keys) == ["IMG_0002.JPG", "Holiday photo.jpg", "_ong.mp3", "_LD.PNG", "DSC_0001.JPG"])
        #expect(byName["IMG_0002.JPG"]?.extents == [Extent(offset: UInt64(image.offset(100)), length: UInt64(photo.count))])
        #expect(byName["IMG_0002.JPG"]?.condition == .good)
        #expect(byName["Holiday photo.jpg"]?.kind == .photo)
        #expect(byName["DSC_0001.JPG"]?.folder == "/_RIP/")
        #expect(byName["_LD.PNG"]?.condition == .overwritten)
        let date = try #require(byName["IMG_0002.JPG"]?.date)
        #expect(Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date)
            == DateComponents(year: 2024, month: 7, day: 14, hour: 18, minute: 22))
        // The live photo's clusters are skipped by the content scan.
        #expect(DirectoryScanner.overlaps(UInt64(image.offset(10))..<UInt64(image.offset(11)), scan.allocated))
        #expect(!DirectoryScanner.overlaps(UInt64(image.offset(100))..<UInt64(image.offset(101)), scan.allocated))
    }

    @Test func theWholeScanMergesNamedAndFoundFiles() throws {
        var image = FAT32Image()
        let photo = Fixture.jpeg()
        image.store(photo, at: 100, live: false)
        // A photo from before the card was formatted: no entry at all.
        image.store(Fixture.jpeg(width: 50, height: 40), at: 900, live: false)
        let root = FAT32Image.shortEntry("IMG_0042.JPG", cluster: 100, size: photo.count, deleted: true)
        image.bytes.replaceSubrange(image.offset(2)..<(image.offset(2) + root.count), with: root)

        let scanner = RecoveryScanner(source: MemorySource(image.bytes))
        try scanner.run()
        let files = scanner.collect()
        #expect(files.count == 2)
        let named = try #require(files.first { $0.origin == .directory })
        // The lost first letter comes back from the camera's naming pattern.
        #expect(named.name == "IMG_0042.JPG")
        #expect(named.format == .jpeg)
        #expect(named.details.pixelWidth == 96)
        #expect(files.first { $0.origin == .contents }?.offset == UInt64(image.offset(900)))
        #expect(Set(files.map(\.id)).count == 2)
        #expect(scanner.progress.stage == .finished)
    }

    @Test func restoresLostFirstLetters() {
        #expect(DirectoryScanner.restoreFirstLetter("_MG_0002.JPG", siblings: ["IMG_0001.JPG", "IMG_0003.JPG"]) == "IMG_0002.JPG")
        #expect(DirectoryScanner.restoreFirstLetter("_SC_0100.JPG", siblings: []) == "DSC_0100.JPG")
        #expect(DirectoryScanner.restoreFirstLetter("_lip.mp4", siblings: ["notes.txt"]) == "_lip.mp4")
        // Two candidates: no guess.
        #expect(DirectoryScanner.restoreFirstLetter("_AT_1.TXT", siblings: ["CAT_2.TXT", "BAT_3.TXT"]) == "_AT_1.TXT")
    }
}

/// An exFAT volume in memory: 512-byte sectors and clusters.
private struct ExFATImage {
    static let fatSector = 24
    static let heapSector = 64
    static let clusters = 1000
    var bytes = [UInt8](repeating: 0, count: (heapSector + clusters) * 512)

    init() {
        bytes[0] = 0xEB; bytes[1] = 0x76; bytes[2] = 0x90
        bytes.replaceSubrange(3..<11, with: Array("EXFAT   ".utf8))
        put(72, Fixture.le64(UInt64(Self.heapSector + Self.clusters)))
        put(80, Fixture.le32(UInt32(Self.fatSector)))
        put(84, Fixture.le32(8))
        put(88, Fixture.le32(UInt32(Self.heapSector)))
        put(92, Fixture.le32(UInt32(Self.clusters)))
        put(96, Fixture.le32(4))
        bytes[108] = 9
        bytes[109] = 0
        bytes[510] = 0x55; bytes[511] = 0xAA
    }

    func offset(_ cluster: Int) -> Int { (Self.heapSector + cluster - 2) * 512 }

    mutating func put(_ at: Int, _ value: [UInt8]) { bytes.replaceSubrange(at..<(at + value.count), with: value) }

    mutating func chain(_ clusters: [Int]) {
        for (index, cluster) in clusters.enumerated() {
            put(Self.fatSector * 512 + cluster * 4, Fixture.le32(index == clusters.count - 1 ? 0xFFFF_FFFF : UInt32(clusters[index + 1])))
        }
    }

    /// A file's directory entry set: file, stream extension and names.
    static func fileSet(_ name: String, cluster: Int, size: Int, contiguous: Bool, deleted: Bool) -> [UInt8] {
        let units = Array(name.utf16)
        let names = (units.count + 14) / 15
        var file = [UInt8](repeating: 0, count: 32)
        file[0] = deleted ? 0x05 : 0x85
        file[1] = UInt8(1 + names)
        file.replaceSubrange(4..<6, with: Fixture.le16(0x20))
        let day: UInt32 = (2024 - 1980) << 25 | 7 << 21 | 14 << 16
        let time: UInt32 = 18 << 11 | 22 << 5
        file.replaceSubrange(12..<16, with: Fixture.le32(day | time))
        var stream = [UInt8](repeating: 0, count: 32)
        stream[0] = deleted ? 0x40 : 0xC0
        stream[1] = contiguous ? 0x03 : 0x01
        stream[3] = UInt8(units.count)
        stream.replaceSubrange(8..<16, with: Fixture.le64(UInt64(size)))
        stream.replaceSubrange(20..<24, with: Fixture.le32(UInt32(cluster)))
        stream.replaceSubrange(24..<32, with: Fixture.le64(UInt64(size)))
        var entries = file + stream
        for part in 0..<names {
            var entry = [UInt8](repeating: 0, count: 32)
            entry[0] = deleted ? 0x41 : 0xC1
            for (index, unit) in units.dropFirst(part * 15).prefix(15).enumerated() {
                entry.replaceSubrange((2 + index * 2)..<(4 + index * 2), with: Fixture.le16(unit))
            }
            entries += entry
        }
        return entries
    }
}

@Suite struct ExFATRecoveryTests {
    @Test func deletedFilesKeepNamesAndFragments() throws {
        var image = ExFATImage()
        let photo = Fixture.jpeg()
        let photoClusters = (photo.count + 511) / 512
        // Bitmap in cluster 2 marks the bitmap, root (4) and the live file (10…).
        var bitmap = [UInt8](repeating: 0, count: 125)
        for cluster in [2, 4] + Array(10..<(10 + photoClusters)) {
            bitmap[(cluster - 2) / 8] |= 1 << ((cluster - 2) % 8)
        }
        image.put(image.offset(2), bitmap)
        image.chain([4])
        image.put(image.offset(10), photo)
        image.put(image.offset(100), photo)
        // A deleted file in two pieces, linked through the FAT.
        let pieces = Fixture.noise(2048, seed: 9)
        image.put(image.offset(200), Array(pieces[0..<1024]))
        image.put(image.offset(300), Array(pieces[1024...]))
        image.chain([200, 201, 300, 301])

        var bitmapEntry = [UInt8](repeating: 0, count: 32)
        bitmapEntry[0] = 0x81
        bitmapEntry.replaceSubrange(20..<24, with: Fixture.le32(2))
        bitmapEntry.replaceSubrange(24..<32, with: Fixture.le64(125))
        let root = bitmapEntry
            + ExFATImage.fileSet("live.jpg", cluster: 10, size: photo.count, contiguous: true, deleted: false)
            + ExFATImage.fileSet("Summer holiday photo.jpg", cluster: 100, size: photo.count, contiguous: true, deleted: true)
            + ExFATImage.fileSet("split.bin", cluster: 200, size: 2048, contiguous: false, deleted: true)
        image.put(image.offset(4), root)

        let source = MemorySource(image.bytes)
        let scan = try #require(DirectoryScanner.scan(source, partition: Partition(offset: 0, length: source.size), cancelled: { false }))
        #expect(scan.format == "exFAT")
        let byName = Dictionary(scan.files.map { ($0.name ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        #expect(Set(byName.keys) == ["Summer holiday photo.jpg", "split.bin"])
        #expect(byName["Summer holiday photo.jpg"]?.extents == [Extent(offset: UInt64(image.offset(100)), length: UInt64(photo.count))])
        #expect(byName["split.bin"]?.extents == [
            Extent(offset: UInt64(image.offset(200)), length: 1024), Extent(offset: UInt64(image.offset(300)), length: 1024),
        ])
        #expect(DirectoryScanner.overlaps(UInt64(image.offset(10))..<UInt64(image.offset(11)), scan.allocated))
        #expect(!DirectoryScanner.overlaps(UInt64(image.offset(100))..<UInt64(image.offset(101)), scan.allocated))
    }
}

@Suite struct PartitionTableTests {
    @Test func readsMBRPartitions() {
        var disk = [UInt8](repeating: 0, count: 4 << 20)
        disk[446 + 4] = 0x0C
        disk.replaceSubrange((446 + 8)..<(446 + 12), with: Fixture.le32(2048))
        disk.replaceSubrange((446 + 12)..<(446 + 16), with: Fixture.le32(4096))
        disk[510] = 0x55; disk[511] = 0xAA
        let partitions = PartitionTable.partitions(Reader(MemorySource(disk)))
        #expect(partitions == [Partition(offset: 2048 * 512, length: 4096 * 512)])
    }

    @Test func readsGPTPartitions() {
        var disk = [UInt8](repeating: 0, count: 4 << 20)
        disk[446 + 4] = 0xEE
        disk.replaceSubrange((446 + 8)..<(446 + 12), with: Fixture.le32(1))
        disk.replaceSubrange((446 + 12)..<(446 + 16), with: Fixture.le32(8191))
        disk[510] = 0x55; disk[511] = 0xAA
        disk.replaceSubrange(512..<520, with: Array("EFI PART".utf8))
        disk.replaceSubrange((512 + 72)..<(512 + 80), with: Fixture.le64(2))
        disk.replaceSubrange((512 + 80)..<(512 + 84), with: Fixture.le32(4))
        disk.replaceSubrange((512 + 84)..<(512 + 88), with: Fixture.le32(128))
        let entry = 1024
        disk.replaceSubrange(entry..<(entry + 16), with: [UInt8](repeating: 0xAB, count: 16))
        disk.replaceSubrange((entry + 32)..<(entry + 40), with: Fixture.le64(40))
        disk.replaceSubrange((entry + 40)..<(entry + 48), with: Fixture.le64(4039))
        #expect(PartitionTable.partitions(Reader(MemorySource(disk))) == [Partition(offset: 40 * 512, length: 4000 * 512)])
    }

    @Test func aCardWithoutATableIsOneVolume() {
        let image = FAT32Image()
        #expect(PartitionTable.partitions(Reader(MemorySource(image.bytes))) == [Partition(offset: 0, length: UInt64(image.bytes.count))])
    }

    @Test func partitionsAreToldFromNestedSlices() {
        #expect(RecoverySources.isPartition("disk4s1", of: "disk4"))
        #expect(RecoverySources.isPartition("disk4s12", of: "disk4"))
        #expect(!RecoverySources.isPartition("disk4s1s1", of: "disk4"))
        #expect(!RecoverySources.isPartition("disk41s1", of: "disk4"))
    }
}

@Suite struct DiskAccessTests {
    /// `authopen` sends the disk's descriptor over a socket; this sends one
    /// the same way and checks it arrives as the same file.
    @Test func receivesADescriptorOverASocket() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("procmon-fd-\(UUID().uuidString)")
        try Data("disk".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var sockets: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { close(sockets[0]); close(sockets[1]) }
        let file = open(url.path, O_RDONLY)
        defer { close(file) }

        var control = [UInt8](repeating: 0, count: 16)
        control.replaceSubrange(0..<4, with: Fixture.le32(16))
        control.replaceSubrange(4..<8, with: Fixture.le32(UInt32(SOL_SOCKET)))
        control.replaceSubrange(8..<12, with: Fixture.le32(UInt32(SCM_RIGHTS)))
        control.replaceSubrange(12..<16, with: Fixture.le32(UInt32(file)))
        var byte: UInt8 = 0
        let sent = control.withUnsafeMutableBytes { controlBuffer in
            withUnsafeMutablePointer(to: &byte) { data in
                var vector = iovec(iov_base: UnsafeMutableRawPointer(data), iov_len: 1)
                return withUnsafeMutablePointer(to: &vector) { vectors in
                    var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectors, msg_iovlen: 1,
                                          msg_control: controlBuffer.baseAddress, msg_controllen: 16, msg_flags: 0)
                    return sendmsg(sockets[1], &message, 0)
                }
            }
        }
        #expect(sent == 1)
        let received = try #require(DiskAccess.receiveDescriptor(sockets[0]))
        defer { close(received) }
        var original = stat()
        var copy = stat()
        fstat(file, &original)
        fstat(received, &copy)
        #expect(original.st_ino == copy.st_ino)
        #expect(received != file)
    }

    @Test func nothingSentMeansNoDescriptor() {
        var sockets: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        close(sockets[1])
        #expect(DiskAccess.receiveDescriptor(sockets[0]) == nil)
        close(sockets[0])
    }

    @Test func imageFilesOpenWithoutAPassword() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("procmon-image-\(UUID().uuidString)")
        try Data(repeating: 7, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let device = try DiskAccess.open(url.path, prompt: "unused")
        #expect(device.size == 4096)
        #expect(device.bytes(at: 1000, count: 3) == [7, 7, 7])
    }
}
