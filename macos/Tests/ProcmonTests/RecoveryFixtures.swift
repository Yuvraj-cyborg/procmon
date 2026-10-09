import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Procmon

/// Real files of each format, made the way apps make them where macOS can
/// write the format, and by hand where it cannot.
enum Fixture {
    static func image(_ type: UTType, width: Int = 96, height: Int = 64, properties: [CFString: Any] = [:]) -> [UInt8]? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // A gradient with detail, so the encoders have real data to compress.
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: CGFloat((x * y) % 7) / 7, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return [UInt8](data as Data)
    }

    static func jpeg(width: Int = 96, height: Int = 64) -> [UInt8] {
        image(.jpeg, width: width, height: height, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:07:14 18:22:31"],
        ])!
    }

    /// Writes a short H.264 movie, `.mov` or `.mp4`.
    static func movie(_ type: AVFileType, frames: Int = 12) async throws -> [UInt8] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("procmon-\(UUID().uuidString).\(type == .mov ? "mov" : "mp4")")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 20), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return [UInt8](try Data(contentsOf: url))
    }

    /// One second of AAC in an `.m4a`.
    static func m4a() throws -> [UInt8] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("procmon-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            ])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][index] = sin(Float(index) * 0.05) * 0.3
            }
            try file.write(from: buffer)
        }
        return [UInt8](try Data(contentsOf: url))
    }

    static func wav(seconds: Int = 1) -> [UInt8] {
        let rate: UInt32 = 8_000
        let data = Int(rate) * seconds * 2
        var bytes: [UInt8] = Array("RIFF".utf8) + le32(UInt32(36 + data)) + Array("WAVEfmt ".utf8)
        bytes += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        bytes += Array("data".utf8) + le32(UInt32(data)) + [UInt8](repeating: 0x11, count: data)
        return bytes
    }

    /// An ID3 tag, then 40 silent MPEG-1 Layer III frames at 128 kbps.
    static func mp3(tagged: Bool = true, frames: Int = 40) -> [UInt8] {
        var bytes: [UInt8] = tagged ? Array("ID3".utf8) + [3, 0, 0, 0, 0, 0, 10] + [UInt8](repeating: 0, count: 10) : []
        for index in 0..<frames {
            // 44.1 kHz frames alternate between 417 and 418 bytes with padding.
            let padded = index % 3 == 0
            bytes += [0xFF, 0xFB, padded ? 0x92 : 0x90, 0x64]
            bytes += [UInt8](repeating: 0x55, count: (padded ? 418 : 417) - 4)
        }
        return bytes
    }

    static func webm(knownSize: Bool = true) -> [UInt8] {
        let docType: [UInt8] = [0x42, 0x82, 0x84] + Array("webm".utf8)
        let header: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x80 | UInt8(docType.count)] + docType
        let info: [UInt8] = [0x15, 0x49, 0xA9, 0x66, 0x84, 0x2A, 0xD7, 0xB1, 0x81]
        let blocks: [UInt8] = [0xA3, 0x84, 0x81, 0x00, 0x00, 0x80]
        let cluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75, 0x80 | UInt8(blocks.count + 3), 0xE7, 0x81, 0x00] + blocks
        let body = info + cluster
        let size: [UInt8] = knownSize ? [0x80 | UInt8(body.count)] : [0xFF]
        return header + [0x18, 0x53, 0x80, 0x67] + size + body
    }

    static func avi() -> [UInt8] {
        let list: [UInt8] = Array("LIST".utf8) + le32(4 + 64) + Array("hdrl".utf8) + [UInt8](repeating: 0x22, count: 64)
        let movi: [UInt8] = Array("LIST".utf8) + le32(4 + 1000) + Array("movi".utf8) + [UInt8](repeating: 0x33, count: 1000)
        let body = Array("AVI ".utf8) + list + movi
        return Array("RIFF".utf8) + le32(UInt32(body.count)) + body
    }

    static func webp() -> [UInt8] {
        let payload = [UInt8](repeating: 0x2F, count: 301)
        let chunk = Array("VP8L".utf8) + le32(UInt32(payload.count)) + payload + [0]
        let body = Array("WEBP".utf8) + chunk
        return Array("RIFF".utf8) + le32(UInt32(body.count)) + body
    }

    static func pdf(updated: Bool = false) -> [UInt8] {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 10, y: 10, width: 80, height: 40))
        context.endPDFPage()
        context.closePDF()
        var bytes = [UInt8](data as Data)
        if updated {
            bytes += Array("\n12 0 obj\n<< /Type /Annot >>\nendobj\nxref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 13 >>\nstartxref\n9\n%%EOF\n".utf8)
        }
        return bytes
    }

    /// A stored (uncompressed) ZIP with these entries.
    static func zip(_ entries: [(String, String)]) -> [UInt8] {
        var bytes: [UInt8] = []
        var central: [UInt8] = []
        for (name, text) in entries {
            let offset = UInt32(bytes.count)
            let content = Array(text.utf8)
            let crc = crc32(content)
            let header = le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(UInt32(content.count)) + le32(UInt32(content.count))
            bytes += [0x50, 0x4B, 0x03, 0x04] + header + le16(UInt16(name.utf8.count)) + le16(0) + Array(name.utf8) + content
            central += [0x50, 0x4B, 0x01, 0x02] + le16(20) + header + le16(UInt16(name.utf8.count)) + le16(0) + le16(0)
                + le16(0) + le16(0) + le32(0) + le32(offset) + Array(name.utf8)
        }
        let directoryOffset = UInt32(bytes.count)
        bytes += central
        bytes += [0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
            + le32(UInt32(central.count)) + le32(directoryOffset) + le16(0)
        return bytes
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    static func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(value >> (8 * $0) & 0xFF) } }

    /// Pseudo-random bytes with a fixed seed: realistic noise between files.
    static func noise(_ count: Int, seed: UInt64 = 42) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }
}

/// Lays files out like a file system would: each on a block boundary, with
/// leftovers of older data in between.
struct DiskLayout {
    private(set) var bytes: [UInt8] = []
    private(set) var placed: [(offset: UInt64, length: UInt64)] = []

    mutating func gap(_ count: Int, noise: Bool = true) {
        bytes += noise ? Fixture.noise(count, seed: UInt64(bytes.count + 1)) : [UInt8](repeating: 0, count: count)
        align()
    }

    @discardableResult
    mutating func place(_ file: [UInt8]) -> UInt64 {
        align()
        let offset = UInt64(bytes.count)
        bytes += file
        placed.append((offset, UInt64(file.count)))
        // The rest of the last block holds whatever was there before.
        let tail = (512 - bytes.count % 512) % 512
        bytes += Fixture.noise(tail, seed: offset &+ 7)
        return offset
    }

    private mutating func align() {
        let remainder = bytes.count % 512
        if remainder != 0 { bytes += [UInt8](repeating: 0, count: 512 - remainder) }
    }
}

extension Carver {
    /// Every file in `bytes`, keyed by offset.
    static func found(in bytes: [UInt8], skipping: [Range<UInt64>] = []) throws -> [UInt64: Carved] {
        var files: [UInt64: Carved] = [:]
        try scan(MemorySource(bytes), skipping: skipping, progress: RecoveryProgress()) { files[$1] = $0 }
        return files
    }
}
