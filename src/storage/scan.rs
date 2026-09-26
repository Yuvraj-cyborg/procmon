use std::cmp::Reverse;
use std::collections::HashSet;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use rayon::prelude::*;

use super::tree::{Category, FileTree, Node, NodeId};
use crate::units::Bytes;

/// Folders keep this many of their largest files as individual nodes; the rest
/// are folded into one "smaller files" node so huge trees stay light in memory.
const FILES_PER_FOLDER: usize = 64;

/// Files at least this large are never folded, so they always show up in the
/// map and the largest-files list.
const ALWAYS_KEEP: u64 = 16 * 1024 * 1024;

/// `st_blocks` is always counted in 512-byte units, regardless of the
/// filesystem's block size.
const BLOCK_SIZE: u64 = 512;

/// Live counters shared between the scanning threads and the UI.
#[derive(Debug, Default)]
pub struct ScanProgress {
    files: AtomicU64,
    bytes: AtomicU64,
    cancelled: AtomicBool,
}

impl ScanProgress {
    pub fn files(&self) -> u64 {
        self.files.load(Ordering::Relaxed)
    }

    pub fn bytes(&self) -> Bytes {
        Bytes(self.bytes.load(Ordering::Relaxed))
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }
}

#[derive(Debug)]
pub enum ScanError {
    Cancelled,
    Io(io::Error),
}

impl std::fmt::Display for ScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScanError::Cancelled => write!(f, "scan cancelled"),
            ScanError::Io(err) => err.fmt(f),
        }
    }
}

struct Context<'a> {
    device: u64,
    progress: &'a ScanProgress,
    hard_links: Mutex<HashSet<(u64, u64)>>,
    unreadable: AtomicU64,
}

/// Intermediate owned tree built in parallel, flattened into a [`FileTree`] at the end.
struct Scanned {
    name: Box<str>,
    size: u64,
    category: Category,
    files: u64,
    children: Vec<Scanned>,
}

/// Measures everything under `root` without crossing into other filesystems
/// or following symlinks. Sizes are allocated blocks, so sparse and cloned
/// files are counted the way the disk sees them; hard links are counted once.
pub fn scan(root: &Path, progress: &ScanProgress) -> Result<FileTree, ScanError> {
    let meta = fs::symlink_metadata(root).map_err(ScanError::Io)?;
    if !meta.is_dir() {
        return Err(ScanError::Io(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a directory",
        )));
    }
    let context = Context {
        device: meta.dev(),
        progress,
        hard_links: Mutex::new(HashSet::new()),
        unreadable: AtomicU64::new(0),
    };
    let name: Box<str> = root.display().to_string().into();
    let scanned = scan_dir(root, name, meta.blocks() * BLOCK_SIZE, &context);
    if progress.is_cancelled() {
        return Err(ScanError::Cancelled);
    }

    let mut tree = FileTree::with_root(
        root.to_path_buf(),
        Node {
            name: scanned.name,
            size: Bytes(scanned.size),
            category: Category::Folder,
            files: scanned.files,
            parent: None,
            children: Vec::new(),
        },
    );
    attach(&mut tree, NodeId::ROOT, scanned.children);
    tree.unreadable = context.unreadable.into_inner();
    Ok(tree)
}

fn scan_dir(path: &Path, name: Box<str>, own_size: u64, cx: &Context<'_>) -> Scanned {
    let mut node = Scanned {
        category: Category::classify(&name, true),
        name,
        size: own_size,
        files: 0,
        children: Vec::new(),
    };
    if cx.progress.is_cancelled() {
        return node;
    }
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(_) => {
            cx.unreadable.fetch_add(1, Ordering::Relaxed);
            return node;
        }
    };

    let mut subdirs: Vec<(PathBuf, Box<str>, u64)> = Vec::new();
    let mut files: Vec<Scanned> = Vec::new();
    for entry in entries.flatten() {
        // `DirEntry::metadata` does not traverse symlinks on Unix.
        let Ok(meta) = entry.metadata() else { continue };
        let file_type = meta.file_type();
        if file_type.is_symlink() {
            continue;
        }
        let entry_name: Box<str> = entry.file_name().to_string_lossy().into();
        let size = meta.blocks() * BLOCK_SIZE;
        if file_type.is_dir() {
            if meta.dev() == cx.device {
                subdirs.push((entry.path(), entry_name, size));
            }
            continue;
        }
        if meta.nlink() > 1
            && !cx
                .hard_links
                .lock()
                .unwrap()
                .insert((meta.dev(), meta.ino()))
        {
            continue;
        }
        cx.progress.files.fetch_add(1, Ordering::Relaxed);
        cx.progress.bytes.fetch_add(size, Ordering::Relaxed);
        files.push(Scanned {
            category: Category::classify(&entry_name, false),
            name: entry_name,
            size,
            files: 1,
            children: Vec::new(),
        });
    }

    let dirs: Vec<Scanned> = subdirs
        .into_par_iter()
        .map(|(path, name, size)| scan_dir(&path, name, size, cx))
        .collect();

    files.sort_unstable_by_key(|f| Reverse(f.size));
    let keep = FILES_PER_FOLDER.max(files.partition_point(|f| f.size >= ALWAYS_KEEP));
    if files.len() > keep {
        let tail = files.split_off(keep);
        let count = tail.len() as u64;
        files.push(Scanned {
            name: format!("{count} smaller files").into(),
            size: tail.iter().map(|f| f.size).sum(),
            category: Category::Remainder,
            files: count,
            children: Vec::new(),
        });
    }

    node.children = dirs;
    node.children.append(&mut files);
    node.children.sort_unstable_by_key(|c| Reverse(c.size));
    node.size += node.children.iter().map(|c| c.size).sum::<u64>();
    node.files = node.children.iter().map(|c| c.files).sum();
    node
}

fn attach(tree: &mut FileTree, parent: NodeId, children: Vec<Scanned>) {
    let mut ids = Vec::with_capacity(children.len());
    for child in children {
        let id = tree.push(Node {
            name: child.name,
            size: Bytes(child.size),
            category: child.category,
            files: child.files,
            parent: Some(parent),
            children: Vec::new(),
        });
        attach(tree, id, child.children);
        ids.push(id);
    }
    tree.node_mut(parent).children = ids;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("procmon-scan-{label}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn sizes_roll_up_and_children_are_sorted() {
        let root = temp_dir("rollup");
        fs::create_dir_all(root.join("big")).unwrap();
        fs::write(root.join("big/blob.bin"), vec![1u8; 256 * 1024]).unwrap();
        fs::write(root.join("small.txt"), b"hi").unwrap();

        let tree = scan(&root, &ScanProgress::default()).unwrap();
        let top = tree.node(NodeId::ROOT);
        assert_eq!(top.files, 2);
        let first = tree.node(top.children[0]);
        assert_eq!(&*first.name, "big");
        assert!(first.size >= Bytes(256 * 1024));
        let child_sum: Bytes = top.children.iter().map(|c| tree.node(*c).size).sum();
        assert!(top.size >= child_sum);
        assert_eq!(
            tree.path_of(first.children[0]).unwrap(),
            root.join("big/blob.bin")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn hard_links_count_once_and_symlinks_are_skipped() {
        let root = temp_dir("links");
        fs::write(root.join("a.bin"), vec![1u8; 64 * 1024]).unwrap();
        fs::hard_link(root.join("a.bin"), root.join("b.bin")).unwrap();
        std::os::unix::fs::symlink(root.join("a.bin"), root.join("c.bin")).unwrap();

        let tree = scan(&root, &ScanProgress::default()).unwrap();
        assert_eq!(tree.node(NodeId::ROOT).files, 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn long_tail_of_files_is_folded() {
        let root = temp_dir("fold");
        for i in 0..(FILES_PER_FOLDER + 10) {
            fs::write(root.join(format!("f{i}")), vec![0u8; 4096 + i]).unwrap();
        }
        let tree = scan(&root, &ScanProgress::default()).unwrap();
        let top = tree.node(NodeId::ROOT);
        assert_eq!(top.children.len(), FILES_PER_FOLDER + 1);
        assert_eq!(top.files as usize, FILES_PER_FOLDER + 10);
        let remainder = top
            .children
            .iter()
            .find(|c| tree.node(**c).category == Category::Remainder)
            .unwrap();
        assert_eq!(tree.node(*remainder).files, 10);
        assert!(tree.path_of(*remainder).is_none());
        fs::remove_dir_all(root).unwrap();
    }

    /// `SCAN_ROOT=$HOME cargo test --release scan_live -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn scan_live() {
        let root = PathBuf::from(std::env::var("SCAN_ROOT").unwrap());
        let started = std::time::Instant::now();
        let tree = scan(&root, &ScanProgress::default()).unwrap();
        let top = tree.node(NodeId::ROOT);
        println!(
            "{} files, {} on disk, {} nodes, {} unreadable, in {:?}",
            top.files,
            top.size.decimal(),
            tree.len(),
            tree.unreadable,
            started.elapsed()
        );
    }

    #[test]
    fn cancelled_scan_reports_cancellation() {
        let root = temp_dir("cancel");
        let progress = ScanProgress::default();
        progress.cancel();
        assert!(matches!(scan(&root, &progress), Err(ScanError::Cancelled)));
        fs::remove_dir_all(root).unwrap();
    }
}
