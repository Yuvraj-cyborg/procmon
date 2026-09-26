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
