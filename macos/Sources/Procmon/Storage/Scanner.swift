// Parallel disk-usage scan.
//
// A fixed pool of workers pulls directories off a shared stack, lists them
// with `readdir` + `fstatat`, and pushes the subdirectories they find. The
// flat results are rolled up into a ``FileTree`` once every worker is idle.

import Darwin
import Foundation
import Synchronization

/// Live counters shared between the scanning threads and the UI.
final class ScanProgress: Sendable {
    private let fileCount = Atomic<UInt64>(0)
    private let byteCount = Atomic<UInt64>(0)
    private let cancelled = Atomic<Bool>(false)

    var files: UInt64 { fileCount.load(ordering: .relaxed) }
    var bytes: Bytes { Bytes(byteCount.load(ordering: .relaxed)) }
    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    func cancel() { cancelled.store(true, ordering: .relaxed) }

    fileprivate func add(files: UInt64, bytes: UInt64) {
        fileCount.add(files, ordering: .relaxed)
        byteCount.add(bytes, ordering: .relaxed)
    }
}

enum ScanError: Error, Equatable, CustomStringConvertible {
    case cancelled
    case notADirectory
    case unreadable(errno: Int32)

    var description: String {
        switch self {
        case .cancelled: "The scan was cancelled."
        case .notADirectory: "It is not a folder."
        case .unreadable(let code): String(cString: strerror(code))
        }
    }
}

enum Scanner {
    /// Folders keep this many of their largest files as individual nodes; the
    /// rest are folded into one "smaller files" node so huge trees stay light.
    static let filesPerFolder = 64
    /// Files at least this large are never folded, so they always show up in
    /// the map and the largest-files list.
    static let alwaysKeep: UInt64 = 16 * 1024 * 1024
    /// `st_blocks` is always counted in 512-byte units.
    private static let blockSize: UInt64 = 512

    /// Measures everything under `root` without crossing into other
    /// filesystems or following symlinks. Sizes are allocated blocks, so sparse
    /// and cloned files are counted the way the disk sees them; hard links are
    /// counted once.
    static func scan(root: String, progress: ScanProgress) throws(ScanError) -> FileTree {
        var info = stat()
        // The root may itself be a symlink (e.g. /tmp); entries below it are not followed.
        guard stat(root, &info) == 0 else { throw .unreadable(errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw .notADirectory }

        let work = WorkQueue(root: Directory(name: root, parent: nil, ownSize: blocks(info)), path: root)
        let context = Context(device: info.st_dev, progress: progress)
        let workers = max(2, Foundation.ProcessInfo.processInfo.activeProcessorCount)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while let job = work.next() {
                let listing = progress.isCancelled ? Listing() : list(job.path, context: context)
                work.complete(job, with: listing)
            }
        }
        if progress.isCancelled { throw .cancelled }
        var tree = assemble(work.directories, rootPath: root)
        tree.unreadable = context.unreadable.load(ordering: .relaxed)
        return tree
    }

    private static func blocks(_ info: stat) -> UInt64 {
        UInt64(max(info.st_blocks, 0)) * blockSize
    }

    // MARK: Listing one directory

    fileprivate struct FileEntry {
        let name: String
        let size: UInt64
    }

    fileprivate struct Listing {
        var files: [FileEntry] = []
        /// Files folded into one "smaller files" entry.
        var folded: (count: UInt64, size: UInt64)?
        var directories: [(name: String, size: UInt64)] = []
    }

    fileprivate struct HardLink: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    fileprivate final class Context: Sendable {
        let device: dev_t
        let progress: ScanProgress
        let hardLinks = Mutex<Set<HardLink>>([])
        let unreadable = Atomic<UInt64>(0)

        init(device: dev_t, progress: ScanProgress) {
            self.device = device
            self.progress = progress
        }
    }

    private static let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!

    private static func list(_ path: String, context: Context) -> Listing {
        guard let handle = opendir(path) else {
            context.unreadable.add(1, ordering: .relaxed)
            return Listing()
        }
        defer { closedir(handle) }
        let descriptor = dirfd(handle)

        var listing = Listing()
        var bytes: UInt64 = 0
        while let entry = readdir(handle) {
            let namePointer = UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
            let length = Int(entry.pointee.d_namlen)
            if (length == 1 && namePointer[0] == 0x2E) || (length == 2 && namePointer[0] == 0x2E && namePointer[1] == 0x2E) {
                continue
            }
            var info = stat()
            guard fstatat(descriptor, namePointer, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK { continue }
            let name = String(decoding: UnsafeRawBufferPointer(start: namePointer, count: length), as: UTF8.self)
            let size = blocks(info)
            if kind == S_IFDIR {
                if info.st_dev == context.device {
                    listing.directories.append((name, size))
                }
                continue
            }
            if info.st_nlink > 1 {
                let link = HardLink(device: info.st_dev, inode: info.st_ino)
                guard context.hardLinks.withLock({ $0.insert(link).inserted }) else { continue }
            }
            bytes += size
            listing.files.append(FileEntry(name: name, size: size))
        }
        context.progress.add(files: UInt64(listing.files.count), bytes: bytes)

        listing.files.sort { $0.size > $1.size }
        let large = listing.files.prefix { $0.size >= alwaysKeep }.count
        let keep = max(filesPerFolder, large)
        if listing.files.count > keep {
            let tail = listing.files[keep...]
            listing.folded = (UInt64(tail.count), tail.reduce(0) { $0 + $1.size })
            listing.files.removeSubrange(keep...)
        }
        return listing
    }

    // MARK: Assembling the tree

    fileprivate struct Directory {
        let name: String
        let parent: Int?
        let ownSize: UInt64
        var files: [FileEntry] = []
        var folded: (count: UInt64, size: UInt64)?
        var subdirectories: [Int] = []
    }

    /// Rolls sizes up and lays the result out as an arena, largest first.
    private static func assemble(_ directories: [Directory], rootPath: String) -> FileTree {
        // Subdirectories are always recorded after their parent, so walking
        // backwards visits every child before its parent.
        var sizes = [UInt64](repeating: 0, count: directories.count)
        var counts = [UInt64](repeating: 0, count: directories.count)
        for index in directories.indices.reversed() {
            let directory = directories[index]
            var size = directory.ownSize + directory.files.reduce(0) { $0 + $1.size } + (directory.folded?.size ?? 0)
            var count = UInt64(directory.files.count) + (directory.folded?.count ?? 0)
            for child in directory.subdirectories {
                size += sizes[child]
                count += counts[child]
            }
            sizes[index] = size
            counts[index] = count
        }

        var tree = FileTree(rootPath: rootPath, root: FileNode(
            name: rootPath, size: Bytes(sizes[0]), category: .folder, files: counts[0], parent: nil, children: []
        ))
        var queue: [(node: NodeID, directory: Int)] = [(.root, 0)]
        var cursor = 0
        while cursor < queue.count {
            let (node, index) = queue[cursor]
            cursor += 1
            let directory = directories[index]

            enum Child {
                case folder(Int)
                case file(FileEntry)
                case folded(count: UInt64, size: UInt64)

                func size(_ sizes: [UInt64]) -> UInt64 {
                    switch self {
                    case .folder(let index): sizes[index]
                    case .file(let entry): entry.size
                    case .folded(_, let size): size
                    }
                }
            }
            var children: [Child] = directory.subdirectories.map(Child.folder) + directory.files.map(Child.file)
            if let folded = directory.folded {
                children.append(.folded(count: folded.count, size: folded.size))
            }
            children.sort { $0.size(sizes) > $1.size(sizes) }

            var ids: [NodeID] = []
            ids.reserveCapacity(children.count)
            for child in children {
                switch child {
                case .folder(let childIndex):
                    let name = directories[childIndex].name
                    let id = tree.append(FileNode(
                        name: name, size: Bytes(sizes[childIndex]), category: .classify(name: name, isDirectory: true),
                        files: counts[childIndex], parent: node, children: []
                    ))
                    queue.append((id, childIndex))
                    ids.append(id)
                case .file(let entry):
                    ids.append(tree.append(FileNode(
                        name: entry.name, size: Bytes(entry.size), category: .classify(name: entry.name, isDirectory: false),
                        files: 1, parent: node, children: []
                    )))
                case .folded(let count, let size):
                    ids.append(tree.append(FileNode(
                        name: "\(count) smaller files", size: Bytes(size), category: .remainder,
                        files: count, parent: node, children: []
                    )))
                }
            }
            tree[node].children = ids
        }
        return tree
    }

    // MARK: Work distribution

    fileprivate struct Job: Sendable {
        let index: Int
        let path: String
    }

    /// A stack of directories to list, shared by the workers. `next()` blocks
    /// until there is work or every worker is idle with nothing left to do.
    fileprivate final class WorkQueue: @unchecked Sendable {
        // Guarded by `condition`.
        private let condition = NSCondition()
        private var pending: [Job]
        private var active = 0
        private(set) var directories: [Directory]

        init(root: Directory, path: String) {
            directories = [root]
            pending = [Job(index: 0, path: path)]
        }

        func next() -> Job? {
            condition.lock()
            defer { condition.unlock() }
            while pending.isEmpty && active > 0 {
                condition.wait()
            }
            guard let job = pending.popLast() else {
                condition.broadcast()
                return nil
            }
            active += 1
            return job
        }

        func complete(_ job: Job, with listing: Listing) {
            let separator = job.path.hasSuffix("/") ? "" : "/"
            condition.lock()
            defer { condition.unlock() }
            directories[job.index].files = listing.files
            directories[job.index].folded = listing.folded
            for (name, size) in listing.directories {
                let index = directories.count
                directories.append(Directory(name: name, parent: job.index, ownSize: size))
                directories[job.index].subdirectories.append(index)
                pending.append(Job(index: index, path: job.path + separator + name))
            }
            active -= 1
            condition.broadcast()
        }
    }
}
