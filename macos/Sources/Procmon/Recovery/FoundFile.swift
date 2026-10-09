// What recovery finds: files recognised by their contents or listed as
// deleted in a directory, and where their bytes lie on the disk.

import Foundation

enum RecoveredKind: String, CaseIterable, Sendable {
    case photo, video, audio, document, other

    var label: String {
        switch self {
        case .photo: "Photos"
        case .video: "Videos"
        case .audio: "Audio"
        case .document: "Documents"
        case .other: "Other"
        }
    }

    /// "photo", "video", … for counts.
    var noun: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio file"
        case .document: "document"
        case .other: "other file"
        }
    }

    var glyph: Glyph {
        switch self {
        case .photo: .photo
        case .video: .film
        case .audio: .music
        case .document, .other: .document
        }
    }

    /// The kind a file name suggests, for directory entries.
    static func guess(fromName name: String) -> RecoveredKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if let format = RecoveredFormat.allCases.first(where: { $0.extensions.contains(ext) }) {
            return format.kind
        }
        return switch FileCategory.classify(name: name, isDirectory: false) {
        case .image: .photo
        case .video: .video
        case .audio: .audio
        case .document: .document
        default: .other
        }
    }
}

/// A format the carver can recognise and measure from its bytes alone.
enum RecoveredFormat: String, CaseIterable, Sendable {
    case jpeg, png, gif, bmp, webp, heic, avif, tiff, cr2, cr3, nef, arw, dng, orf, pef, raf
    case mp4, mov, m4v, threeGP, avi, mkv, webm
    case m4a, mp3, wav
    case pdf, docx, xlsx, pptx, epub, zip

    var kind: RecoveredKind {
        switch self {
        case .jpeg, .png, .gif, .bmp, .webp, .heic, .avif, .tiff, .cr2, .cr3, .nef, .arw, .dng, .orf, .pef, .raf: .photo
        case .mp4, .mov, .m4v, .threeGP, .avi, .mkv, .webm: .video
        case .m4a, .mp3, .wav: .audio
        case .pdf, .docx, .xlsx, .pptx, .epub, .zip: .document
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .threeGP: "3gp"
        case .tiff: "tif"
        default: rawValue
        }
    }

    /// Extensions a directory entry of this format may carry.
    var extensions: Set<String> {
        switch self {
        case .jpeg: ["jpg", "jpeg", "jpe", "thm"]
        case .tiff: ["tif", "tiff"]
        case .heic: ["heic", "heif", "hif"]
        case .threeGP: ["3gp", "3g2"]
        case .mkv: ["mkv", "mka"]
        default: [fileExtension]
        }
    }

    var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .webp: "WebP"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        case .cr2, .cr3: "Canon raw"
        case .nef: "Nikon raw"
        case .arw: "Sony raw"
        case .dng: "DNG raw"
        case .orf: "Olympus raw"
        case .pef: "Pentax raw"
        case .raf: "Fujifilm raw"
        case .mp4: "MP4"
        case .mov: "QuickTime"
        case .m4v: "M4V"
        case .threeGP: "3GP"
        case .avi: "AVI"
        case .mkv: "Matroska"
        case .webm: "WebM"
        case .m4a: "AAC audio"
        case .mp3: "MP3"
        case .wav: "WAV"
        case .pdf: "PDF"
        case .docx: "Word"
        case .xlsx: "Excel"
        case .pptx: "PowerPoint"
        case .epub: "EPUB"
        case .zip: "ZIP archive"
        }
    }
}

/// A run of bytes on the source.
struct Extent: Hashable, Sendable {
    let offset: UInt64
    let length: UInt64

    var end: UInt64 { offset + length }
}

/// Facts a parser or a preview learned about a file's contents.
struct FileDetails: Hashable, Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Duration?

    var summary: String? {
        var parts: [String] = []
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            parts.append("\(pixelWidth)×\(pixelHeight)")
        }
        if let duration, duration > .zero {
            parts.append(Format.mediaLength(duration))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct FoundFile: Identifiable, Hashable, Sendable {
    enum Origin: Hashable, Sendable {
        /// Recognised by its contents, wherever it lay.
        case contents
        /// Listed as deleted in a FAT or exFAT directory, with its old name.
        case directory
    }

    enum Condition: Hashable, Sendable {
        case good
        /// Its structure broke off or never closed: it may be cut short.
        case damaged
        /// Its space was reused after it was deleted, so little of it is left.
        case overwritten
    }

    let id: Int
    /// `nil` for a deleted directory entry whose contents are not a known format.
    var format: RecoveredFormat?
    var kind: RecoveredKind
    let extents: [Extent]
    /// The name it had, when a directory still remembers it.
    var name: String?
    /// Where it was, from the root of its volume.
    var folder: String?
    var date: Date?
    var condition: Condition
    var details = FileDetails()
    var origin: Origin

    var offset: UInt64 { extents.first?.offset ?? 0 }
    var size: Bytes { Bytes(extents.reduce(0) { $0 + $1.length }) }

    var fileExtension: String {
        let named = name.map { ($0 as NSString).pathExtension } ?? ""
        return named.isEmpty ? format?.fileExtension ?? "bin" : named
    }

    /// A name for the recovered copy: the old one, else the kind and a number.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        let noun = switch kind {
        case .photo: "Photo"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Document"
        case .other: "File"
        }
        return "\(noun) \(String(format: "%05d", id)).\(fileExtension)"
    }
}

extension Format {
    /// Video and audio lengths, e.g. `0:42`, `1:02:05`.
    static func mediaLength(_ duration: Duration) -> String {
        let total = Int(duration.seconds.rounded())
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}
