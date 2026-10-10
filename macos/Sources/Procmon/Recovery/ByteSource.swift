// Read-only access to the bytes recovery works on: a raw disk, a disk image
// file, or (for tests) bytes in memory.

import Darwin
import Foundation

enum ReadError: Error, Equatable, CustomStringConvertible {
    /// The device is gone, e.g. a card pulled out mid-scan.
    case disconnected
    /// These bytes could not be read; the rest of the device may still be.
    case unreadable(errno: Int32)

    var description: String {
        switch self {
        case .disconnected: "The disk was disconnected."
        case .unreadable(let code): String(cString: strerror(code))
        }
    }
}

/// Something recovery can read from.
protocol ByteSource: AnyObject, Sendable {
    var size: UInt64 { get }
    /// Reads at offsets and lengths that are multiples of this are fastest;
    /// raw disks accept nothing else, and ``read(into:at:)`` handles the rest.
    var blockSize: Int { get }
    /// Reads up to `buffer.count` bytes at `offset`; returns how many, 0 at the end.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws(ReadError) -> Int
}

extension ByteSource {
    /// Up to `count` bytes at `offset`, or `nil` if any of them is unreadable.
    func bytes(at offset: UInt64, count: Int) -> [UInt8]? {
        guard count > 0, offset < size else { return [] }
        let count = Int(min(UInt64(count), size - offset))
        var result = [UInt8](repeating: 0, count: count)
        let read = result.withUnsafeMutableBytes { try? self.read(into: $0, at: offset) }
        guard let read, read == count else { return nil }
        return result
    }
}

/// A disk or disk image, read through one file descriptor with `pread`,
/// which is safe from several threads at once.
final class RawDevice: ByteSource {
    let path: String
    let size: UInt64
    let blockSize: Int
    private let descriptor: Int32

    /// Takes ownership of `descriptor`.
    init(descriptor: Int32, path: String) throws(ReadError) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw .unreadable(errno: code)
        }
        self.descriptor = descriptor
        self.path = path
        if info.st_mode & S_IFMT == S_IFCHR || info.st_mode & S_IFMT == S_IFBLK {
            var blockSize: UInt32 = 0
            var blockCount: UInt64 = 0
            guard ioctl(descriptor, Self.getBlockSize, &blockSize) == 0, ioctl(descriptor, Self.getBlockCount, &blockCount) == 0 else {
                let code = errno
                close(descriptor)
                throw .unreadable(errno: code)
            }
            self.blockSize = Int(max(blockSize, 512))
            size = blockCount * UInt64(blockSize)
        } else {
            blockSize = 512
            size = UInt64(max(info.st_size, 0))
        }
        // Recovery reads everything once: keep it out of the file cache.
        _ = fcntl(descriptor, F_NOCACHE, 1)
    }

    /// Opens a file (a disk image) that needs no special permission.
    convenience init(path: String) throws(ReadError) {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw .unreadable(errno: errno) }
        try self.init(descriptor: descriptor, path: path)
    }

    deinit {
        close(descriptor)
    }

    // `_IOR('d', 24, uint32_t)` and `_IOR('d', 25, uint64_t)` from <sys/disk.h>.
    private static let getBlockSize: UInt = 0x4004_6418
    private static let getBlockCount: UInt = 0x4008_6419

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws(ReadError) -> Int {
        guard offset < size, buffer.count > 0 else { return 0 }
        let wanted = Int(min(UInt64(buffer.count), size - offset))
        let block = UInt64(blockSize)
        if offset % block == 0, wanted % blockSize == 0 {
            return try readAligned(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<wanted]), at: offset)
        }
        // Read the whole blocks around the request, then copy out the middle.
        let start = offset / block * block
        let end = min(size, (offset + UInt64(wanted) + block - 1) / block * block)
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(end - start), alignment: 4096)
        defer { scratch.deallocate() }
        let got = try readAligned(into: scratch, at: start)
        let skip = Int(offset - start)
        let copied = max(0, min(wanted, got - skip))
        if copied > 0 {
            buffer.baseAddress!.copyMemory(from: scratch.baseAddress! + skip, byteCount: copied)
        }
        return copied
    }

    private func readAligned(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws(ReadError) -> Int {
        var done = 0
        while done < buffer.count {
            let result = pread(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if result < 0 {
                let code = errno
                if code == EINTR { continue }
                throw code == ENXIO || code == ENODEV || code == EBADF ? .disconnected : .unreadable(errno: code)
            }
            if result == 0 { break }
            done += result
        }
        return done
    }
}

/// Bytes in memory, for tests.
final class MemorySource: ByteSource {
    let data: [UInt8]
    let blockSize = 512

    init(_ data: [UInt8]) {
        self.data = data
    }

    var size: UInt64 { UInt64(data.count) }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws(ReadError) -> Int {
        guard offset < size else { return 0 }
        let count = min(buffer.count, data.count - Int(offset))
        data.withUnsafeBytes { buffer.baseAddress!.copyMemory(from: $0.baseAddress! + Int(offset), byteCount: count) }
        return count
    }
}

/// Random access for the format parsers: small reads close together,
/// served from a few cached pages. One reader per thread.
final class Reader {
    static let pageSize = 256 * 1024
    private static let pageLimit = 24

    let source: ByteSource
    var size: UInt64 { source.size }
    private var pages: [UInt64: [UInt8]] = [:]
    /// Pages that failed to read, so they are not retried byte by byte.
    private var bad: Set<UInt64> = []
    private var order: [UInt64] = []

    init(_ source: ByteSource) {
        self.source = source
    }

    /// The cached page holding `offset`, or `nil` past the end or when unreadable.
    private func page(_ index: UInt64) -> [UInt8]? {
        if let page = pages[index] { return page }
        guard !bad.contains(index), index * UInt64(Self.pageSize) < size else { return nil }
        guard let page = source.bytes(at: index * UInt64(Self.pageSize), count: Self.pageSize) else {
            bad.insert(index)
            return nil
        }
        if order.count >= Self.pageLimit {
            pages[order.removeFirst()] = nil
        }
        pages[index] = page
        order.append(index)
        return page
    }

    func byte(at offset: UInt64) -> UInt8? {
        let size = UInt64(Self.pageSize)
        guard let page = page(offset / size) else { return nil }
        let index = Int(offset % size)
        return index < page.count ? page[index] : nil
    }

    /// Exactly `count` bytes, or `nil` if any is past the end or unreadable.
    func bytes(at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, offset.addingReportingOverflow(UInt64(count)).partialValue <= size else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(count)
        var position = offset
        let pageSize = UInt64(Self.pageSize)
        while result.count < count {
            guard let page = page(position / pageSize) else { return nil }
            let start = Int(position % pageSize)
            let take = min(count - result.count, page.count - start)
            guard take > 0 else { return nil }
            result.append(contentsOf: page[start..<(start + take)])
            position += UInt64(take)
        }
        return result
    }

    func matches(_ pattern: [UInt8], at offset: UInt64) -> Bool {
        bytes(at: offset, count: pattern.count) == pattern
    }

    func u16le(_ offset: UInt64) -> UInt16? { integer(offset, 2, bigEndian: false).map(UInt16.init) }
    func u16be(_ offset: UInt64) -> UInt16? { integer(offset, 2, bigEndian: true).map(UInt16.init) }
    func u32le(_ offset: UInt64) -> UInt32? { integer(offset, 4, bigEndian: false).map(UInt32.init) }
    func u32be(_ offset: UInt64) -> UInt32? { integer(offset, 4, bigEndian: true).map(UInt32.init) }
    func u64le(_ offset: UInt64) -> UInt64? { integer(offset, 8, bigEndian: false) }
    func u64be(_ offset: UInt64) -> UInt64? { integer(offset, 8, bigEndian: true) }

    private func integer(_ offset: UInt64, _ width: Int, bigEndian: Bool) -> UInt64? {
        guard let bytes = bytes(at: offset, count: width) else { return nil }
        let ordered = bigEndian ? bytes : bytes.reversed()
        return ordered.reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Where `pattern` next starts at or after `offset`, looking no further
    /// than `limit`. Stops at the first unreadable page.
    func find(_ pattern: [UInt8], from offset: UInt64, limit: UInt64) -> UInt64? {
        guard let first = pattern.first else { return offset }
        let end = min(limit, size)
        var position = offset
        let pageSize = UInt64(Self.pageSize)
        while position < end {
            guard let page = page(position / pageSize) else { return nil }
            let start = Int(position % pageSize)
            let stop = min(page.count, start + Int(end - position))
            var found: UInt64?
            page.withUnsafeBufferPointer { buffer in
                var cursor = start
                while cursor < stop, let hit = memchr(buffer.baseAddress! + cursor, Int32(first), stop - cursor) {
                    let index = buffer.baseAddress!.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                    let candidate = position - UInt64(start) + UInt64(index)
                    if index + pattern.count <= buffer.count {
                        if memcmp(buffer.baseAddress! + index, pattern, pattern.count) == 0 {
                            found = candidate
                            return
                        }
                    } else if matches(pattern, at: candidate) {
                        found = candidate
                        return
                    }
                    cursor = index + 1
                }
            }
            if let found { return found < end ? found : nil }
            position += UInt64(stop - start)
        }
        return nil
    }
}
