// Video and audio formats, and the photo formats that share their
// containers (HEIC, AVIF and Canon's CR3 are ISO media files; WebP is RIFF).
//
// These containers state their own sizes, so even a long video is measured
// by reading a few headers rather than all of it.

import Foundation

enum MediaFormats {
    static let videoLimit: UInt64 = 64 << 30
    static let audioLimit: UInt64 = 512 << 20

    // MARK: ISO base media (MP4, MOV, HEIC, AVIF, CR3, M4A, 3GP)

    /// Top-level boxes seen in real files. Anything else after a complete
    /// file belongs to whatever was written next on the disk.
    private static let knownBoxes: Set<String> = [
        "ftyp", "moov", "mdat", "free", "skip", "wide", "uuid", "meta", "pdin", "moof", "mfra", "sidx", "ssix",
        "prft", "emsg", "styp", "pnot", "PICT", "junk", "udta", "XMP_", "beam", "jumb", "ID32",
    ]

    static func isoMedia(_ reader: Reader, at start: UInt64) -> Carved? {
        guard let headerSize = reader.u32be(start), (8...512).contains(headerSize), reader.ascii("ftyp", at: start + 4),
              let major = reader.bytes(at: start + 8, count: 4)
        else { return nil }
        var brands = [String(decoding: major, as: UTF8.self)]
        var cursor = start + 16
        while cursor + 4 <= start + UInt64(headerSize), let brand = reader.bytes(at: cursor, count: 4) {
            brands.append(String(decoding: brand, as: UTF8.self))
            cursor += 4
        }
        let format = classify(brands)
        let limit = min(reader.size, start + videoLimit)
        var position = start
        var sawMovie = false
        var sawData = false
        var sawMeta = false
        var sawFragments = false
        var details = FileDetails()
        var date: Date?
        var condition = FoundFile.Condition.good
        while position + 8 <= limit {
            guard let size32 = reader.u32be(position), let type = reader.bytes(at: position + 4, count: 4),
                  type.allSatisfy({ (0x20...0x7E).contains($0) })
            else { break }
            let name = String(decoding: type, as: UTF8.self)
            let complete = sawData && (sawMovie || sawMeta || sawFragments)
            if position > start && name == "ftyp" { break }
            if !knownBoxes.contains(name) && complete { break }
            var size = UInt64(size32)
            if size32 == 1 {
                guard let large = reader.u64be(position + 8) else { break }
                size = large
            } else if size32 == 0 {
                // "Runs to the end of the file": a recording that was never closed.
                condition = .damaged
                position = limit
                if name == "mdat" { sawData = true }
                break
            }
            guard size >= 8 else { break }
            if position + size > limit {
                condition = .damaged
                position = limit
                if name == "mdat" { sawData = true }
                break
            }
            switch name {
            case "moov":
                sawMovie = true
                (details, date) = movieDetails(reader, box: position, size: size)
            case "mdat": sawData = true
            case "meta": sawMeta = true
            case "moof": sawFragments = true
            default: break
            }
            position += size
        }
        // Still images keep their index in `meta`; everything else (Canon's
        // CR3 included) needs a movie index and the data it points into.
        let playable = format == .heic || format == .avif ? sawMeta : (sawMovie || sawFragments) && sawData
        guard playable, position > start else { return nil }
        return Carved(format: format, length: position - start, condition: condition, details: details, date: date)
    }

    static func classify(_ brands: [String]) -> RecoveredFormat {
        let major = brands.first ?? ""
        switch major {
        case "heic", "heix", "heim", "heis", "hevc", "hevx": return .heic
        case "avif", "avis": return .avif
        case "crx ": return .cr3
        case "qt  ": return .mov
        case "M4A ", "M4B ", "M4P ", "F4A ", "F4B ": return .m4a
        case "M4V ", "M4VH", "M4VP": return .m4v
        case _ where major.hasPrefix("3g"): return .threeGP
        case "mif1", "msf1":
            return brands.contains { $0.hasPrefix("avi") } ? .avif : .heic
        default: return .mp4
        }
    }

    /// Duration and creation date from `mvhd`, size from the largest track header.
    private static func movieDetails(_ reader: Reader, box: UInt64, size: UInt64) -> (FileDetails, Date?) {
        var details = FileDetails()
        var date: Date?
        var position = box + 8
        let end = box + size
        var children = 0
        while position + 8 <= end, children < 512 {
            guard let childSize = reader.u32be(position).map(UInt64.init), childSize >= 8,
                  let type = reader.bytes(at: position + 4, count: 4)
            else { break }
            switch String(decoding: type, as: UTF8.self) {
            case "mvhd":
                let long = reader.byte(at: position + 8) == 1
                let created = long ? reader.u64be(position + 12) : reader.u32be(position + 12).map(UInt64.init)
                let scale = reader.u32be(position + (long ? 28 : 20))
                let length = long ? reader.u64be(position + 32) : reader.u32be(position + 24).map(UInt64.init)
                if let scale, scale > 0, let length, length < UInt64.max / 2 {
                    details.duration = .seconds(Double(length) / Double(scale))
                }
                date = created.flatMap(quickTimeDate)
            case "trak":
                if let (width, height) = trackSize(reader, box: position, size: childSize),
                   width * height > (details.pixelWidth ?? 0) * (details.pixelHeight ?? 0) {
                    details.pixelWidth = width
                    details.pixelHeight = height
                }
            default: break
            }
            position += childSize
            children += 1
        }
        return (details, date)
    }

    private static func trackSize(_ reader: Reader, box: UInt64, size: UInt64) -> (Int, Int)? {
        var position = box + 8
        while position + 8 <= box + size {
            guard let childSize = reader.u32be(position).map(UInt64.init), childSize >= 8 else { return nil }
            if reader.ascii("tkhd", at: position + 4) {
                let long = reader.byte(at: position + 8) == 1
                guard let width = reader.u32be(position + (long ? 96 : 84)), let height = reader.u32be(position + (long ? 100 : 88)) else {
                    return nil
                }
                return (Int(width >> 16), Int(height >> 16))
            }
            position += childSize
        }
        return nil
    }

    /// Seconds since 1904, as QuickTime counts. Cameras without a clock write
    /// zero; anything outside a sane range is ignored.
    static func quickTimeDate(_ seconds: UInt64) -> Date? {
        let date = Date(timeIntervalSince1970: Double(seconds) - 2_082_844_800)
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return (1995...2100).contains(year) ? date : nil
    }

    // MARK: RIFF (AVI, WAV, WebP)

    static func riff(_ reader: Reader, at start: UInt64) -> Carved? {
        guard reader.ascii("RIFF", at: start), let declared = reader.u32le(start + 4), declared >= 4,
              let form = reader.bytes(at: start + 8, count: 4)
        else { return nil }
        // Chunks are padded to an even size.
        var length = 8 + UInt64(declared) + UInt64(declared & 1)
        switch String(decoding: form, as: UTF8.self) {
        case "WEBP":
            guard ["VP8 ", "VP8L", "VP8X"].contains(where: { reader.ascii($0, at: start + 12) }), length <= PhotoFormats.jpegLimit else {
                return nil
            }
            return fit(Carved(format: .webp, length: length), reader, start)
        case "AVI ":
            guard reader.ascii("LIST", at: start + 12), reader.ascii("hdrl", at: start + 20) else { return nil }
            // Recordings over 1 GB continue in extra `RIFF AVIX` chunks.
            while start + length + 12 <= reader.size, reader.ascii("RIFF", at: start + length), reader.ascii("AVIX", at: start + length + 8),
                  let more = reader.u32le(start + length + 4), length < videoLimit {
                length += 8 + UInt64(more) + UInt64(more & 1)
            }
            return fit(Carved(format: .avi, length: length), reader, start)
        case "WAVE":
            guard reader.ascii("fmt ", at: start + 12), let rate = reader.u32le(start + 28) else { return nil }
            var carved = Carved(format: .wav, length: length)
            if rate > 0 {
                carved.details.duration = .seconds(Double(length - 44) / Double(rate))
            }
            return fit(carved, reader, start)
        default:
            return nil
        }
    }

    /// A file running past the end of the disk lost its tail.
    private static func fit(_ carved: Carved, _ reader: Reader, _ start: UInt64) -> Carved {
        guard start + carved.length > reader.size else { return carved }
        var cut = carved
        cut.length = reader.size - start
        cut.condition = .damaged
        return cut
    }

    // MARK: Matroska and WebM

    private static let segmentChildren: Set<UInt64> = [
        0x114D_9B74, 0x1549_A966, 0x1654_AE6B, 0x1F43_B675, 0x1C53_BB6B, 0x1043_A770, 0x1254_C367, 0x1941_A469, 0xEC, 0xBF,
    ]
    private static let cluster: UInt64 = 0x1F43_B675

    static func matroska(_ reader: Reader, at start: UInt64) -> Carved? {
        guard reader.matches([0x1A, 0x45, 0xDF, 0xA3], at: start),
              let header = size(reader, at: start + 4), !header.unknown, header.value < 4096
        else { return nil }
        let headerEnd = start + 4 + UInt64(header.width) + header.value
        var docType: String?
        var position = start + 4 + UInt64(header.width)
        while position < headerEnd, let id = elementID(reader, at: position), let element = size(reader, at: position + UInt64(id.width)) {
            let data = position + UInt64(id.width) + UInt64(element.width)
            if id.value == 0x4282, element.value < 32, let bytes = reader.bytes(at: data, count: Int(element.value)) {
                docType = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            position = data + element.value
        }
        guard let docType, docType == "matroska" || docType == "webm",
              reader.matches([0x18, 0x53, 0x80, 0x67], at: headerEnd), let segment = size(reader, at: headerEnd + 4)
        else { return nil }
        let format: RecoveredFormat = docType == "webm" ? .webm : .mkv
        let body = headerEnd + 4 + UInt64(segment.width)
        let limit = min(reader.size, start + videoLimit)
        if !segment.unknown {
            return fit(Carved(format: format, length: body + segment.value - start), reader, start)
        }
        // A live recording leaves the size open: walk the segment until
        // something that cannot belong to it.
        position = body
        while position < limit, let id = elementID(reader, at: position), segmentChildren.contains(id.value),
              let element = size(reader, at: position + UInt64(id.width)) {
            let data = position + UInt64(id.width) + UInt64(element.width)
            if element.unknown {
                guard id.value == cluster, let end = endOfOpenCluster(reader, from: data, limit: limit) else { break }
                position = end
            } else {
                position = data + element.value
            }
        }
        guard position > body else { return nil }
        return Carved(format: format, length: min(position, limit) - start)
    }

    /// A cluster of unknown size ends where an element that is not one of its children begins.
    private static func endOfOpenCluster(_ reader: Reader, from offset: UInt64, limit: UInt64) -> UInt64? {
        let children: Set<UInt64> = [0xE7, 0xA3, 0xA0, 0xA7, 0xAB, 0xEC, 0xBF]
        var position = offset
        while position < limit, let id = elementID(reader, at: position) {
            guard children.contains(id.value), let element = size(reader, at: position + UInt64(id.width)), !element.unknown else {
                return position
            }
            position += UInt64(id.width) + UInt64(element.width) + element.value
        }
        return position
    }

    /// An element ID keeps its length marker bits, as the spec writes them.
    private static func elementID(_ reader: Reader, at offset: UInt64) -> (value: UInt64, width: Int)? {
        guard let first = reader.byte(at: offset), first != 0 else { return nil }
        let width = first.leadingZeroBitCount + 1
        guard width <= 4, let bytes = reader.bytes(at: offset, count: width) else { return nil }
        return (bytes.reduce(0) { $0 << 8 | UInt64($1) }, width)
    }

    /// A size without its marker bit; all ones means "unknown".
    private static func size(_ reader: Reader, at offset: UInt64) -> (value: UInt64, width: Int, unknown: Bool)? {
        guard let first = reader.byte(at: offset), first != 0 else { return nil }
        let width = first.leadingZeroBitCount + 1
        guard let bytes = reader.bytes(at: offset, count: width) else { return nil }
        let mask: UInt64 = width == 8 ? 0 : UInt64(0xFF) >> width
        var value = UInt64(first) & mask
        for byte in bytes.dropFirst() {
            value = value << 8 | UInt64(byte)
        }
        let allOnes = width == 8 ? value == (1 << 56) - 1 : value == (UInt64(1) << (7 * width)) - 1
        return (value, width, allOnes)
    }

    // MARK: MP3

    struct MPEGFrame: Equatable {
        let length: UInt64
        let samples: Int
        let sampleRate: Int

        private static let bitrates: [[Int]] = [
            [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
            [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
            [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
            [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
            [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
        ]

        init?(header: UInt32) {
            guard header >> 21 == 0x7FF else { return nil }
            let version = Int(header >> 19 & 3)
            let layer = Int(header >> 17 & 3)
            let bitrateIndex = Int(header >> 12 & 0xF)
            let rateIndex = Int(header >> 10 & 3)
            guard version != 1, layer != 0, (1...14).contains(bitrateIndex), rateIndex != 3 else { return nil }
            let mpeg1 = version == 3
            let table = mpeg1 ? 3 - layer : (layer == 3 ? 3 : 4)
            let bitrate = Self.bitrates[table][bitrateIndex] * 1000
            let rate = [44_100, 48_000, 32_000][rateIndex] >> (mpeg1 ? 0 : version == 2 ? 1 : 2)
            let padding = Int(header >> 9 & 1)
            switch layer {
            case 3:
                length = UInt64((12 * bitrate / rate + padding) * 4)
                samples = 384
            case 2:
                length = UInt64(144 * bitrate / rate + padding)
                samples = 1152
            default:
                length = UInt64((mpeg1 ? 144 : 72) * bitrate / rate + padding)
                samples = mpeg1 ? 1152 : 576
            }
            sampleRate = rate
        }
    }

    /// With an ID3 tag the start is certain; bare frames need a long run of
    /// consistent headers before they count, since `FF Ex` is common in any data.
    static func mp3(_ reader: Reader, at start: UInt64) -> Carved? {
        var position = start
        let tagged = reader.ascii("ID3", at: start)
        if tagged {
            guard let flags = reader.byte(at: start + 5), let raw = reader.bytes(at: start + 6, count: 4), raw.allSatisfy({ $0 < 0x80 }) else {
                return nil
            }
            let tag = raw.reduce(UInt64(0)) { $0 << 7 | UInt64($1) }
            position = start + 10 + tag + (flags & 0x10 != 0 ? 10 : 0)
            // Some encoders pad the tag with zeros.
            var padding = 0
            while padding < 65_536, reader.byte(at: position) == 0 {
                position += 1
                padding += 1
            }
        }
        let limit = min(reader.size, start + audioLimit)
        var frames = 0
        var samples = 0
        var rate = 0
        while position + 4 <= limit, let header = reader.u32be(position), let frame = MPEGFrame(header: header) {
            if frames > 0, frame.sampleRate != rate { break }
            rate = frame.sampleRate
            position += frame.length
            frames += 1
            samples += frame.samples
        }
        guard frames >= (tagged ? 4 : 32) else { return nil }
        if reader.ascii("TAG", at: position) {
            position += 128
        }
        var carved = Carved(format: .mp3, length: min(position, limit) - start)
        carved.details.duration = .seconds(Double(samples) / Double(rate))
        return carved
    }
}
