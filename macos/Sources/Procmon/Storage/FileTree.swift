// A scanned directory hierarchy stored as a compact arena.
//
// A home folder easily holds a million nodes, so each one is a 32-byte record:
// names live in one shared UTF-8 buffer, and a node's children are a range of
// consecutive records (the scanner lays siblings out together). Only folders
// edited after the scan, by moving something to the Trash, keep an explicit
// child list.

import Foundation

/// Index of a node inside a ``FileTree``.
struct NodeID: Hashable, Sendable {
    fileprivate let index: Int32

    static let root = NodeID(index: 0)
}

/// Broad file type, used for colouring and the legend.
enum FileCategory: UInt8, Sendable, CaseIterable {
    case folder, application, image, video, audio, archive, document, code
    /// Synthetic bucket for the many small files folded together per folder.
    case remainder
    case other

    static let legend: [FileCategory] = [.folder, .application, .image, .video, .audio, .archive, .document, .code]

    var label: String {
        switch self {
        case .folder: "Folders"
        case .application: "Apps"
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .archive: "Archives"
        case .document: "Documents"
        case .code: "Code"
        case .remainder: "Small files"
        case .other: "Other"
        }
    }

    /// Classifies a directory entry by its name.
    static func classify(name: String, isDirectory: Bool) -> FileCategory {
        classify(utf8: Array(name.utf8)[...], isDirectory: isDirectory)
    }

    /// Classifies raw UTF-8 name bytes, so the scanner never builds a String
    /// for every file.
    static func classify(utf8 name: ArraySlice<UInt8>, isDirectory: Bool) -> FileCategory {
        // Extensions longer than this are not ones we recognise.
        let longest = 7
        guard let dot = name.lastIndex(of: 0x2E), name.endIndex - dot - 1 <= longest else {
            return isDirectory ? .folder : .other
        }
        let ext = String(decoding: name[(dot + 1)...].map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
        if isDirectory {
            return ext == "app" ? .application : .folder
        }
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg", "raw", "psd": return .image
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": return .video
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff": return .audio
        case "zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "rar", "dmg", "iso", "pkg": return .archive
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "md", "rtf",
             "csv", "epub": return .document
        case "rs", "js", "ts", "tsx", "py", "go", "c", "h", "cpp", "swift", "java", "kt", "rb", "json", "toml",
             "yaml", "yml", "rlib", "o", "a", "so", "dylib", "wasm": return .code
        default: return .other
        }
    }
}

/// A read-only view of one node. Cheap to make; the name is decoded on demand.
struct FileNode: Sendable {
    let name: String
    /// Allocated size on disk, including everything below this node.
    let size: Bytes
    let category: FileCategory
    /// Number of files at or below this node.
    let files: UInt64
    let parent: NodeID?
    let isContainer: Bool
}

/// A node's children, largest first, without allocating for the common case.
struct FileChildren: RandomAccessCollection, Sendable {
    fileprivate enum Storage: Sendable {
        case range(Range<Int32>)
        case list([NodeID])
    }

    fileprivate let storage: Storage

    var startIndex: Int { 0 }

    var endIndex: Int {
        switch storage {
        case .range(let range): range.count
        case .list(let list): list.count
        }
    }

    subscript(position: Int) -> NodeID {
        switch storage {
        case .range(let range): NodeID(index: range.lowerBound + Int32(position))
        case .list(let list): list[position]
        }
    }
}

struct FileTree: Sendable {
    /// One node, packed into 32 bytes.
    private struct Record: Sendable {
        var size: UInt64
        var files: UInt32
        let nameStart: UInt32
        let parent: Int32
        var firstChild: Int32
        var childCount: Int32
        let nameLength: UInt16
        let category: FileCategory
    }

    let rootPath: String
    private var records: [Record] = []
    private var names: [UInt8] = []
    /// Child lists that no longer match the scanned layout.
    private var edited: [Int32: [NodeID]] = [:]
    /// Directories that could not be read (privacy settings, races).
    var unreadable: UInt64 = 0
    /// Protected folders deliberately left out, so macOS never had to ask.
    var skipped = 0

    init(rootPath: String, rootSize: Bytes, rootFiles: UInt64) {
        self.rootPath = rootPath
        _ = append(name: Array(rootPath.utf8)[...], size: rootSize, category: .folder, files: rootFiles, parent: nil)
    }

    var count: Int { records.count }

    /// Sizes the storage up front, so building never over-allocates by
    /// doubling: for a million nodes that is tens of megabytes.
    mutating func reserve(nodes: Int, nameBytes: Int) {
        records.reserveCapacity(nodes)
        names.reserveCapacity(nameBytes)
    }

    /// Whether `id` belongs to this tree.
    func contains(_ id: NodeID) -> Bool {
        id.index >= 0 && Int(id.index) < records.count
    }

    // MARK: Building

    /// Adds a node and returns its id. Children are attached afterwards with
    /// ``setChildren(_:of:)``.
    mutating func append(name: ArraySlice<UInt8>, size: Bytes, category: FileCategory, files: UInt64, parent: NodeID?) -> NodeID {
        precondition(records.count < Int(Int32.max), "more than 2 billion nodes")
        let start = UInt32(clamping: names.count)
        let length = min(name.count, Int(UInt16.max))
        names.append(contentsOf: name.prefix(length))
        records.append(Record(
            size: size.value,
            files: UInt32(clamping: files),
            nameStart: start,
            parent: parent?.index ?? -1,
            firstChild: 0,
            childCount: 0,
            nameLength: UInt16(length),
            category: category
        ))
        return NodeID(index: Int32(records.count - 1))
    }

    mutating func append(name: String, size: Bytes, category: FileCategory, files: UInt64, parent: NodeID?) -> NodeID {
        append(name: Array(name.utf8)[...], size: size, category: category, files: files, parent: parent)
    }

    /// Sets `parent`'s children, largest first. Consecutive ids, which the
    /// scanner always produces, are stored as a plain range.
    mutating func setChildren(_ children: [NodeID], of parent: NodeID) {
        guard let first = children.first else {
            records[Int(parent.index)].childCount = 0
            edited[parent.index] = nil
            return
        }
        let isRange = children.indices.dropFirst().allSatisfy { children[$0].index == children[$0 - 1].index + 1 }
        if isRange {
            records[Int(parent.index)].firstChild = first.index
            records[Int(parent.index)].childCount = Int32(children.count)
            edited[parent.index] = nil
        } else {
            records[Int(parent.index)].childCount = Int32(children.count)
            edited[parent.index] = children
        }
    }

    // MARK: Reading

    subscript(id: NodeID) -> FileNode {
        let record = records[Int(id.index)]
        return FileNode(
            name: name(of: id),
            size: Bytes(record.size),
            category: record.category,
            files: UInt64(record.files),
            parent: record.parent < 0 ? nil : NodeID(index: record.parent),
            isContainer: record.childCount > 0
        )
    }

    func name(of id: NodeID) -> String {
        let record = records[Int(id.index)]
        let start = Int(record.nameStart)
        return String(decoding: names[start..<(start + Int(record.nameLength))], as: UTF8.self)
    }

    func size(of id: NodeID) -> Bytes { Bytes(records[Int(id.index)].size) }

    func category(of id: NodeID) -> FileCategory { records[Int(id.index)].category }

    func parent(of id: NodeID) -> NodeID? {
        let parent = records[Int(id.index)].parent
        return parent < 0 ? nil : NodeID(index: parent)
    }

    func isContainer(_ id: NodeID) -> Bool { records[Int(id.index)].childCount > 0 }

    func children(of id: NodeID) -> FileChildren {
        if let list = edited[id.index] {
            return FileChildren(storage: .list(list))
        }
        let record = records[Int(id.index)]
        return FileChildren(storage: .range(record.firstChild..<(record.firstChild + record.childCount)))
    }

    /// Path from the root down to `id`, inclusive.
    func lineage(_ id: NodeID) -> [NodeID] {
        var chain = [id]
        var cursor = id
        while let parent = parent(of: cursor) {
            chain.append(parent)
            cursor = parent
        }
        return chain.reversed()
    }

    /// The `limit` largest individual files in the whole tree, largest first.
    func largestFiles(limit: Int) -> [NodeID] {
        // Walk from the root rather than over the arena: removed nodes stay in
        // the arena but are no longer reachable.
        var files: [NodeID] = []
        var stack = [NodeID.root]
        while let id = stack.popLast() {
            let record = records[Int(id.index)]
            if record.childCount == 0 {
                if record.category != .folder && record.category != .remainder {
                    files.append(id)
                }
            } else {
                stack.append(contentsOf: children(of: id))
            }
        }
        return Array(files.sorted { size(of: $0) > size(of: $1) }.prefix(limit))
    }

    /// Unlinks `id` after it was deleted on disk, subtracting its size and
    /// file count from every ancestor and keeping siblings sorted by size.
    mutating func remove(_ id: NodeID) {
        guard let parent = parent(of: id) else { return }
        let removed = records[Int(id.index)]
        setChildren(children(of: parent).filter { $0 != id }, of: parent)

        var cursor: NodeID? = parent
        while let ancestor = cursor {
            let index = Int(ancestor.index)
            records[index].size -= min(records[index].size, removed.size)
            records[index].files -= min(records[index].files, removed.files)
            cursor = self.parent(of: ancestor)
            if let grandparent = cursor {
                let siblings = children(of: grandparent).sorted { size(of: $0) > size(of: $1) }
                setChildren(siblings, of: grandparent)
            }
        }
    }

    /// Filesystem path of a node, or `nil` for synthetic nodes.
    func path(of id: NodeID) -> String? {
        let lineage = lineage(id)
        guard !lineage.contains(where: { category(of: $0) == .remainder }) else { return nil }
        return lineage.dropFirst().reduce(rootPath) { path, node in
            (path as NSString).appendingPathComponent(name(of: node))
        }
    }

    /// Display name for a node: the root shows its folder name.
    func title(of id: NodeID) -> String {
        guard id == .root else { return name(of: id) }
        let last = (rootPath as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? rootPath : last
    }
}
