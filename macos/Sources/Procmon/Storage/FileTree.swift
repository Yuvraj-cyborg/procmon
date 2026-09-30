// A scanned directory hierarchy stored as a flat arena.

import Foundation

/// Index of a ``FileNode`` inside a ``FileTree``.
struct NodeID: Hashable, Sendable {
    fileprivate let index: Int32

    static let root = NodeID(index: 0)
}

/// Broad file type, used for colouring and the legend.
enum FileCategory: Sendable, CaseIterable {
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
        let ext = name.lastIndex(of: ".").map { name[name.index(after: $0)...].lowercased() } ?? ""
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

struct FileNode: Sendable {
    let name: String
    /// Allocated size on disk, including everything below this node.
    var size: Bytes
    let category: FileCategory
    /// Number of files at or below this node.
    var files: UInt64
    let parent: NodeID?
    /// Sorted by size, largest first.
    var children: [NodeID]

    var isContainer: Bool { !children.isEmpty }
}

struct FileTree: Sendable {
    let rootPath: String
    private var nodes: [FileNode]
    /// Directories that could not be read (privacy settings, races).
    var unreadable: UInt64 = 0

    init(rootPath: String, root: FileNode) {
        self.rootPath = rootPath
        nodes = [root]
    }

    var count: Int { nodes.count }

    /// Whether `id` belongs to this tree's arena.
    func contains(_ id: NodeID) -> Bool {
        id.index >= 0 && Int(id.index) < nodes.count
    }

    subscript(id: NodeID) -> FileNode {
        get { nodes[Int(id.index)] }
        set { nodes[Int(id.index)] = newValue }
    }

    mutating func append(_ node: FileNode) -> NodeID {
        precondition(nodes.count < Int(Int32.max), "more than 2 billion nodes")
        nodes.append(node)
        return NodeID(index: Int32(nodes.count - 1))
    }

    /// Path from the root down to `id`, inclusive.
    func lineage(_ id: NodeID) -> [NodeID] {
        var chain = [id]
        var cursor = id
        while let parent = self[cursor].parent {
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
            let node = self[id]
            if node.children.isEmpty {
                if node.category != .folder && node.category != .remainder {
                    files.append(id)
                }
            } else {
                stack.append(contentsOf: node.children)
            }
        }
        return Array(files.sorted { self[$0].size > self[$1].size }.prefix(limit))
    }

    /// Unlinks `id` after it was deleted on disk, subtracting its size and
    /// file count from every ancestor and keeping siblings sorted by size.
    mutating func remove(_ id: NodeID) {
        guard let parent = self[id].parent else { return }
        let (size, files) = (self[id].size, self[id].files)
        self[parent].children.removeAll { $0 == id }

        var cursor: NodeID? = parent
        while let ancestor = cursor {
            self[ancestor].size = self[ancestor].size - size
            self[ancestor].files = self[ancestor].files > files ? self[ancestor].files - files : 0
            cursor = self[ancestor].parent
            if let grandparent = cursor {
                let siblings = self[grandparent].children.sorted { self[$0].size > self[$1].size }
                self[grandparent].children = siblings
            }
        }
    }

    /// Filesystem path of a node, or `nil` for synthetic nodes.
    func path(of id: NodeID) -> String? {
        let lineage = lineage(id)
        guard !lineage.contains(where: { self[$0].category == .remainder }) else { return nil }
        return lineage.dropFirst().reduce(rootPath) { path, node in
            (path as NSString).appendingPathComponent(self[node].name)
        }
    }

    /// Display name for a node: the root shows its folder name.
    func title(of id: NodeID) -> String {
        guard id == .root else { return self[id].name }
        let last = (rootPath as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? rootPath : last
    }
}
