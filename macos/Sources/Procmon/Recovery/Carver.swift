// Finds files by their contents, the way PhotoRec does: read the disk from
// start to end, and wherever a 512-byte block begins with a known signature,
// let that format's parser decide whether a file starts there and how long
// it is. File systems start files on block boundaries, so nothing else needs
// checking, and a file measured whole is skipped rather than searched.

import Foundation
import Synchronization

/// Live counters shared between a recovery scan and the page showing it.
final class RecoveryProgress: Sendable {
    enum Stage: UInt8, Sendable {
        case opening, directories, contents, finished
    }

    private let stageValue = Atomic<UInt8>(Stage.opening.rawValue)
    private let position = Atomic<UInt64>(0)
    private let totalBytes = Atomic<UInt64>(0)
    private let unreadableBytes = Atomic<UInt64>(0)
    private let cancelled = Atomic<Bool>(false)

    var stage: Stage { Stage(rawValue: stageValue.load(ordering: .relaxed)) ?? .opening }
    /// How far through the disk the contents scan has come.
    var scanned: Bytes { Bytes(position.load(ordering: .relaxed)) }
    var total: Bytes { Bytes(totalBytes.load(ordering: .relaxed)) }
    /// Bytes the disk could not return; often a sign it is failing.
    var unreadable: Bytes { Bytes(unreadableBytes.load(ordering: .relaxed)) }
    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    func cancel() { cancelled.store(true, ordering: .relaxed) }

    func begin(_ stage: Stage, total: UInt64? = nil) {
        stageValue.store(stage.rawValue, ordering: .relaxed)
        if let total { totalBytes.store(total, ordering: .relaxed) }
    }

    func reached(_ offset: UInt64) { position.store(offset, ordering: .relaxed) }

    func lost(_ bytes: UInt64) { unreadableBytes.add(bytes, ordering: .relaxed) }
}

enum Carver {
    static let blockSize: UInt64 = 512
    static let chunkSize = 4 << 20

    /// The parser for a block's first bytes, if they look like any format.
    static func parser(for head: UnsafeRawBufferPointer) -> ((Reader, UInt64) -> Carved?)? {
        guard head.count >= 16 else { return nil }
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            bytes.indices.allSatisfy { head[offset + $0] == bytes[$0] }
        }
        func ascii(_ text: String, at offset: Int = 0) -> Bool {
            starts(Array(text.utf8), at: offset)
        }
        switch head[0] {
        case 0xFF:
            if head[1] == 0xD8, head[2] == 0xFF { return PhotoFormats.jpeg }
            if head[1] & 0xE0 == 0xE0 { return MediaFormats.mp3 }
        case 0x89: if ascii("PNG", at: 1) { return PhotoFormats.png }
        case 0x47: if ascii("GIF8") { return PhotoFormats.gif }
        case 0x42: if head[1] == 0x4D { return PhotoFormats.bmp }
        case 0x52: if ascii("RIFF") { return MediaFormats.riff }
        case 0x49:
            if ascii("ID3") { return MediaFormats.mp3 }
            if starts([0x49, 0x49, 0x2A, 0x00]) || ascii("IIRO") || ascii("IIRS") { return PhotoFormats.tiff }
        case 0x4D: if starts([0x4D, 0x4D, 0x00, 0x2A]) || ascii("MMOR") { return PhotoFormats.tiff }
        case 0x46: if ascii("FUJIFILMCCD-RAW ") { return PhotoFormats.raf }
        // Most blocks of free space are zeros: check those without allocating.
        case 0x00: if head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 { return MediaFormats.isoMedia }
        case 0x1A: if starts([0x1A, 0x45, 0xDF, 0xA3]) { return MediaFormats.matroska }
        case 0x25: if ascii("%PDF-") { return DocumentFormats.pdf }
        case 0x50: if starts([0x50, 0x4B, 0x03, 0x04]) { return DocumentFormats.zip }
        default: break
        }
        return nil
    }

    /// Scans `range` of `source`, calling `found` with each file and its
    /// offset. `skipping` lists byte ranges known to hold live files (sorted),
    /// which are stepped over. Unreadable blocks are counted and passed over;
    /// only a disconnected disk ends the scan early.
    static func scan(
        _ source: ByteSource,
        range: Range<UInt64>? = nil,
        skipping: [Range<UInt64>] = [],
        progress: RecoveryProgress,
        found: (Carved, UInt64) -> Void
    ) throws(ReadError) {
        let range = range ?? 0..<source.size
        let reader = Reader(source)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 4096)
        defer { buffer.deallocate() }
        var skip = skipping.makeIterator()
        var nextSkip = skip.next()
        var position = range.lowerBound / blockSize * blockSize

        while position < range.upperBound, !progress.isCancelled {
            while let current = nextSkip, current.upperBound <= position {
                nextSkip = skip.next()
            }
            if let current = nextSkip, current.contains(position) {
                position = (current.upperBound + blockSize - 1) / blockSize * blockSize
                progress.reached(position)
                continue
            }
            let stop = min(range.upperBound, nextSkip?.lowerBound ?? .max, position + UInt64(chunkSize))
            let count = Int(stop - position)
            let valid = try read(source, into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]), at: position, progress: progress)
            guard valid > 0 else { break }

            var resume = position + UInt64(valid)
            var block = 0
            while block + 16 <= valid {
                let head = UnsafeRawBufferPointer(rebasing: buffer[block..<min(valid, block + Int(blockSize))])
                let offset = position + UInt64(block)
                if let parse = parser(for: head), let carved = parse(reader, offset) {
                    found(carved, offset)
                    // A complete file is skipped whole. A damaged one is only
                    // a guess, so whatever lies inside it is still searched.
                    let end = carved.condition == .good ? offset + carved.length : offset + 1
                    let next = (end + blockSize - 1) / blockSize * blockSize
                    if next > offset + blockSize {
                        resume = next
                        break
                    }
                }
                block += Int(blockSize)
            }
            position = resume
            progress.reached(min(position, range.upperBound))
        }
        progress.reached(range.upperBound)
    }

    /// Fills `buffer` from `offset`; unreadable stretches become zeros and
    /// are counted, so one bad patch does not end the scan.
    private static func read(_ source: ByteSource, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, progress: RecoveryProgress) throws(ReadError) -> Int {
        do {
            return try source.read(into: buffer, at: offset)
        } catch .disconnected {
            throw .disconnected
        } catch {
            // Retry in small pieces: only the pieces that fail are lost.
            let piece = 64 * 1024
            var done = 0
            while done < buffer.count {
                let length = min(piece, buffer.count - done)
                let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[done..<(done + length)])
                do {
                    let got = try source.read(into: slice, at: offset + UInt64(done))
                    if got == 0 { break }
                    done += got
                } catch .disconnected {
                    throw .disconnected
                } catch {
                    slice.initializeMemory(as: UInt8.self, repeating: 0)
                    progress.lost(UInt64(length))
                    done += length
                }
            }
            return done
        }
    }
}
