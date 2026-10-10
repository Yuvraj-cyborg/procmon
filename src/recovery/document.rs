//! Documents: PDF, and ZIP with the formats built on it (Word, Excel,
//! PowerPoint, EPUB). Neither states its size up front, so both are measured
//! by finding their closing structure.

use super::found::Format;
use super::photo::Carved;
use super::reader::Reader;

pub const PDF_LIMIT: u64 = 1 << 30;
pub const ZIP_LIMIT: u64 = 4 << 30;

// MARK: PDF

/// A PDF ends at `%%EOF`; an edited one appends more objects and another
/// `%%EOF`, so the search goes on while what follows still looks like PDF.
pub fn pdf(r: &mut Reader, start: u64) -> Option<Carved> {
    if !r.ascii("%PDF-", start)
        || !matches!(r.byte(start + 5), Some(b'1' | b'2'))
        || r.byte(start + 6) != Some(b'.')
    {
        return None;
    }
    let limit = r.size().min(start + PDF_LIMIT);
    let mut position = start + 8;
    let mut end = None;
    while let Some(marker) = r.find(b"%%EOF", position, limit) {
        let mut after = marker + 5;
        while after < limit && matches!(r.byte(after), Some(b'\r' | b'\n')) {
            after += 1;
        }
        end = Some(after);
        match r.bytes(after, 16) {
            Some(next) if continues_document(&next) => position = after,
            _ => break,
        }
    }
    Some(Carved::new(Format::Pdf, end? - start))
}

/// An appended update starts with an object (`12 0 obj`), a cross-reference
/// table, or a comment that is not the start of another PDF.
fn continues_document(bytes: &[u8]) -> bool {
    let text = String::from_utf8_lossy(bytes);
    if text.starts_with("xref") {
        return true;
    }
    if text.starts_with('%') {
        return !text.starts_with("%PDF");
    }
    let parts: Vec<&str> = text.splitn(3, ' ').collect();
    parts.len() == 3
        && !parts[0].is_empty()
        && parts[0].chars().all(|c| c.is_ascii_digit())
        && !parts[1].is_empty()
        && parts[1].chars().all(|c| c.is_ascii_digit())
        && parts[2].starts_with("obj")
}

// MARK: ZIP

const CENTRAL_END: [u8; 4] = [0x50, 0x4B, 0x05, 0x06];

/// The end-of-archive record says where the central directory starts and
/// how long it is; the right one is the record those numbers lead back to.
pub fn zip(r: &mut Reader, start: u64) -> Option<Carved> {
    if !r.matches(&[0x50, 0x4B, 0x03, 0x04], start)
        || r.u16le(start + 4)? > 63
        || ![0, 1, 6, 8, 9, 12, 14, 93, 95, 98, 99].contains(&r.u16le(start + 8)?)
        || !(1..=1024).contains(&r.u16le(start + 26)?)
    {
        return None;
    }
    let limit = r.size().min(start + ZIP_LIMIT);
    let mut position = start + 30;
    while let Some(record) = r.find(&CENTRAL_END, position, limit) {
        position = record + 4;
        let (Some(size), Some(offset), Some(comment)) = (
            r.u32le(record + 12),
            r.u32le(record + 16),
            r.u16le(record + 20),
        ) else {
            continue;
        };
        let directory = if offset == u32::MAX || size == u32::MAX {
            zip64_directory(r, start, record)
        } else if start + u64::from(offset) + u64::from(size) == record {
            Some((u64::from(offset), u64::from(size)))
        } else {
            None
        };
        let Some((offset, size)) = directory else {
            continue;
        };
        let length = record + 22 + u64::from(comment) - start;
        return Some(Carved::new(classify(r, start + offset, size), length));
    }
    None
}

/// Archives over 4 GB keep the real numbers in a ZIP64 record, found
/// through a locator just before the classic one.
fn zip64_directory(r: &mut Reader, start: u64, record: u64) -> Option<(u64, u64)> {
    if record < 20 || !r.matches(&[0x50, 0x4B, 0x06, 0x07], record - 20) {
        return None;
    }
    let zip64 = start + r.u64le(record - 12)?;
    if !r.matches(&[0x50, 0x4B, 0x06, 0x06], zip64) {
        return None;
    }
    let size = r.u64le(zip64 + 40)?;
    let offset = r.u64le(zip64 + 48)?;
    (start + offset + size == zip64).then_some((offset, size))
}

/// Office files and EPUBs are told apart by the names inside.
fn classify(r: &mut Reader, directory: u64, size: u64) -> Format {
    let mut position = directory;
    let mut names = Vec::new();
    while position + 46 <= directory + size
        && names.len() < 2_000
        && r.matches(&[0x50, 0x4B, 0x01, 0x02], position)
    {
        let (Some(name), Some(extra), Some(comment)) = (
            r.u16le(position + 28),
            r.u16le(position + 30),
            r.u16le(position + 32),
        ) else {
            break;
        };
        if let Some(bytes) = r.bytes(position + 46, usize::from(name)) {
            names.push(String::from_utf8_lossy(&bytes).into_owned());
        }
        position += 46 + u64::from(name) + u64::from(extra) + u64::from(comment);
    }
    let has_prefix = |prefix: &str| names.iter().any(|n| n.starts_with(prefix));
    if has_prefix("word/") {
        Format::Docx
    } else if has_prefix("xl/") {
        Format::Xlsx
    } else if has_prefix("ppt/") {
        Format::Pptx
    } else if names.iter().any(|n| n == "mimetype")
        && names.iter().any(|n| n == "META-INF/container.xml")
    {
        Format::Epub
    } else {
        Format::Zip
    }
}
