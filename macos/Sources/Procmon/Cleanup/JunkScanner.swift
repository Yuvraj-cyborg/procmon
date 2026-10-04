// Finds and measures what Clean Up can remove from disk, and removes it.

import Darwin
import Foundation

enum JunkScanner {
    /// Where to look. Tests point it at a temporary folder.
    struct Places: Sendable {
        let home: String
        let temporary: String

        static var current: Places {
            Places(home: NSHomeDirectory(), temporary: (NSTemporaryDirectory() as NSString).standardizingPath)
        }

        var caches: String { home + "/Library/Caches" }
        var logs: String { home + "/Library/Logs" }
        var trash: String { home + "/.Trash" }
    }

    /// Everything removable right now, largest groups first. Reads only;
    /// slow for big caches, so call it off the main thread.
    static func scan(_ places: Places, running: RunningSet, now: Date = Date()) -> [JunkGroup] {
        var groups: [JunkGroup] = []

        // App caches: each folder directly inside ~/Library/Caches.
        let caches = entries(of: places.caches).compactMap { name -> JunkItem? in
            let path = places.caches + "/" + name
            let usage = DiskUsage.measure(path)
            guard usage.size > 0, CleanupRules.isRemovableCache(named: name, running: running, newest: usage.newest, now: now) else {
                return nil
            }
            return JunkItem(
                path: path, name: CleanupRules.knownCacheNames[name.lowercased()] ?? name, size: Bytes(usage.size),
                kind: .appCaches, root: places.caches, blockedBy: [name.lowercased()]
            )
        }
        groups.append(JunkGroup(kind: .appCaches, items: caches))

        // Developer caches: whole folders at known places.
        let developer = CleanupRules.developerCaches.compactMap { cache -> JunkItem? in
            let path = places.home + "/" + cache.path
            guard !running.isRunning(anyOf: cache.blockedBy) else { return nil }
            let usage = DiskUsage.measure(path)
            guard usage.size > 0, now.timeIntervalSince(usage.newest) >= CleanupRules.inUseWindow else { return nil }
            return JunkItem(path: path, name: cache.label, size: Bytes(usage.size), kind: .developerCaches, root: places.home, blockedBy: cache.blockedBy)
        }
        groups.append(JunkGroup(kind: .developerCaches, items: developer))

        // Logs: individual old files anywhere under ~/Library/Logs.
        var logs: [JunkItem] = []
        DiskUsage.walkFiles(places.logs) { path, size, modified in
            if CleanupRules.isOldLog(newest: modified, now: now) {
                logs.append(JunkItem(
                    path: path, name: (path as NSString).lastPathComponent, size: Bytes(size),
                    kind: .logs, root: places.logs, blockedBy: []
                ))
            }
        }
        groups.append(JunkGroup(kind: .logs, items: logs.sorted { $0.size > $1.size }))

        // Temporary files: top-level entries whose newest content is old.
        let temporary = entries(of: places.temporary).compactMap { name -> JunkItem? in
            let path = places.temporary + "/" + name
            let usage = DiskUsage.measure(path)
            guard usage.size > 0, CleanupRules.isStaleTemporary(named: name, newest: usage.newest, now: now) else { return nil }
            return JunkItem(path: path, name: name, size: Bytes(usage.size), kind: .temporaryFiles, root: places.temporary, blockedBy: [])
        }
        groups.append(JunkGroup(kind: .temporaryFiles, items: temporary))

        // Trash: everything, but never selected by default. Reading it needs
        // Full Disk Access; without it the folder cannot even be listed.
        let trashListing = try? FileManager.default.contentsOfDirectory(atPath: places.trash)
        let trash = (trashListing ?? []).compactMap { name -> JunkItem? in
            let path = places.trash + "/" + name
            let usage = DiskUsage.measure(path)
            guard usage.size > 0 else { return nil }
            return JunkItem(path: path, name: name, size: Bytes(usage.size), kind: .trash, root: places.trash, blockedBy: [])
        }
        groups.append(JunkGroup(
            kind: .trash, items: trash,
            isUnreadable: trashListing == nil && FileManager.default.fileExists(atPath: places.trash)
        ))

        return groups.map { JunkGroup(kind: $0.kind, items: $0.items.sorted { $0.size > $1.size }, isUnreadable: $0.isUnreadable) }
    }

    /// Removes `items`, checking each again first: it must still be inside its
    /// folder, and nothing that blocks it may have started since the scan.
    static func remove(_ items: [JunkItem], running: RunningSet) -> (freed: Bytes, removed: Int, skipped: Int) {
        var freed = Bytes.zero
        var removed = 0
        var skipped = 0
        for item in items {
            guard CleanupRules.isInside(item.path, root: item.root), !running.isRunning(anyOf: item.blockedBy) else {
                skipped += 1
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: item.path)
                freed += item.size
                removed += 1
            } catch {
                skipped += 1
            }
        }
        return (freed, removed, skipped)
    }

    private static func entries(of folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }
}

/// Allocated size and newest modification under a path, without following
/// symlinks or building a tree.
enum DiskUsage {
    static func measure(_ path: String) -> (size: UInt64, newest: Date) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return (0, .distantPast) }
        var size = UInt64(max(info.st_blocks, 0)) * 512
        var newest = info.st_mtimespec.tv_sec
        if info.st_mode & S_IFMT == S_IFDIR {
            bulkWalk(path, device: info.st_dev) { bytes, modified in
                size += bytes
                newest = max(newest, modified)
            }
        }
        return (size, Date(timeIntervalSince1970: Double(newest)))
    }

    /// Entries read per `getattrlistbulk` call fit in this many bytes.
    private static let bulkBuffer = 64 * 1024

    /// Depth-first over one filesystem, reading each directory's entries and
    /// their sizes in a few `getattrlistbulk` calls instead of one `stat` per
    /// file, and making strings only for the directories it descends into.
    /// About a third less kernel time than `readdir` and `fstatat`.
    private static func bulkWalk(_ root: String, device: dev_t, visit: (_ bytes: UInt64, _ modified: time_t) -> Void) {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(bitPattern: ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkBuffer, alignment: 16)
        defer { buffer.deallocate() }
        var stack = [root]
        while let directory = stack.popLast() {
            let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            while true {
                let count = getattrlistbulk(descriptor, &request, buffer, bulkBuffer, 0)
                guard count > 0 else { break }
                var entry = UnsafeRawPointer(buffer)
                for _ in 0..<count {
                    // Fields follow in attribute-bit order, and only those
                    // the filesystem returned are present.
                    let length = Int(entry.loadUnaligned(as: UInt32.self))
                    var field = entry.advanced(by: 4)
                    let returned = field.loadUnaligned(as: attribute_set_t.self)
                    field = field.advanced(by: MemoryLayout<attribute_set_t>.size)
                    var name: UnsafeRawBufferPointer?
                    if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                        let reference = field.loadUnaligned(as: attrreference_t.self)
                        // The length counts the terminating NUL.
                        name = UnsafeRawBufferPointer(start: field.advanced(by: Int(reference.attr_dataoffset)), count: max(Int(reference.attr_length) - 1, 0))
                        field = field.advanced(by: MemoryLayout<attrreference_t>.size)
                    }
                    var entryDevice = device
                    if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                        entryDevice = field.loadUnaligned(as: dev_t.self)
                        field = field.advanced(by: MemoryLayout<dev_t>.size)
                    }
                    var type: fsobj_type_t = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                        type = field.loadUnaligned(as: fsobj_type_t.self)
                        field = field.advanced(by: MemoryLayout<fsobj_type_t>.size)
                    }
                    var modified: time_t = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                        modified = field.loadUnaligned(as: timespec.self).tv_sec
                        field = field.advanced(by: MemoryLayout<timespec>.size)
                    }
                    var bytes: UInt64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        bytes = UInt64(max(field.loadUnaligned(as: off_t.self), 0))
                    }
                    entry = entry.advanced(by: length)
                    // Symlinks are neither followed nor counted.
                    guard type != fsobj_type_t(VLNK.rawValue) else { continue }
                    visit(bytes, modified)
                    if type == fsobj_type_t(VDIR.rawValue), entryDevice == device, let name {
                        stack.append(directory + "/" + String(decoding: name, as: UTF8.self))
                    }
                }
            }
        }
    }

    /// Calls `visit` for every regular file below `path`.
    static func walkFiles(_ path: String, visit: (String, UInt64, Date) -> Void) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        walk(path, device: info.st_dev) { entry, info in
            guard info.st_mode & S_IFMT == S_IFREG else { return }
            visit(entry, UInt64(max(info.st_blocks, 0)) * 512, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)))
        }
    }

    private static let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!

    /// Depth-first over one filesystem, skipping symlinks.
    private static func walk(_ root: String, device: dev_t, visit: (String, stat) -> Void) {
        var stack = [root]
        while let directory = stack.popLast() {
            guard let handle = opendir(directory) else { continue }
            defer { closedir(handle) }
            let descriptor = dirfd(handle)
            while let entry = readdir(handle) {
                let name = UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
                let length = Int(entry.pointee.d_namlen)
                if (length == 1 && name[0] == 0x2E) || (length == 2 && name[0] == 0x2E && name[1] == 0x2E) { continue }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let kind = info.st_mode & S_IFMT
                guard kind != S_IFLNK else { continue }
                let path = directory + "/" + String(decoding: UnsafeRawBufferPointer(start: name, count: length), as: UTF8.self)
                visit(path, info)
                if kind == S_IFDIR, info.st_dev == device {
                    stack.append(path)
                }
            }
        }
    }
}
