//! One recovery scan from start to finish: deleted files with their names
//! from the directories first, since that is quick, then the whole disk by
//! content, which finds what the directories no longer list.

use std::collections::HashSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use super::carver::{self, Progress, Stage};
use super::filesystems;
use super::found::{Condition, Extent, Format, FoundFile, Origin};
use super::reader::{ByteSource, ReadError, Reader};

pub struct RecoveryScan {
    source: Arc<dyn ByteSource>,
    progress: Progress,
    pending: Mutex<Vec<FoundFile>>,
    last_id: AtomicUsize,
    file_systems: Mutex<Vec<&'static str>>,
}

impl RecoveryScan {
    pub fn new(source: Arc<dyn ByteSource>) -> Self {
        Self {
            source,
            progress: Progress::default(),
            pending: Mutex::new(Vec::new()),
            last_id: AtomicUsize::new(0),
            file_systems: Mutex::new(Vec::new()),
        }
    }

    pub fn source(&self) -> &Arc<dyn ByteSource> {
        &self.source
    }

    pub fn progress(&self) -> &Progress {
        &self.progress
    }

    /// File systems the directory pass read, e.g. `["FAT32"]`.
    pub fn file_systems(&self) -> Vec<&'static str> {
        self.file_systems.lock().map(|f| f.clone()).unwrap_or_default()
    }

    /// Files found since the last call, for the page to show.
    pub fn collect(&self) -> Vec<FoundFile> {
        self.pending.lock().map(|mut files| std::mem::take(&mut *files)).unwrap_or_default()
    }

    /// Runs the scan on the calling thread. Ends early, without an error,
    /// when cancelled; fails only when the disk goes away.
    pub fn run(&self) -> Result<(), ReadError> {
        let source = self.source.as_ref();
        self.progress.begin(Stage::Directories, Some(source.size()));
        let mut reader = Reader::new(source);
        let mut allocated = Vec::new();
        let mut named = HashSet::new();
        let cancelled = || self.progress.is_cancelled();
        for partition in filesystems::partitions(&mut reader, source.block_size() as u64) {
            if self.progress.is_cancelled() {
                return Ok(());
            }
            let Some(scan) = filesystems::scan(source, partition, &cancelled) else { continue };
            if let Ok(mut systems) = self.file_systems.lock() {
                systems.push(scan.format);
            }
            allocated.extend(scan.allocated);
            for mut file in scan.files {
                identify(&mut file, &mut reader);
                file.id = self.next_id();
                named.insert(file.offset());
                self.publish(file);
            }
        }
        if self.progress.is_cancelled() {
            return Ok(());
        }

        self.progress.begin(Stage::Contents, None);
        allocated.sort_by_key(|range| range.start);
        carver::scan(source, None, &allocated, &self.progress, |carved, offset| {
            // Listed already, with its name.
            if named.contains(&offset) {
                return;
            }
            self.publish(FoundFile {
                id: self.next_id(),
                format: Some(carved.format),
                kind: carved.format.kind(),
                extents: vec![Extent {
                    offset,
                    length: carved.length,
                }],
                name: None,
                folder: None,
                date: carved.date,
                condition: carved.condition,
                details: carved.details,
                origin: Origin::Contents,
            });
        })?;
        if !self.progress.is_cancelled() {
            self.progress.begin(Stage::Finished, None);
        }
        Ok(())
    }

    fn publish(&self, file: FoundFile) {
        if let Ok(mut pending) = self.pending.lock() {
            pending.push(file);
        }
    }

    fn next_id(&self) -> usize {
        self.last_id.fetch_add(1, Ordering::Relaxed) + 1
    }
}

/// Checks a directory entry against its contents: the format they hold, what
/// they say about themselves, and whether they are still there.
pub fn identify(file: &mut FoundFile, reader: &mut Reader) {
    let Some(first) = file.extents.first().copied() else { return };
    let Some(head) = reader.bytes(first.offset, 32) else { return };
    let expected = Format::for_name(file.name.as_deref().unwrap_or_default());
    let Some(parse) = carver::parser_for(&head) else {
        // Named like a photo or video, but holding something else: its
        // clusters were reused after it was deleted.
        if expected.is_some() && file.condition == Condition::Good {
            file.condition = Condition::Overwritten;
        }
        return;
    };
    file.format = expected;
    // Parsers read the disk straight through, so only a file in one piece can be measured.
    if file.extents.len() != 1 {
        return;
    }
    let Some(carved) = parse(reader, first.offset) else {
        if file.condition == Condition::Good {
            file.condition = Condition::Damaged;
        }
        return;
    };
    file.format = Some(carved.format);
    file.kind = carved.format.kind();
    file.details = carved.details;
    file.date = file.date.or(carved.date);
    if carved.condition == Condition::Damaged && file.condition == Condition::Good {
        file.condition = Condition::Damaged;
    }
}
