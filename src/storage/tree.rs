use std::path::{Path, PathBuf};

use crate::units::Bytes;

/// Index of a [`Node`] inside a [`FileTree`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId(u32);

impl NodeId {
    pub const ROOT: NodeId = NodeId(0);

    fn index(self) -> usize {
        self.0 as usize
    }

    /// Stable integer for keying UI elements.
    pub fn as_usize(self) -> usize {
        self.index()
    }
}

/// Broad file type, used for colouring and the legend.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Category {
    Folder,
    Application,
    Image,
    Video,
    Audio,
    Archive,
    Document,
    Code,
    /// Synthetic bucket for the many small files folded together per folder.
    Remainder,
    Other,
}

impl Category {
    pub const LEGEND: [Category; 8] = [
        Category::Folder,
        Category::Application,
        Category::Image,
        Category::Video,
        Category::Audio,
        Category::Archive,
        Category::Document,
        Category::Code,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Category::Folder => "Folders",
            Category::Application => "Apps",
            Category::Image => "Images",
            Category::Video => "Video",
            Category::Audio => "Audio",
            Category::Archive => "Archives",
            Category::Document => "Documents",
            Category::Code => "Code",
            Category::Remainder => "Small files",
            Category::Other => "Other",
        }
    }

    /// Classifies a directory entry by its name.
    pub fn classify(name: &str, is_dir: bool) -> Category {
        let ext = name
            .rsplit_once('.')
            .map(|(_, ext)| ext.to_ascii_lowercase())
            .unwrap_or_default();
        if is_dir {
            return match ext.as_str() {
                "app" => Category::Application,
                _ => Category::Folder,
            };
        }
        match ext.as_str() {
            "png" | "jpg" | "jpeg" | "gif" | "heic" | "webp" | "tiff" | "bmp" | "svg" | "raw"
            | "psd" => Category::Image,
            "mp4" | "mov" | "mkv" | "avi" | "webm" | "m4v" => Category::Video,
            "mp3" | "wav" | "flac" | "aac" | "m4a" | "ogg" | "aiff" => Category::Audio,
            "zip" | "tar" | "gz" | "tgz" | "xz" | "bz2" | "7z" | "rar" | "dmg" | "iso" | "pkg" => {
                Category::Archive
            }
            "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "pages" | "numbers"
            | "key" | "txt" | "md" | "rtf" | "csv" | "epub" => Category::Document,
            "rs" | "js" | "ts" | "tsx" | "py" | "go" | "c" | "h" | "cpp" | "swift" | "java"
            | "kt" | "rb" | "json" | "toml" | "yaml" | "yml" | "rlib" | "o" | "a" | "so"
            | "dylib" | "wasm" => Category::Code,
            _ => Category::Other,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Node {
    pub name: Box<str>,
    /// Allocated size on disk, including everything below this node.
    pub size: Bytes,
    pub category: Category,
    /// Number of files at or below this node.
    pub files: u64,
    pub parent: Option<NodeId>,
    /// Sorted by size, largest first.
    pub children: Vec<NodeId>,
}

impl Node {
    pub fn is_container(&self) -> bool {
        !self.children.is_empty()
    }
}

/// A scanned directory hierarchy stored as a flat arena.
#[derive(Debug, Clone)]
pub struct FileTree {
    root_path: PathBuf,
    nodes: Vec<Node>,
    /// Directories that could not be read (permissions, races).
    pub unreadable: u64,
}

impl FileTree {
    pub(super) fn with_root(root_path: PathBuf, root: Node) -> Self {
        Self {
            root_path,
            nodes: vec![root],
            unreadable: 0,
        }
    }

    pub(super) fn push(&mut self, node: Node) -> NodeId {
        let id = NodeId(u32::try_from(self.nodes.len()).expect("more than 4 billion nodes"));
        self.nodes.push(node);
        id
    }

    pub(super) fn node_mut(&mut self, id: NodeId) -> &mut Node {
        &mut self.nodes[id.index()]
    }

    pub fn node(&self, id: NodeId) -> &Node {
        &self.nodes[id.index()]
    }

    pub fn root_path(&self) -> &Path {
        &self.root_path
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    /// Path from the root down to `id`, inclusive.
    pub fn lineage(&self, id: NodeId) -> Vec<NodeId> {
        let mut chain = vec![id];
        let mut cursor = id;
        while let Some(parent) = self.node(cursor).parent {
            chain.push(parent);
            cursor = parent;
        }
        chain.reverse();
        chain
    }

    /// The `limit` largest individual files in the whole tree, largest first.
    pub fn largest_files(&self, limit: usize) -> Vec<NodeId> {
        // Walk from the root rather than over the arena: removed nodes stay in
        // the arena but are no longer reachable.
        let mut files = Vec::new();
        let mut stack = vec![NodeId::ROOT];
        while let Some(id) = stack.pop() {
            let node = self.node(id);
            if node.children.is_empty() {
                if !matches!(node.category, Category::Folder | Category::Remainder) {
                    files.push(id);
                }
            } else {
                stack.extend_from_slice(&node.children);
            }
        }
        let by_size = |a: &NodeId, b: &NodeId| self.node(*b).size.cmp(&self.node(*a).size);
        if files.len() > limit {
            files.select_nth_unstable_by(limit, by_size);
            files.truncate(limit);
        }
        files.sort_unstable_by(by_size);
        files
    }

    /// Unlinks `id` after it was deleted on disk, subtracting its size and
    /// file count from every ancestor and keeping siblings sorted by size.
    pub fn remove(&mut self, id: NodeId) {
        let Some(parent) = self.node(id).parent else {
            return;
        };
        let (size, files) = (self.node(id).size, self.node(id).files);
        self.node_mut(parent).children.retain(|child| *child != id);

        let mut cursor = Some(parent);
        while let Some(ancestor) = cursor {
            let node = self.node_mut(ancestor);
            node.size = node.size - size;
            node.files = node.files.saturating_sub(files);
            cursor = node.parent;
            if let Some(grandparent) = cursor {
                let mut siblings = std::mem::take(&mut self.node_mut(grandparent).children);
                siblings.sort_by_key(|id| std::cmp::Reverse(self.node(*id).size));
                self.node_mut(grandparent).children = siblings;
            }
        }
    }

    /// Filesystem path of a node, or `None` for synthetic nodes.
    pub fn path_of(&self, id: NodeId) -> Option<PathBuf> {
        let lineage = self.lineage(id);
        if lineage
            .iter()
            .any(|n| self.node(*n).category == Category::Remainder)
        {
            return None;
        }
        let mut path = self.root_path.clone();
        for node in lineage.into_iter().skip(1) {
            path.push(&*self.node(node).name);
        }
        Some(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(name: &str, size: u64, category: Category, parent: Option<NodeId>) -> Node {
        Node {
            name: name.into(),
            size: Bytes(size),
            category,
            files: u64::from(category != Category::Folder),
            parent,
            children: Vec::new(),
        }
    }

    /// root (1000) ─ a/ (900) ─ big.mov (600), small.txt (300)
    ///             └ c.zip (100)
    fn sample() -> (FileTree, [NodeId; 4]) {
        let mut tree = FileTree::with_root(
            PathBuf::from("/r"),
            Node {
                files: 3,
                ..node("r", 1000, Category::Folder, None)
            },
        );
        let a = tree.push(Node {
            files: 2,
            ..node("a", 900, Category::Folder, Some(NodeId::ROOT))
        });
        let c = tree.push(node("c.zip", 100, Category::Archive, Some(NodeId::ROOT)));
        let big = tree.push(node("big.mov", 600, Category::Video, Some(a)));
        let small = tree.push(node("small.txt", 300, Category::Document, Some(a)));
        tree.node_mut(NodeId::ROOT).children = vec![a, c];
        tree.node_mut(a).children = vec![big, small];
        (tree, [a, c, big, small])
    }

    #[test]
    fn largest_files_skips_folders() {
        let (tree, [_, c, big, small]) = sample();
        assert_eq!(tree.largest_files(10), vec![big, small, c]);
        assert_eq!(tree.largest_files(1), vec![big]);
    }

    #[test]
    fn remove_updates_ancestors_and_resorts() {
        let (mut tree, [a, c, big, _]) = sample();
        tree.remove(big);
        assert_eq!(tree.node(a).size, Bytes(300));
        assert_eq!(tree.node(a).files, 1);
        assert_eq!(tree.node(NodeId::ROOT).size, Bytes(400));
        assert_eq!(tree.node(NodeId::ROOT).files, 2);
        assert!(!tree.largest_files(10).contains(&big));

        tree.remove(a);
        assert_eq!(tree.node(NodeId::ROOT).children, vec![c]);
        assert_eq!(tree.node(NodeId::ROOT).size, Bytes(100));
    }

    #[test]
    fn classifies_common_types() {
        assert_eq!(
            Category::classify("Safari.app", true),
            Category::Application
        );
        assert_eq!(Category::classify("src", true), Category::Folder);
        assert_eq!(Category::classify("IMG_0001.HEIC", false), Category::Image);
        assert_eq!(
            Category::classify("backup.tar.gz", false),
            Category::Archive
        );
        assert_eq!(Category::classify("Makefile", false), Category::Other);
    }
}
