// Photo formats: where each file ends, from its own structure.
//
// A parser checks that the bytes really are the format, then walks it to the
// end. A file whose structure breaks off is kept but marked damaged: half a
// photo is still worth having.

import Foundation

/// A file a parser recognised at some offset.
struct Carved: Equatable {
    var format: RecoveredFormat
    var length: UInt64
    var condition: FoundFile.Condition = .good
    var details = FileDetails()
    var date: Date?
}

extension Reader {
    func ascii(_ text: String, at offset: UInt64) -> Bool {
        matches(Array(text.utf8), at: offset)
    }
}

enum PhotoFormats {
    static let jpegLimit: UInt64 = 128 << 20
    static let imageLimit: UInt64 = 512 << 20

    // MARK: JPEG

    static func jpeg(_ reader: Reader, at start: UInt64) -> Carved? {
        let limit = min(reader.size, start + jpegLimit)
        var position = start + 2
        var frame: (width: Int, height: Int)?
        var scanned = false
        while position + 4 <= limit {
            guard reader.byte(at: position) == 0xFF, var marker = reader.byte(at: position + 1) else { break }
            // Any number of 0xFF may pad the space before a marker.
            while marker == 0xFF {
                position += 1
                guard let next = reader.byte(at: position + 1) else { return nil }
                marker = next
            }
            switch marker {
            case 0xD9:
                guard let frame, scanned else { return nil }
                return Carved(format: .jpeg, length: position + 2 - start, details: FileDetails(pixelWidth: frame.width, pixelHeight: frame.height))
            case 0xD8:
                // Another image starts here: this one never finished.
                return damaged(frame: frame, scanned: scanned, length: position - start)
            case 0x01, 0xD0...0xD7:
                position += 2
                continue
            case 0xC0...0xFE:
                guard let length = reader.u16be(position + 2), length >= 2 else {
                    return damaged(frame: frame, scanned: scanned, length: position - start)
                }
                if isFrame(marker), let height = reader.u16be(position + 5), let width = reader.u16be(position + 7) {
                    frame = (Int(width), Int(height))
                }
                position += 2 + UInt64(length)
                if marker == 0xDA {
                    scanned = true
                    guard let next = nextMarker(reader, from: position, limit: limit) else {
                        // Nothing but zeros or unreadable space follows: the
                        // picture ends where the data does.
                        let end = firstZeroSector(reader, from: position, start: start, limit: limit) ?? position
                        return damaged(frame: frame, scanned: scanned, length: end - start)
                    }
                    position = next
                }
            default:
                return damaged(frame: frame, scanned: scanned, length: position - start)
            }
        }
        return damaged(frame: frame, scanned: scanned, length: min(position, limit) - start)
    }

    /// Start-of-frame markers; C4, C8 and CC share the range but mean something else.
    private static func isFrame(_ marker: UInt8) -> Bool {
        (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
    }

    private static func damaged(frame: (width: Int, height: Int)?, scanned: Bool, length: UInt64) -> Carved? {
        guard let frame, scanned, length > 0 else { return nil }
        return Carved(format: .jpeg, length: length, condition: .damaged, details: FileDetails(pixelWidth: frame.width, pixelHeight: frame.height))
    }

    /// The first 512-byte block of zeros at or after `offset`, counted in
    /// blocks from `start`. Compressed image data never holds that many.
    static func firstZeroSector(_ reader: Reader, from offset: UInt64, start: UInt64, limit: UInt64) -> UInt64? {
        var sector = start + (offset - start + 511) / 512 * 512
        while sector + 512 <= limit {
            guard let block = reader.bytes(at: sector, count: 512) else { return sector }
            if block.allSatisfy({ $0 == 0 }) { return sector }
            sector += 512
        }
        return nil
    }

    /// The next real marker after entropy-coded data: `FF` followed by
    /// anything but a stuffed zero, a restart marker or more padding.
    private static func nextMarker(_ reader: Reader, from offset: UInt64, limit: UInt64) -> UInt64? {
        var position = offset
        while let hit = reader.find([0xFF], from: position, limit: limit) {
            guard let following = reader.byte(at: hit + 1) else { return nil }
            switch following {
            case 0x00, 0xD0...0xD7: position = hit + 2
            case 0xFF: position = hit + 1
            default: return hit
            }
        }
        return nil
    }

    // MARK: PNG

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func png(_ reader: Reader, at start: UInt64) -> Carved? {
        guard reader.matches(pngSignature, at: start),
              reader.u32be(start + 8) == 13, reader.ascii("IHDR", at: start + 12),
              let width = reader.u32be(start + 16), let height = reader.u32be(start + 20),
              (1...100_000).contains(width), (1...100_000).contains(height)
        else { return nil }
        let details = FileDetails(pixelWidth: Int(width), pixelHeight: Int(height))
        let limit = min(reader.size, start + imageLimit)
        var position = start + 8
        var sawData = false
        while position + 12 <= limit {
            guard let length = reader.u32be(position), length <= 0x7FFF_FFFF,
                  let type = reader.bytes(at: position + 4, count: 4), type.allSatisfy(isLetter)
            else { break }
            position += 12 + UInt64(length)
            switch String(decoding: type, as: UTF8.self) {
            case "IDAT": sawData = true
            case "IEND": return sawData ? Carved(format: .png, length: position - start, details: details) : nil
            default: break
            }
        }
        return sawData ? Carved(format: .png, length: min(position, limit) - start, condition: .damaged, details: details) : nil
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    // MARK: GIF

    static func gif(_ reader: Reader, at start: UInt64) -> Carved? {
        guard reader.ascii("GIF87a", at: start) || reader.ascii("GIF89a", at: start),
              let width = reader.u16le(start + 6), let height = reader.u16le(start + 8),
              let flags = reader.byte(at: start + 10), width > 0, height > 0
        else { return nil }
        let details = FileDetails(pixelWidth: Int(width), pixelHeight: Int(height))
        let limit = min(reader.size, start + jpegLimit)
        var position = start + 13 + colorTableSize(flags)
        var images = 0
        while position < limit, let block = reader.byte(at: position) {
            switch block {
            case 0x2C:
                guard let packed = reader.byte(at: position + 9) else { return nil }
                position += 10 + colorTableSize(packed) + 1
                guard let next = skipSubBlocks(reader, from: position, limit: limit) else { return incomplete(images, position, start, details) }
                position = next
                images += 1
            case 0x21:
                guard let next = skipSubBlocks(reader, from: position + 2, limit: limit) else { return incomplete(images, position, start, details) }
                position = next
            case 0x3B:
                return images > 0 ? Carved(format: .gif, length: position + 1 - start, details: details) : nil
            default:
                return incomplete(images, position, start, details)
            }
        }
        return incomplete(images, min(position, limit), start, details)
    }

    private static func colorTableSize(_ flags: UInt8) -> UInt64 {
        flags & 0x80 == 0 ? 0 : 3 << (UInt64(flags & 0x07) + 1)
    }

    private static func skipSubBlocks(_ reader: Reader, from offset: UInt64, limit: UInt64) -> UInt64? {
        var position = offset
        while position < limit, let size = reader.byte(at: position) {
            position += 1 + UInt64(size)
            if size == 0 { return position }
        }
        return nil
    }

    private static func incomplete(_ images: Int, _ position: UInt64, _ start: UInt64, _ details: FileDetails) -> Carved? {
        images > 0 ? Carved(format: .gif, length: position - start, condition: .damaged, details: details) : nil
    }

    // MARK: BMP

    static func bmp(_ reader: Reader, at start: UInt64) -> Carved? {
        guard reader.ascii("BM", at: start),
              let size = reader.u32le(start + 2), let reserved = reader.u32le(start + 6),
              let dataOffset = reader.u32le(start + 10), let header = reader.u32le(start + 14),
              reserved == 0, [12, 40, 52, 56, 64, 108, 124].contains(header),
              UInt64(size) <= imageLimit, dataOffset >= 14 + header, dataOffset < size
        else { return nil }
        let core = header == 12
        func signed(_ value: UInt32) -> Int { Int(Int32(bitPattern: value)) }
        guard let width = core ? reader.u16le(start + 18).map(Int.init) : reader.u32le(start + 18).map(signed),
              let height = core ? reader.u16le(start + 20).map(Int.init) : reader.u32le(start + 22).map(signed),
              let planes = reader.u16le(start + (core ? 22 : 26)), let depth = reader.u16le(start + (core ? 24 : 28)),
              planes == 1, [1, 4, 8, 16, 24, 32].contains(depth), (1...100_000).contains(width), (1...100_000).contains(abs(height))
        else { return nil }
        // Uncompressed pixels must fit in the file the header claims.
        let compression = core ? 0 : reader.u32le(start + 30) ?? 0
        if compression == 0 {
            let row = (UInt64(width) * UInt64(depth) + 31) / 32 * 4
            guard row * UInt64(abs(height)) <= UInt64(size - dataOffset) else { return nil }
        }
        return Carved(format: .bmp, length: UInt64(size), details: FileDetails(pixelWidth: width, pixelHeight: abs(height)))
    }

    // MARK: TIFF and the raw formats built on it

    /// Walks every image directory and keeps the furthest byte any of them
    /// points at: strips, tiles, previews and tag data.
    static func tiff(_ reader: Reader, at start: UInt64) -> Carved? {
        guard let head = reader.bytes(at: start, count: 4) else { return nil }
        let littleEndian: Bool
        var format = RecoveredFormat.tiff
        switch head {
        case [0x49, 0x49, 0x2A, 0x00]: littleEndian = true
        case [0x4D, 0x4D, 0x00, 0x2A]: littleEndian = false
        case [0x49, 0x49, 0x52, 0x4F], [0x49, 0x49, 0x52, 0x53]: littleEndian = true; format = .orf
        case [0x4D, 0x4D, 0x4F, 0x52]: littleEndian = false; format = .orf
        default: return nil
        }
        let limit = min(reader.size - start, imageLimit)
        func u16(_ offset: UInt64) -> UInt64? {
            (littleEndian ? reader.u16le(start + offset) : reader.u16be(start + offset)).map(UInt64.init)
        }
        func u32(_ offset: UInt64) -> UInt64? {
            (littleEndian ? reader.u32le(start + offset) : reader.u32be(start + offset)).map(UInt64.init)
        }
        func values(type: UInt64, count: UInt64, at offset: UInt64) -> [UInt64] {
            let wide = type == 4 || type == 13
            guard type == 3 || wide, count <= 65_536 else { return [] }
            return (0..<count).compactMap { wide ? u32(offset + $0 * 4) : u16(offset + $0 * 2) }
        }
        guard let first = u32(4), first >= 8, first < limit else { return nil }
        if format == .tiff, reader.ascii("CR", at: start + 8), reader.byte(at: start + 10) == 2 {
            format = .cr2
        }

        var end: UInt64 = 8
        var queue = [first]
        var visited: Set<UInt64> = []
        var sawImage = false
        var make = ""
        var isDNG = false
        var size = (width: 0, height: 0)
        while let directory = queue.popLast(), visited.count < 64 {
            guard directory >= 8, directory < limit, visited.insert(directory).inserted,
                  let count = u16(directory), (1...2_000).contains(count)
            else { continue }
            end = max(end, directory + 2 + count * 12 + 4)
            var offsets: [UInt64] = []
            var lengths: [UInt64] = []
            var preview: (offset: UInt64?, length: UInt64?) = (nil, nil)
            var dimensions = (width: 0, height: 0)
            for index in 0..<count {
                let entry = directory + 2 + index * 12
                guard let tag = u16(entry), let type = u16(entry + 2), let number = u32(entry + 4) else { continue }
                let unit: UInt64 = switch type {
                case 1, 2, 6, 7: 1
                case 3, 8: 2
                case 4, 9, 11, 13: 4
                case 5, 10, 12: 8
                default: 0
                }
                let bytes = unit * number
                guard unit > 0, bytes <= limit else { continue }
                let valueOffset = bytes <= 4 ? entry + 8 : (u32(entry + 8) ?? 0)
                if bytes > 4 {
                    guard valueOffset + bytes <= limit else { continue }
                    end = max(end, valueOffset + bytes)
                }
                switch tag {
                case 0x100: dimensions.width = Int(values(type: type, count: 1, at: valueOffset).first ?? 0)
                case 0x101: dimensions.height = Int(values(type: type, count: 1, at: valueOffset).first ?? 0)
                case 0x10F:
                    make = String(decoding: (reader.bytes(at: start + valueOffset, count: Int(min(bytes, 64))) ?? []).prefix { $0 != 0 }, as: UTF8.self)
                case 0x111, 0x144: offsets = values(type: type, count: number, at: valueOffset)
                case 0x117, 0x145: lengths = values(type: type, count: number, at: valueOffset)
                case 0x201: preview.offset = values(type: type, count: 1, at: valueOffset).first
                case 0x202: preview.length = values(type: type, count: 1, at: valueOffset).first
                case 0x14A: queue += values(type: type, count: number, at: valueOffset)
                case 0x8769, 0x8825, 0xA005: queue += values(type: type, count: 1, at: valueOffset)
                case 0xC612: isDNG = true
                default: break
                }
            }
            for (offset, length) in zip(offsets, lengths) where offset + length <= limit {
                end = max(end, offset + length)
                sawImage = sawImage || length > 0
            }
            if let offset = preview.offset, let length = preview.length, offset + length <= limit {
                end = max(end, offset + length)
                sawImage = sawImage || length > 0
            }
            if dimensions.width * dimensions.height > size.width * size.height {
                size = dimensions
            }
            if let next = u32(directory + 2 + count * 12), next != 0 {
                queue.append(next)
            }
        }
        guard sawImage, end >= 64 else { return nil }
        if format == .tiff {
            let maker = make.uppercased()
            format = isDNG ? .dng
                : maker.hasPrefix("NIKON") ? .nef
                : maker.hasPrefix("SONY") ? .arw
                : maker.hasPrefix("PENTAX") || maker.hasPrefix("RICOH") ? .pef
                : .tiff
        }
        return Carved(format: format, length: end, details: FileDetails(pixelWidth: size.width, pixelHeight: size.height))
    }

    // MARK: Fujifilm raw

    /// The header lists the embedded preview and the sensor data with their sizes.
    static func raf(_ reader: Reader, at start: UInt64) -> Carved? {
        guard reader.ascii("FUJIFILMCCD-RAW ", at: start) else { return nil }
        var end: UInt64 = 108
        for (offset, length) in [(84, 88), (92, 96), (100, 104)] as [(UInt64, UInt64)] {
            guard let position = reader.u32be(start + offset), let size = reader.u32be(start + length) else { return nil }
            end = max(end, UInt64(position) + UInt64(size))
        }
        guard end <= imageLimit, start + end <= reader.size else { return nil }
        return Carved(format: .raf, length: end)
    }
}
