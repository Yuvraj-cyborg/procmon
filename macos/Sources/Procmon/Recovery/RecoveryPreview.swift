// Pictures of found files, read straight off the disk: ImageIO and
// AVFoundation ask for the bytes they need, so a thumbnail of a 4 GB video
// reads a few hundred kilobytes and nothing is copied anywhere first.

import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One found file's bytes, as if it were a file of its own.
final class FoundFileReader: Sendable {
    let source: ByteSource
    let extents: [Extent]
    let size: UInt64

    init(_ file: FoundFile, source: ByteSource) {
        self.source = source
        extents = file.extents
        size = file.extents.reduce(0) { $0 + $1.length }
    }

    /// Reads up to `count` bytes at `position` within the file; unreadable bytes read as zeros.
    func read(into buffer: UnsafeMutableRawPointer, at position: UInt64, count: Int) -> Int {
        var done = 0
        var logical: UInt64 = 0
        for extent in extents where done < count {
            defer { logical += extent.length }
            let wanted = position + UInt64(done)
            guard wanted < logical + extent.length, wanted >= logical else { continue }
            let within = wanted - logical
            let take = Int(min(UInt64(count - done), extent.length - within))
            let target = UnsafeMutableRawBufferPointer(start: buffer + done, count: take)
            let got = (try? source.read(into: target, at: extent.offset + within)) ?? {
                target.initializeMemory(as: UInt8.self, repeating: 0)
                return take
            }()
            done += got
            if got < take { break }
        }
        return done
    }

    func data(at position: UInt64, count: Int) -> Data {
        var data = Data(count: count)
        let got = data.withUnsafeMutableBytes { read(into: $0.baseAddress!, at: position, count: count) }
        return data.prefix(got)
    }
}

/// What a preview learned that the parsers could not.
struct PreviewFacts: Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var date: Date?
}

/// Thumbnails, kept while the page shows the same scan.
final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSNumber, NSImage>()

    init() {
        cache.countLimit = 600
    }

    func image(_ id: Int) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }
    func store(_ image: NSImage, _ id: Int) { cache.setObject(image, forKey: NSNumber(value: id)) }
    func removeAll() { cache.removeAllObjects() }
}

enum RecoveryPreview {
    /// At most this many previews are made at once, so scrolling stays smooth.
    private static let gate = Gate(limit: 4)

    /// A picture of `file`, at most `size` pixels on its longer side.
    static func image(of file: FoundFile, source: ByteSource, size: Int) async -> (CGImage, PreviewFacts)? {
        await gate.run {
            let reader = FoundFileReader(file, source: source)
            switch file.format?.kind ?? file.kind {
            case .photo:
                return await offMain(qos: .userInitiated) { photo(reader, size: size) }
            case .video:
                guard let type = playableType(file) else { return nil }
                return await video(reader, type: type, size: size)
            case .document where file.format == .pdf:
                return await offMain(qos: .userInitiated) { pdf(reader, size: size) }
            default:
                return nil
            }
        }
    }

    private static func photo(_ reader: FoundFileReader, size: Int) -> (CGImage, PreviewFacts)? {
        guard let provider = provider(reader), let source = CGImageSourceCreateWithDataProvider(provider, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var facts = PreviewFacts()
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            facts.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
            facts.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            facts.date = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDate)
        }
        return (image, facts)
    }

    /// EXIF writes dates as `2024:07:14 18:22:31`, in the camera's local time.
    static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func pdf(_ reader: FoundFileReader, size: Int) -> (CGImage, PreviewFacts)? {
        guard let provider = provider(reader), let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale = CGFloat(size) / max(box.width, box.height, 1)
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage().map { ($0, PreviewFacts(pixelWidth: Int(box.width), pixelHeight: Int(box.height))) }
    }

    /// ImageIO and PDF read through this, a few blocks at a time.
    private static func provider(_ reader: FoundFileReader) -> CGDataProvider? {
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                let reader = Unmanaged<FoundFileReader>.fromOpaque(info!).takeUnretainedValue()
                return reader.read(into: buffer, at: UInt64(position), count: count)
            },
            releaseInfo: { info in
                Unmanaged<FoundFileReader>.fromOpaque(info!).release()
            }
        )
        return CGDataProvider(directInfo: Unmanaged.passRetained(reader).toOpaque(), size: off_t(reader.size), callbacks: &callbacks)
    }

    // MARK: Video

    /// Formats AVFoundation plays; Matroska, WebM and most AVI files it does not.
    static func playableType(_ file: FoundFile) -> UTType? {
        switch file.format {
        case .mp4, .m4v, .threeGP: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .m4a: .mpeg4Audio
        case .mp3: .mp3
        case .wav: .wav
        default: nil
        }
    }

    private static func video(_ reader: FoundFileReader, type: UTType, size: Int) async -> (CGImage, PreviewFacts)? {
        let asset = FoundFileAsset(reader, type: type)
        let generator = AVAssetImageGenerator(asset: asset.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size, height: size)
        let duration = (try? await asset.asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let time = CMTime(seconds: duration > 2 ? 1 : duration / 2, preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: time) else { return nil }
        return (image, PreviewFacts(pixelWidth: nil, pixelHeight: nil, date: nil))
    }
}

/// An AVFoundation asset whose bytes come from a found file, through a
/// resource loader that answers each range AVFoundation asks for.
final class FoundFileAsset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let reader: FoundFileReader
    private let type: UTType
    private let queue = DispatchQueue(label: "procmon.recovery.asset")

    init(_ reader: FoundFileReader, type: UTType) {
        self.reader = reader
        self.type = type
        // A scheme AVFoundation does not know sends every read to the delegate.
        asset = AVURLAsset(url: URL(string: "procmon-found://file.\(type.preferredFilenameExtension ?? "mov")")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = type.identifier
            information.contentLength = Int64(reader.size)
            information.isByteRangeAccessSupported = true
        }
        if let request = loadingRequest.dataRequest {
            let start = UInt64(max(0, request.requestedOffset))
            let end = request.requestsAllDataToEndOfResource ? reader.size : min(reader.size, start + UInt64(request.requestedLength))
            var position = UInt64(max(0, request.currentOffset))
            while position < end, !loadingRequest.isCancelled {
                let count = Int(min(1 << 20, end - position))
                request.respond(with: reader.data(at: position, count: count))
                position += UInt64(count)
            }
        }
        loadingRequest.finishLoading()
        return true
    }
}

/// Lets at most `limit` tasks run its work at once.
actor Gate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        if running >= limit {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            running += 1
        }
        defer {
            if waiting.isEmpty {
                running -= 1
            } else {
                waiting.removeFirst().resume()
            }
        }
        return await work()
    }
}
