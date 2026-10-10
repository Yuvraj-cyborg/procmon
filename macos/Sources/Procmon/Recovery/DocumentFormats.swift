// Documents: PDF, and ZIP with the formats built on it (Word, Excel,
// PowerPoint, EPUB). Neither states its size up front, so both are measured
// by finding their closing structure.

import Foundation

enum DocumentFormats {
    static let pdfLimit: UInt64 = 1 << 30
    static let zipLimit: UInt64 = 4 << 30

    // MARK: PDF

    /// A PDF ends at `%%EOF`; an edited one appends more objects and another
    /// `%%EOF`, so the search goes on while what follows still looks like PDF.
    static func pdf(_ reader: Reader, at start: UInt64) -> Carved? {
        guard reader.ascii("%PDF-", at: start), let major = reader.byte(at: start + 5), major == 0x31 || major == 0x32,
              reader.byte(at: start + 6) == 0x2E
        else { return nil }
        let limit = min(reader.size, start + pdfLimit)
        var position = start + 8
        var end: UInt64?
        while let marker = reader.find(Array("%%EOF".utf8), from: position, limit: limit) {
            var after = marker + 5
            while after < limit, let byte = reader.byte(at: after), byte == 0x0D || byte == 0x0A {
                after += 1
            }
            end = after
            guard let next = reader.bytes(at: after, count: 16), continuesDocument(next) else { break }
            position = after
        }
        guard let end else { return nil }
        return Carved(format: .pdf, length: end - start)
    }

    /// An appended update starts with an object (`12 0 obj`), a cross-reference
    /// table, or a comment that is not the start of another PDF.
    private static func continuesDocument(_ bytes: [UInt8]) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix("xref") { return true }
        if text.hasPrefix("%") { return !text.hasPrefix("%PDF") }
        let parts = text.split(separator: " ", maxSplits: 2)
        return parts.count == 3 && parts[0].allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isNumber) && parts[2].hasPrefix("obj")
    }

    // MARK: ZIP

    private static let centralEnd: [UInt8] = [0x50, 0x4B, 0x05, 0x06]

    /// The end-of-archive record says where the central directory starts and
    /// how long it is; the right one is the record those numbers lead back to.
    static func zip(_ reader: Reader, at start: UInt64) -> Carved? {
        guard reader.matches([0x50, 0x4B, 0x03, 0x04], at: start),
              let version = reader.u16le(start + 4), version <= 63,
              let method = reader.u16le(start + 8), [0, 1, 6, 8, 9, 12, 14, 93, 95, 98, 99].contains(method),
              let nameLength = reader.u16le(start + 26), (1...1024).contains(nameLength)
        else { return nil }
        let limit = min(reader.size, start + zipLimit)
        var position = start + 30
        while let record = reader.find(centralEnd, from: position, limit: limit) {
            position = record + 4
            guard let directorySize = reader.u32le(record + 12), let directoryOffset = reader.u32le(record + 16),
                  let comment = reader.u16le(record + 20)
            else { continue }
            var directory: (offset: UInt64, size: UInt64)?
            if directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF {
                directory = zip64Directory(reader, start: start, record: record)
            } else if start + UInt64(directoryOffset) + UInt64(directorySize) == record {
                directory = (UInt64(directoryOffset), UInt64(directorySize))
            }
            guard let directory else { continue }
            let length = record + 22 + UInt64(comment) - start
            return Carved(format: classify(reader, directory: start + directory.offset, size: directory.size), length: length)
        }
        return nil
    }

    /// Archives over 4 GB keep the real numbers in a ZIP64 record, found
    /// through a locator just before the classic one.
    private static func zip64Directory(_ reader: Reader, start: UInt64, record: UInt64) -> (offset: UInt64, size: UInt64)? {
        guard record >= 20, reader.matches([0x50, 0x4B, 0x06, 0x07], at: record - 20),
              let relative = reader.u64le(record - 12)
        else { return nil }
        let zip64 = start + relative
        guard reader.matches([0x50, 0x4B, 0x06, 0x06], at: zip64),
              let size = reader.u64le(zip64 + 40), let offset = reader.u64le(zip64 + 48),
              start + offset + size == zip64
        else { return nil }
        return (offset, size)
    }

    /// Office files and EPUBs are told apart by the names inside.
    private static func classify(_ reader: Reader, directory: UInt64, size: UInt64) -> RecoveredFormat {
        var position = directory
        var names: [String] = []
        while position + 46 <= directory + size, names.count < 2_000, reader.matches([0x50, 0x4B, 0x01, 0x02], at: position),
              let nameLength = reader.u16le(position + 28), let extra = reader.u16le(position + 30), let comment = reader.u16le(position + 32) {
            if let name = reader.bytes(at: position + 46, count: Int(nameLength)) {
                names.append(String(decoding: name, as: UTF8.self))
            }
            position += 46 + UInt64(nameLength) + UInt64(extra) + UInt64(comment)
        }
        if names.contains(where: { $0.hasPrefix("word/") }) { return .docx }
        if names.contains(where: { $0.hasPrefix("xl/") }) { return .xlsx }
        if names.contains(where: { $0.hasPrefix("ppt/") }) { return .pptx }
        if names.contains("mimetype"), names.contains("META-INF/container.xml") { return .epub }
        return .zip
    }
}
