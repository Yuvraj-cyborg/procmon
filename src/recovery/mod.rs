//! Bringing back deleted files: by their old directory entries on FAT and
//! exFAT, and by their contents anywhere on a disk.

mod access;
mod carver;
mod disks;
mod document;
mod export;
mod filesystems;
mod found;
mod media;
mod photo;
mod preview;
mod reader;
mod scanner;

pub use access::{AccessError, is_elevated, open, relaunch_elevated};
pub use carver::Stage;
pub use disks::{Disk, DiskKind, holding, list};
pub use export::{ExportProgress, export};
pub use found::{Condition, FoundFile, Kind, Origin, Timestamp};
pub use preview::{has_preview, thumbnail};
pub use reader::{ByteSource, RawDevice};
pub use scanner::RecoveryScan;

#[cfg(test)]
mod tests;
