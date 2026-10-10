//! Finds files by their contents, the way PhotoRec does: read the disk from
//! start to end, and wherever a 512-byte block begins with a known signature,
//! let that format's parser decide whether a file starts there and how long
//! it is. File systems start files on block boundaries, so nothing else needs
//! checking, and a file measured whole is skipped rather than searched.

use std::ops::Range;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};

use super::document;
use super::found::Condition;
use super::media;
use super::photo::{self, Carved};
use super::reader::{ByteSource, ReadError, Reader};
use crate::units::Bytes;

pub const BLOCK: u64 = 512;
const CHUNK: usize = 4 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Opening,
    Directories,
    Contents,
    Finished,
}

/// Live counters shared between a recovery scan and the page showing it.
#[derive(Debug, Default)]
pub struct Progress {
    stage: AtomicU8,
    position: AtomicU64,
    total: AtomicU64,
    unreadable: AtomicU64,
    cancelled: AtomicBool,
}

impl Progress {
    pub fn stage(&self) -> Stage {
        match self.stage.load(Ordering::Relaxed) {
            1 => Stage::Directories,
            2 => Stage::Contents,
            3 => Stage::Finished,
            _ => Stage::Opening,
        }
    }

    /// How far through the disk the contents scan has come.
    pub fn scanned(&self) -> Bytes {
        Bytes(self.position.load(Ordering::Relaxed))
    }

    pub fn total(&self) -> Bytes {
        Bytes(self.total.load(Ordering::Relaxed))
    }

    /// Bytes the disk could not return; often a sign it is failing.
    pub fn unreadable(&self) -> Bytes {
        Bytes(self.unreadable.load(Ordering::Relaxed))
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    pub fn begin(&self, stage: Stage, total: Option<u64>) {
        self.stage.store(stage as u8, Ordering::Relaxed);
        if let Some(total) = total {
            self.total.store(total, Ordering::Relaxed);
        }
    }

    fn reached(&self, offset: u64) {
        self.position.store(offset, Ordering::Relaxed);
    }

    fn lost(&self, bytes: u64) {
        self.unreadable.fetch_add(bytes, Ordering::Relaxed);
    }
}

pub type Parser = fn(&mut Reader, u64) -> Option<Carved>;

/// The parser for a block's first bytes, if they look like any format.
pub fn parser_for(head: &[u8]) -> Option<Parser> {
    if head.len() < 16 {
        return None;
    }
    let starts = |pattern: &[u8]| head.starts_with(pattern);
    let parser: Parser = match head[0] {
        0xFF if head[1] == 0xD8 && head[2] == 0xFF => photo::jpeg,
        0xFF if head[1] & 0xE0 == 0xE0 => media::mp3,
        0x89 if &head[1..4] == b"PNG" => photo::png,
        b'G' if starts(b"GIF8") => photo::gif,
        b'B' if head[1] == b'M' => photo::bmp,
        b'R' if starts(b"RIFF") => media::riff,
        b'I' if starts(b"ID3") => media::mp3,
        b'I' if starts(&[0x49, 0x49, 0x2A, 0x00]) || starts(b"IIRO") || starts(b"IIRS") => photo::tiff,
        b'M' if starts(&[0x4D, 0x4D, 0x00, 0x2A]) || starts(b"MMOR") => photo::tiff,
        b'F' if starts(b"FUJIFILMCCD-RAW ") => photo::raf,
        // Most blocks of free space are zeros: this is the cheap check for them.
        0x00 if &head[4..8] == b"ftyp" => media::iso_media,
        0x1A if starts(&[0x1A, 0x45, 0xDF, 0xA3]) => media::matroska,
        b'%' if starts(b"%PDF-") => document::pdf,
        b'P' if starts(&[0x50, 0x4B, 0x03, 0x04]) => document::zip,
        _ => return None,
    };
    Some(parser)
}

/// Scans `range` of `source`, calling `found` with each file and its offset.
/// `skipping` lists byte ranges known to hold live files (sorted), which are
/// stepped over. Unreadable blocks are counted and passed over; only a
/// disconnected disk ends the scan early.
pub fn scan(
    source: &dyn ByteSource,
    range: Option<Range<u64>>,
    skipping: &[Range<u64>],
    progress: &Progress,
    mut found: impl FnMut(Carved, u64),
) -> Result<(), ReadError> {
    let range = range.unwrap_or(0..source.size());
    let mut reader = Reader::new(source);
    let mut buffer = vec![0u8; CHUNK];
    let mut skip = skipping.iter().peekable();
    let mut position = range.start / BLOCK * BLOCK;

    while position < range.end && !progress.is_cancelled() {
        while skip.next_if(|s| s.end <= position).is_some() {}
        if let Some(current) = skip.peek()
            && current.contains(&position)
        {
            position = current.end.div_ceil(BLOCK) * BLOCK;
            progress.reached(position);
            continue;
        }
        let stop = range
            .end
            .min(skip.peek().map_or(u64::MAX, |s| s.start))
            .min(position + CHUNK as u64);
        let count = (stop - position) as usize;
        let valid = read(source, &mut buffer[..count], position, progress)?;
        if valid == 0 {
            break;
        }

        let mut resume = position + valid as u64;
        let mut block = 0;
        while block + 16 <= valid {
            let head = &buffer[block..valid.min(block + BLOCK as usize)];
            let offset = position + block as u64;
            if let Some(parse) = parser_for(head)
                && let Some(carved) = parse(&mut reader, offset)
            {
                found(carved, offset);
                // A complete file is skipped whole. A damaged one is only a
                // guess, so whatever lies inside it is still searched.
                let end = if carved.condition == Condition::Good { offset + carved.length } else { offset + 1 };
                let next = end.div_ceil(BLOCK) * BLOCK;
                if next > offset + BLOCK {
                    resume = next;
                    break;
                }
            }
            block += BLOCK as usize;
        }
        position = resume;
        progress.reached(position.min(range.end));
    }
    progress.reached(range.end);
    Ok(())
}

/// Fills `buffer` from `offset`; unreadable stretches become zeros and are
/// counted, so one bad patch does not end the scan.
fn read(source: &dyn ByteSource, buffer: &mut [u8], offset: u64, progress: &Progress) -> Result<usize, ReadError> {
    match source.read_at(buffer, offset) {
        Ok(read) => Ok(read),
        Err(ReadError::Disconnected) => Err(ReadError::Disconnected),
        Err(ReadError::Unreadable) => {
            // Retry in small pieces: only the pieces that fail are lost.
            const PIECE: usize = 64 * 1024;
            let mut done = 0;
            while done < buffer.len() {
                let length = PIECE.min(buffer.len() - done);
                let slice = &mut buffer[done..done + length];
                match source.read_at(slice, offset + done as u64) {
                    Ok(0) => break,
                    Ok(got) => done += got,
                    Err(ReadError::Disconnected) => return Err(ReadError::Disconnected),
                    Err(ReadError::Unreadable) => {
                        slice.fill(0);
                        progress.lost(length as u64);
                        done += length;
                    }
                }
            }
            Ok(done)
        }
    }
}
