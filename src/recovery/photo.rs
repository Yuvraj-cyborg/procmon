//! Photo formats: where each file ends, from its own structure.
//!
//! A parser checks that the bytes really are the format, then walks it to
//! the end. A file whose structure breaks off is kept but marked damaged:
//! half a photo is still worth having.

use super::found::{Condition, Details, Format, Timestamp};
use super::reader::Reader;

/// A file a parser recognised at some offset.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Carved {
    pub format: Format,
    pub length: u64,
    pub condition: Condition,
    pub details: Details,
    pub date: Option<Timestamp>,
}

impl Carved {
    pub fn new(format: Format, length: u64) -> Self {
        Self {
            format,
            length,
            condition: Condition::Good,
            details: Details::default(),
            date: None,
        }
    }

    pub fn damaged(mut self) -> Self {
        self.condition = Condition::Damaged;
        self
    }

    pub fn pixels(mut self, (width, height): (u32, u32)) -> Self {
        self.details.pixels = Some((width, height));
        self
    }
}

pub const JPEG_LIMIT: u64 = 128 << 20;
pub const IMAGE_LIMIT: u64 = 512 << 20;

// MARK: JPEG

pub fn jpeg(r: &mut Reader, start: u64) -> Option<Carved> {
    let limit = r.size().min(start + JPEG_LIMIT);
    let mut position = start + 2;
    let mut frame: Option<(u32, u32)> = None;
    let mut scanned = false;
    while position + 4 <= limit {
        if r.byte(position) != Some(0xFF) {
            break;
        }
        // Any number of 0xFF may pad the space before a marker.
        let mut marker = r.byte(position + 1)?;
        while marker == 0xFF {
            position += 1;
            marker = r.byte(position + 1)?;
        }
        match marker {
            0xD9 => {
                let frame = frame?;
                return scanned
                    .then(|| Carved::new(Format::Jpeg, position + 2 - start).pixels(frame));
            }
            // Another image starts here: this one never finished.
            0xD8 => return jpeg_damaged(frame, scanned, position - start),
            0x01 | 0xD0..=0xD7 => position += 2,
            0xC0..=0xFE => {
                let Some(length) = r.u16be(position + 2).filter(|l| *l >= 2) else {
                    return jpeg_damaged(frame, scanned, position - start);
                };
                if is_frame(marker)
                    && let (Some(height), Some(width)) =
                        (r.u16be(position + 5), r.u16be(position + 7))
                {
                    frame = Some((u32::from(width), u32::from(height)));
                }
                position += 2 + u64::from(length);
                if marker == 0xDA {
                    scanned = true;
                    match next_marker(r, position, limit) {
                        Some(next) => position = next,
                        None => {
                            // Nothing but zeros or unreadable space follows: the
                            // picture ends where the data does.
                            let end =
                                first_zero_sector(r, position, start, limit).unwrap_or(position);
                            return jpeg_damaged(frame, scanned, end - start);
                        }
                    }
                }
            }
            _ => return jpeg_damaged(frame, scanned, position - start),
        }
    }
    jpeg_damaged(frame, scanned, position.min(limit) - start)
}

/// Start-of-frame markers; C4, C8 and CC share the range but mean something else.
fn is_frame(marker: u8) -> bool {
    (0xC0..=0xCF).contains(&marker) && !matches!(marker, 0xC4 | 0xC8 | 0xCC)
}

fn jpeg_damaged(frame: Option<(u32, u32)>, scanned: bool, length: u64) -> Option<Carved> {
    let frame = frame?;
    (scanned && length > 0).then(|| Carved::new(Format::Jpeg, length).pixels(frame).damaged())
}

/// The first 512-byte block of zeros at or after `offset`, counted in
/// blocks from `start`. Compressed image data never holds that many.
pub fn first_zero_sector(r: &mut Reader, offset: u64, start: u64, limit: u64) -> Option<u64> {
    let mut sector = start + (offset - start).div_ceil(512) * 512;
    while sector + 512 <= limit {
        match r.bytes(sector, 512) {
            None => return Some(sector),
            Some(block) if block.iter().all(|b| *b == 0) => return Some(sector),
            Some(_) => sector += 512,
        }
    }
    None
}

/// The next real marker after entropy-coded data: `FF` followed by
/// anything but a stuffed zero, a restart marker or more padding.
fn next_marker(r: &mut Reader, offset: u64, limit: u64) -> Option<u64> {
    let mut position = offset;
    loop {
        let hit = r.find(&[0xFF], position, limit)?;
        match r.byte(hit + 1)? {
            0x00 | 0xD0..=0xD7 => position = hit + 2,
            0xFF => position = hit + 1,
            _ => return Some(hit),
        }
    }
}

// MARK: PNG

const PNG_SIGNATURE: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

pub fn png(r: &mut Reader, start: u64) -> Option<Carved> {
    if !r.matches(&PNG_SIGNATURE, start)
        || r.u32be(start + 8) != Some(13)
        || !r.ascii("IHDR", start + 12)
    {
        return None;
    }
    let width = r.u32be(start + 16).filter(|w| (1..=100_000).contains(w))?;
    let height = r.u32be(start + 20).filter(|h| (1..=100_000).contains(h))?;
    let limit = r.size().min(start + IMAGE_LIMIT);
    let mut position = start + 8;
    let mut saw_data = false;
    while position + 12 <= limit {
        let Some(length) = r.u32be(position).filter(|l| *l <= 0x7FFF_FFFF) else {
            break;
        };
        let Some(kind) = r
            .bytes(position + 4, 4)
            .filter(|t| t.iter().all(u8::is_ascii_alphabetic))
        else {
            break;
        };
        position += 12 + u64::from(length);
        match kind.as_slice() {
            b"IDAT" => saw_data = true,
            b"IEND" => {
                return saw_data
                    .then(|| Carved::new(Format::Png, position - start).pixels((width, height)));
            }
            _ => {}
        }
    }
    saw_data.then(|| {
        Carved::new(Format::Png, position.min(limit) - start)
            .pixels((width, height))
            .damaged()
    })
}

// MARK: GIF

pub fn gif(r: &mut Reader, start: u64) -> Option<Carved> {
    if !(r.ascii("GIF87a", start) || r.ascii("GIF89a", start)) {
        return None;
    }
    let width = r.u16le(start + 6).filter(|w| *w > 0)?;
    let height = r.u16le(start + 8).filter(|h| *h > 0)?;
    let flags = r.byte(start + 10)?;
    let pixels = (u32::from(width), u32::from(height));
    let limit = r.size().min(start + JPEG_LIMIT);
    let mut position = start + 13 + color_table_size(flags);
    let mut images = 0;
    let incomplete = |images: usize, position: u64| {
        (images > 0).then(|| {
            Carved::new(Format::Gif, position - start)
                .pixels(pixels)
                .damaged()
        })
    };
    while position < limit {
        let Some(block) = r.byte(position) else { break };
        match block {
            0x2C => {
                let packed = r.byte(position + 9)?;
                position += 10 + color_table_size(packed) + 1;
                let Some(next) = skip_sub_blocks(r, position, limit) else {
                    return incomplete(images, position);
                };
                position = next;
                images += 1;
            }
            0x21 => {
                let Some(next) = skip_sub_blocks(r, position + 2, limit) else {
                    return incomplete(images, position);
                };
                position = next;
            }
            0x3B => {
                return (images > 0)
                    .then(|| Carved::new(Format::Gif, position + 1 - start).pixels(pixels));
            }
            _ => return incomplete(images, position),
        }
    }
    incomplete(images, position.min(limit))
}

fn color_table_size(flags: u8) -> u64 {
    if flags & 0x80 == 0 {
        0
    } else {
        3 << (u64::from(flags & 0x07) + 1)
    }
}

fn skip_sub_blocks(r: &mut Reader, offset: u64, limit: u64) -> Option<u64> {
    let mut position = offset;
    while position < limit {
        let size = r.byte(position)?;
        position += 1 + u64::from(size);
        if size == 0 {
            return Some(position);
        }
    }
    None
}

// MARK: BMP

pub fn bmp(r: &mut Reader, start: u64) -> Option<Carved> {
    if !r.ascii("BM", start) {
        return None;
    }
    let size = r.u32le(start + 2)?;
    let data_offset = r.u32le(start + 10)?;
    let header = r.u32le(start + 14)?;
    if r.u32le(start + 6)? != 0
        || ![12, 40, 52, 56, 64, 108, 124].contains(&header)
        || u64::from(size) > IMAGE_LIMIT
        || data_offset < 14 + header
        || data_offset >= size
    {
        return None;
    }
    let core = header == 12;
    let signed = |value: u32| i64::from(value as i32);
    let (width, height) = if core {
        (
            i64::from(r.u16le(start + 18)?),
            i64::from(r.u16le(start + 20)?),
        )
    } else {
        (signed(r.u32le(start + 18)?), signed(r.u32le(start + 22)?))
    };
    let planes = r.u16le(start + if core { 22 } else { 26 })?;
    let depth = r.u16le(start + if core { 24 } else { 28 })?;
    let height = height.abs();
    if planes != 1
        || ![1, 4, 8, 16, 24, 32].contains(&depth)
        || !(1..=100_000).contains(&width)
        || !(1..=100_000).contains(&height)
    {
        return None;
    }
    // Uncompressed pixels must fit in the file the header claims.
    let compression = if core {
        0
    } else {
        r.u32le(start + 30).unwrap_or(0)
    };
    if compression == 0 {
        let row = (width as u64 * u64::from(depth)).div_ceil(32) * 4;
        if row * height as u64 > u64::from(size - data_offset) {
            return None;
        }
    }
    Some(Carved::new(Format::Bmp, u64::from(size)).pixels((width as u32, height as u32)))
}

// MARK: TIFF and the raw formats built on it

/// Walks every image directory and keeps the furthest byte any of them
/// points at: strips, tiles, previews and tag data.
pub fn tiff(r: &mut Reader, start: u64) -> Option<Carved> {
    let head = r.bytes(start, 4)?;
    let (little, mut format) = match head.as_slice() {
        [0x49, 0x49, 0x2A, 0x00] => (true, Format::Tiff),
        [0x4D, 0x4D, 0x00, 0x2A] => (false, Format::Tiff),
        b"IIRO" | b"IIRS" => (true, Format::Orf),
        b"MMOR" => (false, Format::Orf),
        _ => return None,
    };
    let limit = r.size().checked_sub(start)?.min(IMAGE_LIMIT);
    let u16_at = |r: &mut Reader, offset: u64| {
        if little {
            r.u16le(start + offset)
        } else {
            r.u16be(start + offset)
        }
        .map(u64::from)
    };
    let u32_at = |r: &mut Reader, offset: u64| {
        if little {
            r.u32le(start + offset)
        } else {
            r.u32be(start + offset)
        }
        .map(u64::from)
    };
    let values = |r: &mut Reader, kind: u64, count: u64, offset: u64| -> Vec<u64> {
        let wide = kind == 4 || kind == 13;
        if !(kind == 3 || wide) || count > 65_536 {
            return Vec::new();
        }
        (0..count)
            .filter_map(|i| {
                if wide {
                    u32_at(r, offset + i * 4)
                } else {
                    u16_at(r, offset + i * 2)
                }
            })
            .collect()
    };
    let first = u32_at(r, 4).filter(|f| *f >= 8 && *f < limit)?;
    if format == Format::Tiff && r.ascii("CR", start + 8) && r.byte(start + 10) == Some(2) {
        format = Format::Cr2;
    }

    let mut end: u64 = 8;
    let mut queue = vec![first];
    let mut visited = std::collections::HashSet::new();
    let mut saw_image = false;
    let mut make = String::new();
    let mut is_dng = false;
    let mut size = (0u64, 0u64);
    while let Some(directory) = queue.pop() {
        if visited.len() >= 64 || directory < 8 || directory >= limit || !visited.insert(directory)
        {
            continue;
        }
        let Some(count) = u16_at(r, directory).filter(|c| (1..=2_000).contains(c)) else {
            continue;
        };
        end = end.max(directory + 2 + count * 12 + 4);
        let mut offsets = Vec::new();
        let mut lengths = Vec::new();
        let mut preview = (None, None);
        let mut dimensions = (0, 0);
        for index in 0..count {
            let entry = directory + 2 + index * 12;
            let (Some(tag), Some(kind), Some(number)) =
                (u16_at(r, entry), u16_at(r, entry + 2), u32_at(r, entry + 4))
            else {
                continue;
            };
            let unit: u64 = match kind {
                1 | 2 | 6 | 7 => 1,
                3 | 8 => 2,
                4 | 9 | 11 | 13 => 4,
                5 | 10 | 12 => 8,
                _ => 0,
            };
            let bytes = unit * number;
            if unit == 0 || bytes > limit {
                continue;
            }
            let value_offset = if bytes <= 4 {
                entry + 8
            } else {
                u32_at(r, entry + 8).unwrap_or(0)
            };
            if bytes > 4 {
                if value_offset + bytes > limit {
                    continue;
                }
                end = end.max(value_offset + bytes);
            }
            match tag {
                0x100 => {
                    dimensions.0 = values(r, kind, 1, value_offset)
                        .first()
                        .copied()
                        .unwrap_or(0)
                }
                0x101 => {
                    dimensions.1 = values(r, kind, 1, value_offset)
                        .first()
                        .copied()
                        .unwrap_or(0)
                }
                0x10F => {
                    let text = r
                        .bytes(start + value_offset, bytes.min(64) as usize)
                        .unwrap_or_default();
                    make = String::from_utf8_lossy(text.split(|b| *b == 0).next().unwrap_or(&[]))
                        .into_owned();
                }
                0x111 | 0x144 => offsets = values(r, kind, number, value_offset),
                0x117 | 0x145 => lengths = values(r, kind, number, value_offset),
                0x201 => preview.0 = values(r, kind, 1, value_offset).first().copied(),
                0x202 => preview.1 = values(r, kind, 1, value_offset).first().copied(),
                0x14A => queue.extend(values(r, kind, number, value_offset)),
                0x8769 | 0x8825 | 0xA005 => queue.extend(values(r, kind, 1, value_offset)),
                0xC612 => is_dng = true,
                _ => {}
            }
        }
        for (offset, length) in offsets.iter().zip(&lengths) {
            if offset + length <= limit {
                end = end.max(offset + length);
                saw_image |= *length > 0;
            }
        }
        if let (Some(offset), Some(length)) = preview
            && offset + length <= limit
        {
            end = end.max(offset + length);
            saw_image |= length > 0;
        }
        if dimensions.0 * dimensions.1 > size.0 * size.1 {
            size = dimensions;
        }
        if let Some(next) = u32_at(r, directory + 2 + count * 12).filter(|n| *n != 0) {
            queue.push(next);
        }
    }
    if !saw_image || end < 64 {
        return None;
    }
    if format == Format::Tiff {
        let maker = make.to_ascii_uppercase();
        format = if is_dng {
            Format::Dng
        } else if maker.starts_with("NIKON") {
            Format::Nef
        } else if maker.starts_with("SONY") {
            Format::Arw
        } else if maker.starts_with("PENTAX") || maker.starts_with("RICOH") {
            Format::Pef
        } else {
            Format::Tiff
        };
    }
    Some(Carved::new(format, end).pixels((size.0 as u32, size.1 as u32)))
}

// MARK: Fujifilm raw

/// The header lists the embedded preview and the sensor data with their sizes.
pub fn raf(r: &mut Reader, start: u64) -> Option<Carved> {
    if !r.ascii("FUJIFILMCCD-RAW ", start) {
        return None;
    }
    let mut end: u64 = 108;
    for (offset, length) in [(84, 88), (92, 96), (100, 104)] {
        let position = u64::from(r.u32be(start + offset)?);
        let size = u64::from(r.u32be(start + length)?);
        end = end.max(position + size);
    }
    (end <= IMAGE_LIMIT && start + end <= r.size()).then(|| Carved::new(Format::Raf, end))
}
