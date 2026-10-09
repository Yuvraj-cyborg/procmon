import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Procmon

@Suite struct CarverTests {
    /// Every format on one disk, with old data between them: each must be
    /// found at its offset with its exact length.
    @Test func findsEveryFormatWithItsExactLength() async throws {
        var files: [(RecoveredFormat, [UInt8])] = [
            (.jpeg, Fixture.jpeg()),
            (.png, try #require(Fixture.image(.png))),
            (.gif, try #require(Fixture.image(.gif))),
            (.bmp, try #require(Fixture.image(.bmp))),
            (.tiff, try #require(Fixture.image(.tiff))),
            (.webp, Fixture.webp()),
            (.mov, try await Fixture.movie(.mov)),
            (.mp4, try await Fixture.movie(.mp4)),
            (.m4a, try Fixture.m4a()),
            (.wav, Fixture.wav()),
            (.mp3, Fixture.mp3()),
            (.webm, Fixture.webm()),
            (.avi, Fixture.avi()),
            (.pdf, Fixture.pdf()),
            (.docx, Fixture.zip([("[Content_Types].xml", "<Types/>"), ("word/document.xml", "<w:document/>")])),
            (.zip, Fixture.zip([("notes.txt", "hello"), ("more/data.csv", "1,2,3")])),
        ]
        if let heic = Fixture.image(.heic) {
            files.append((.heic, heic))
        }
        var disk = DiskLayout()
        var expected: [UInt64: (RecoveredFormat, UInt64)] = [:]
        for (format, bytes) in files {
            disk.gap(1536)
            expected[disk.place(bytes)] = (format, UInt64(bytes.count))
        }
        disk.gap(4096)

        let found = try Carver.found(in: disk.bytes)
        for (offset, (format, length)) in expected.sorted(by: { $0.key < $1.key }) {
            let carved = try #require(found[offset], "\(format) at \(offset) was not found")
            #expect(carved.format == format)
            #expect(carved.length == length, "\(format): \(carved.length) of \(length) bytes")
            #expect(carved.condition == .good, "\(format) should be whole")
        }
        // Nothing invented in the noise between them.
        #expect(Set(found.keys).subtracting(expected.keys).isEmpty, "unexpected: \(found.filter { expected[$0.key] == nil })")
    }

    @Test func readsSizesDurationsAndDates() async throws {
        var disk = DiskLayout()
        let jpeg = disk.place(Fixture.jpeg(width: 120, height: 80))
        let movie = disk.place(try await Fixture.movie(.mov, frames: 24))
        let mp3 = disk.place(Fixture.mp3(frames: 380))
        disk.gap(2048)
        let found = try Carver.found(in: disk.bytes)

        #expect(found[jpeg]?.details == FileDetails(pixelWidth: 120, pixelHeight: 80))
        let video = try #require(found[movie])
        #expect(video.details.pixelWidth == 64)
        #expect(video.details.pixelHeight == 48)
        #expect(abs((video.details.duration?.seconds ?? 0) - 2) < 0.1)
        // 380 frames of 1152 samples at 44.1 kHz.
        #expect(abs((found[mp3]?.details.duration?.seconds ?? 0) - 9.93) < 0.01)
    }

    @Test func aPhotoCutShortIsKeptAndWhatFollowsIsStillFound() throws {
        let photo = Fixture.jpeg(width: 300, height: 200)
        var disk = DiskLayout()
        // The second half was overwritten with zeros, then a PNG was written after it.
        let cut = disk.place(Array(photo.prefix(photo.count / 2)) + [UInt8](repeating: 0, count: 4096))
        let png = disk.place(try #require(Fixture.image(.png)))
        disk.gap(1024)
        let found = try Carver.found(in: disk.bytes)

        let damaged = try #require(found[cut])
        #expect(damaged.format == .jpeg)
        #expect(damaged.condition == .damaged)
        #expect(damaged.length >= UInt64(photo.count / 2))
        #expect(found[png]?.format == .png)
    }

    @Test func thumbnailsInsideAPhotoAreNotReportedSeparately() throws {
        // A JPEG with a JPEG embedded at a block boundary of its own data.
        let inner = Fixture.jpeg(width: 32, height: 24)
        var outer = Fixture.jpeg(width: 400, height: 300)
        let comment = [UInt8](repeating: 0x20, count: (512 - (2 + 4) % 512)) + inner
        let segment: [UInt8] = [0xFF, 0xFE, UInt8((comment.count + 2) >> 8), UInt8((comment.count + 2) & 0xFF)] + comment
        outer.insert(contentsOf: segment, at: 2)
        var disk = DiskLayout()
        let offset = disk.place(outer)
        disk.gap(512)
        let found = try Carver.found(in: disk.bytes)
        #expect(found.count == 1)
        #expect(found[offset]?.length == UInt64(outer.count))
    }

    @Test func editedPDFsKeepTheirAppendedUpdate() throws {
        var disk = DiskLayout()
        let updated = Fixture.pdf(updated: true)
        let offset = disk.place(updated)
        disk.gap(1024)
        #expect(try Carver.found(in: disk.bytes)[offset]?.length == UInt64(updated.count))
    }

    @Test func liveRecordingsWithoutASizeAreMeasured() throws {
        var disk = DiskLayout()
        let webm = Fixture.webm(knownSize: false)
        let offset = disk.place(webm)
        disk.gap(1024)
        let carved = try #require(try Carver.found(in: disk.bytes)[offset])
        #expect(carved.format == .webm)
        #expect(carved.length == UInt64(webm.count))
    }

    @Test func bareMP3FramesNeedALongRun() throws {
        var disk = DiskLayout()
        let short = disk.place(Fixture.mp3(tagged: false, frames: 8))
        disk.gap(512)
        let long = disk.place(Fixture.mp3(tagged: false, frames: 64))
        disk.gap(512)
        let found = try Carver.found(in: disk.bytes)
        #expect(found[short] == nil)
        #expect(found[long]?.format == .mp3)
    }

    @Test func liveFilesAreSkipped() throws {
        var disk = DiskLayout()
        let kept = disk.place(Fixture.jpeg())
        let live = disk.place(try #require(Fixture.image(.png)))
        disk.gap(512)
        let found = try Carver.found(in: disk.bytes, skipping: [live..<(live + 512)])
        #expect(found[kept] != nil)
        #expect(found[live] == nil)
    }

    @Test func unreadableBlocksAreCountedAndPassedOver() throws {
        var disk = DiskLayout()
        disk.gap(256 * 1024)
        let after = disk.place(Fixture.jpeg())
        disk.gap(512)
        let source = FlakySource(MemorySource(disk.bytes), bad: 64 * 1024..<128 * 1024)
        let progress = RecoveryProgress()
        var found: [UInt64] = []
        try Carver.scan(source, progress: progress) { found.append($1) }
        #expect(found == [after])
        #expect(progress.unreadable == Bytes(64 * 1024))
    }

    @Test func aDisconnectedDiskEndsTheScan() {
        let source = FlakySource(MemorySource([UInt8](repeating: 0, count: 1 << 20)), bad: 0..<1, gone: true)
        #expect(throws: ReadError.disconnected) {
            try Carver.scan(source, progress: RecoveryProgress()) { _, _ in }
        }
    }

    @Test func classifiesISOMediaBrands() {
        #expect(MediaFormats.classify(["heic", "mif1"]) == .heic)
        #expect(MediaFormats.classify(["mif1", "avif"]) == .avif)
        #expect(MediaFormats.classify(["qt  "]) == .mov)
        #expect(MediaFormats.classify(["crx "]) == .cr3)
        #expect(MediaFormats.classify(["M4A ", "isom"]) == .m4a)
        #expect(MediaFormats.classify(["3gp4"]) == .threeGP)
        #expect(MediaFormats.classify(["isom", "avc1"]) == .mp4)
    }

    @Test func quickTimeDatesNeedAClock() {
        #expect(MediaFormats.quickTimeDate(0) == nil)
        let date = MediaFormats.quickTimeDate(3_803_976_000)
        #expect(date.map { Calendar(identifier: .gregorian).component(.year, from: $0) } == 2024)
    }
}

/// A source with a patch that cannot be read, or that vanishes.
final class FlakySource: ByteSource {
    let inner: MemorySource
    let bad: Range<UInt64>
    let gone: Bool

    init(_ inner: MemorySource, bad: Range<UInt64>, gone: Bool = false) {
        self.inner = inner
        self.bad = bad
        self.gone = gone
    }

    var size: UInt64 { inner.size }
    var blockSize: Int { inner.blockSize }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws(ReadError) -> Int {
        if bad.overlaps(offset..<(offset + UInt64(buffer.count))) {
            throw gone ? .disconnected : .unreadable(errno: EIO)
        }
        return try inner.read(into: buffer, at: offset)
    }
}
