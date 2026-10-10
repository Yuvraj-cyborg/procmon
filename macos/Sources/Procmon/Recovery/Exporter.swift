// Copies found files off the disk being recovered into a new folder.

import Foundation
import Synchronization

final class ExportProgress: Sendable {
    private let filesDone = Atomic<Int>(0)
    private let bytesDone = Atomic<UInt64>(0)
    private let cancelled = Atomic<Bool>(false)

    var files: Int { filesDone.load(ordering: .relaxed) }
    var bytes: Bytes { Bytes(bytesDone.load(ordering: .relaxed)) }
    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    func cancel() { cancelled.store(true, ordering: .relaxed) }
    fileprivate func copied(_ count: Int) { bytesDone.add(UInt64(count), ordering: .relaxed) }
    fileprivate func finishedFile() { filesDone.add(1, ordering: .relaxed) }
}

struct ExportReport: Sendable {
    let folder: URL
    var saved = 0
    var bytes = Bytes.zero
    /// Bytes the disk could not return; saved as zeros.
    var unreadable = Bytes.zero
    var failures: [String] = []
}

enum Exporter {
    /// Saves `files` into a new folder in `destination`, one folder per kind.
    /// Files that still have their names keep them, and their old folders.
    static func export(
        _ files: [FoundFile], from source: ByteSource, sourceName: String, to destination: URL, progress: ExportProgress
    ) throws -> ExportReport {
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        let folder = unique(destination.appendingPathComponent(safe("Recovered from \(sourceName) \(stamp)")))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = ExportReport(folder: folder)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 4096)
        defer { buffer.deallocate() }
        for file in files {
            guard !progress.isCancelled else { break }
            var directory = folder.appendingPathComponent(file.kind.label)
            if let path = file.folder {
                for part in path.split(separator: "/") where !part.isEmpty {
                    directory.appendPathComponent(safe(String(part)))
                }
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = unique(directory.appendingPathComponent(safe(file.displayName)))
                let lost = try copy(file, from: source, to: url, buffer: buffer, progress: progress)
                if let date = file.date {
                    try? FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
                }
                report.saved += 1
                report.bytes += file.size
                report.unreadable += Bytes(lost)
            } catch {
                report.failures.append("\(file.displayName): \(error.localizedDescription)")
            }
            progress.finishedFile()
        }
        return report
    }

    /// Returns the bytes that could not be read and were written as zeros.
    private static func copy(_ file: FoundFile, from source: ByteSource, to url: URL, buffer: UnsafeMutableRawBufferPointer, progress: ExportProgress) throws -> UInt64 {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var lost: UInt64 = 0
        for extent in file.extents {
            var position = extent.offset
            while position < extent.end {
                let count = Int(min(UInt64(buffer.count), extent.end - position))
                let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
                let got: Int
                do {
                    got = try source.read(into: slice, at: position)
                } catch .disconnected {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The disk was disconnected."])
                } catch {
                    slice.initializeMemory(as: UInt8.self, repeating: 0)
                    lost += UInt64(count)
                    got = count
                }
                guard got > 0 else { break }
                try handle.write(contentsOf: Data(bytesNoCopy: slice.baseAddress!, count: got, deallocator: .none))
                position += UInt64(got)
                progress.copied(got)
            }
        }
        return lost
    }

    /// Names safe for any file system: no slashes or colons, not hidden.
    static func safe(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// `name 2.ext`, `name 3.ext`… when the name is taken.
    static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for number in 2... {
            let candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
