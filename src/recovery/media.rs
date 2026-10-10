//! Video and audio formats, and the photo formats that share their
//! containers (HEIC, AVIF and Canon's CR3 are ISO media files; WebP is RIFF).
//!
//! These containers state their own sizes, so even a long video is measured
//! by reading a few headers rather than all of it.

use std::time::Duration;

use super::found::{Details, Format, Timestamp};
use super::photo::{Carved, JPEG_LIMIT};
use super::reader::Reader;

pub const VIDEO_LIMIT: u64 = 64 << 30;
pub const AUDIO_LIMIT: u64 = 512 << 20;

// MARK: ISO base media (MP4, MOV, HEIC, AVIF, CR3, M4A, 3GP)

/// Top-level boxes seen in real files. Anything else after a complete file
/// belongs to whatever was written next on the disk.
const KNOWN_BOXES: [&[u8; 4]; 24] = [
    b"ftyp", b"moov", b"mdat", b"free", b"skip", b"wide", b"uuid", b"meta", b"pdin", b"moof",
    b"mfra", b"sidx", b"ssix", b"prft", b"emsg", b"styp", b"pnot", b"PICT", b"junk", b"udta",
    b"XMP_", b"beam", b"jumb", b"ID32",
];

pub fn iso_media(r: &mut Reader, start: u64) -> Option<Carved> {
    let header = r.u32be(start).filter(|h| (8..=512).contains(h))?;
    if !r.ascii("ftyp", start + 4) {
        return None;
    }
    let mut brands = vec![r.bytes(start + 8, 4)?];
    let mut cursor = start + 16;
    while cursor + 4 <= start + u64::from(header) {
        let Some(brand) = r.bytes(cursor, 4) else {
            break;
        };
        brands.push(brand);
        cursor += 4;
    }
    let format = classify(&brands);
    let limit = r.size().min(start + VIDEO_LIMIT);
    let mut position = start;
    let (mut saw_movie, mut saw_data, mut saw_meta, mut saw_fragments) =
        (false, false, false, false);
    let mut details = Details::default();
    let mut date = None;
    let mut damaged = false;
    while position + 8 <= limit {
        let (Some(size32), Some(kind)) = (r.u32be(position), r.bytes(position + 4, 4)) else {
            break;
        };
        if !kind.iter().all(|b| (0x20..=0x7E).contains(b)) {
            break;
        }
        let complete = saw_data && (saw_movie || saw_meta || saw_fragments);
        if position > start && kind == b"ftyp" {
            break;
        }
        if complete
            && !KNOWN_BOXES
                .iter()
                .any(|known| known.as_slice() == kind.as_slice())
        {
            break;
        }
        let size = match size32 {
            1 => match r.u64be(position + 8) {
                Some(large) => large,
                None => break,
            },
            // "Runs to the end of the file": a recording that was never closed.
            0 => {
                damaged = true;
                saw_data |= kind == b"mdat";
                position = limit;
                break;
            }
            size => u64::from(size),
        };
        if size < 8 {
            break;
        }
        if position + size > limit {
            damaged = true;
            saw_data |= kind == b"mdat";
            position = limit;
            break;
        }
        match kind.as_slice() {
            b"moov" => {
                saw_movie = true;
                (details, date) = movie_details(r, position, size);
            }
            b"mdat" => saw_data = true,
            b"meta" => saw_meta = true,
            b"moof" => saw_fragments = true,
            _ => {}
        }
        position += size;
    }
    // Still images keep their index in `meta`; everything else (Canon's CR3
    // included) needs a movie index and the data it points into.
    let playable = if matches!(format, Format::Heic | Format::Avif) {
        saw_meta
    } else {
        (saw_movie || saw_fragments) && saw_data
    };
    if !playable || position <= start {
        return None;
    }
    let mut carved = Carved::new(format, position - start);
    carved.details = details;
    carved.date = date;
    Some(if damaged { carved.damaged() } else { carved })
}

pub fn classify(brands: &[Vec<u8>]) -> Format {
    let major = brands.first().map(Vec::as_slice).unwrap_or_default();
    match major {
        b"heic" | b"heix" | b"heim" | b"heis" | b"hevc" | b"hevx" => Format::Heic,
        b"avif" | b"avis" => Format::Avif,
        b"crx " => Format::Cr3,
        b"qt  " => Format::Mov,
        b"M4A " | b"M4B " | b"M4P " | b"F4A " | b"F4B " => Format::M4a,
        b"M4V " | b"M4VH" | b"M4VP" => Format::M4v,
        b"mif1" | b"msf1" => {
            if brands.iter().any(|b| b.starts_with(b"avi")) {
                Format::Avif
            } else {
                Format::Heic
            }
        }
        _ if major.starts_with(b"3g") => Format::ThreeGp,
        _ => Format::Mp4,
    }
}

/// Duration and creation date from `mvhd`, size from the largest track header.
fn movie_details(r: &mut Reader, start: u64, size: u64) -> (Details, Option<Timestamp>) {
    let mut details = Details::default();
    let mut date = None;
    let end = start + size;
    let mut position = start + 8;
    let mut children = 0;
    while position + 8 <= end && children < 512 {
        let (Some(child), Some(kind)) =
            (r.u32be(position).map(u64::from), r.bytes(position + 4, 4))
        else {
            break;
        };
        if child < 8 {
            break;
        }
        match kind.as_slice() {
            b"mvhd" => {
                let long = r.byte(position + 8) == Some(1);
                let created = if long {
                    r.u64be(position + 12)
                } else {
                    r.u32be(position + 12).map(u64::from)
                };
                let scale = r.u32be(position + if long { 28 } else { 20 });
                let length = if long {
                    r.u64be(position + 32)
                } else {
                    r.u32be(position + 24).map(u64::from)
                };
                if let (Some(scale), Some(length)) = (scale, length)
                    && scale > 0
                    && length < u64::MAX / 2
                {
                    details.duration =
                        Some(Duration::from_secs_f64(length as f64 / f64::from(scale)));
                }
                date = created.and_then(quicktime_date);
            }
            b"trak" => {
                if let Some((width, height)) = track_size(r, position, child) {
                    let area =
                        |p: Option<(u32, u32)>| p.map_or(0, |(w, h)| u64::from(w) * u64::from(h));
                    if u64::from(width) * u64::from(height) > area(details.pixels) {
                        details.pixels = Some((width, height));
                    }
                }
            }
            _ => {}
        }
        position += child;
        children += 1;
    }
    (details, date)
}

fn track_size(r: &mut Reader, start: u64, size: u64) -> Option<(u32, u32)> {
    let mut position = start + 8;
    while position + 8 <= start + size {
        let child = r.u32be(position).map(u64::from).filter(|c| *c >= 8)?;
        if r.ascii("tkhd", position + 4) {
            let long = r.byte(position + 8) == Some(1);
            let width = r.u32be(position + if long { 96 } else { 84 })?;
            let height = r.u32be(position + if long { 100 } else { 88 })?;
            return Some((width >> 16, height >> 16));
        }
        position += child;
    }
    None
}

/// Seconds since 1904, as QuickTime counts. Cameras without a clock write
/// zero; anything outside a sane range is ignored.
pub fn quicktime_date(seconds: u64) -> Option<Timestamp> {
    let date = Timestamp::from_unix(seconds as i64 - 2_082_844_800);
    (1995..=2100).contains(&date.year).then_some(date)
}

// MARK: RIFF (AVI, WAV, WebP)

pub fn riff(r: &mut Reader, start: u64) -> Option<Carved> {
    if !r.ascii("RIFF", start) {
        return None;
    }
    let declared = r.u32le(start + 4).filter(|d| *d >= 4)?;
    let form = r.bytes(start + 8, 4)?;
    // Chunks are padded to an even size.
    let mut length = 8 + u64::from(declared) + u64::from(declared & 1);
    let carved = match form.as_slice() {
        b"WEBP" => {
            if !["VP8 ", "VP8L", "VP8X"]
                .iter()
                .any(|chunk| r.ascii(chunk, start + 12))
                || length > JPEG_LIMIT
            {
                return None;
            }
            Carved::new(Format::Webp, length)
        }
        b"AVI " => {
            if !(r.ascii("LIST", start + 12) && r.ascii("hdrl", start + 20)) {
                return None;
            }
            // Recordings over 1 GB continue in extra `RIFF AVIX` chunks.
            while start + length + 12 <= r.size()
                && length < VIDEO_LIMIT
                && r.ascii("RIFF", start + length)
                && r.ascii("AVIX", start + length + 8)
            {
                let Some(more) = r.u32le(start + length + 4) else {
                    break;
                };
                length += 8 + u64::from(more) + u64::from(more & 1);
            }
            Carved::new(Format::Avi, length)
        }
        b"WAVE" => {
            if !r.ascii("fmt ", start + 12) {
                return None;
            }
            let rate = r.u32le(start + 28)?;
            let mut carved = Carved::new(Format::Wav, length);
            if rate > 0 {
                carved.details.duration = Some(Duration::from_secs_f64(
                    length.saturating_sub(44) as f64 / f64::from(rate),
                ));
            }
            carved
        }
        _ => return None,
    };
    Some(fit(carved, r, start))
}

/// A file running past the end of the disk lost its tail.
fn fit(carved: Carved, r: &Reader, start: u64) -> Carved {
    if start + carved.length <= r.size() {
        return carved;
    }
    Carved {
        length: r.size() - start,
        ..carved
    }
    .damaged()
}

// MARK: Matroska and WebM

const SEGMENT_CHILDREN: [u64; 10] = [
    0x114D_9B74,
    0x1549_A966,
    0x1654_AE6B,
    0x1F43_B675,
    0x1C53_BB6B,
    0x1043_A770,
    0x1254_C367,
    0x1941_A469,
    0xEC,
    0xBF,
];
const CLUSTER: u64 = 0x1F43_B675;

pub fn matroska(r: &mut Reader, start: u64) -> Option<Carved> {
    if !r.matches(&[0x1A, 0x45, 0xDF, 0xA3], start) {
        return None;
    }
    let header = ebml_size(r, start + 4).filter(|h| !h.unknown && h.value < 4096)?;
    let header_end = start + 4 + header.width + header.value;
    let mut doc_type = None;
    let mut position = start + 4 + header.width;
    while position < header_end {
        let Some((id, id_width)) = element_id(r, position) else {
            break;
        };
        let Some(element) = ebml_size(r, position + id_width) else {
            break;
        };
        let data = position + id_width + element.width;
        if id == 0x4282 && element.value < 32 {
            let bytes = r.bytes(data, element.value as usize)?;
            doc_type = Some(
                String::from_utf8_lossy(bytes.split(|b| *b == 0).next().unwrap_or(&[]))
                    .into_owned(),
            );
        }
        position = data + element.value;
    }
    let format = match doc_type.as_deref() {
        Some("webm") => Format::Webm,
        Some("matroska") => Format::Mkv,
        _ => return None,
    };
    if !r.matches(&[0x18, 0x53, 0x80, 0x67], header_end) {
        return None;
    }
    let segment = ebml_size(r, header_end + 4)?;
    let body = header_end + 4 + segment.width;
    let limit = r.size().min(start + VIDEO_LIMIT);
    if !segment.unknown {
        return Some(fit(
            Carved::new(format, body + segment.value - start),
            r,
            start,
        ));
    }
    // A live recording leaves the size open: walk the segment until
    // something that cannot belong to it.
    position = body;
    while position < limit {
        let Some((id, id_width)) =
            element_id(r, position).filter(|(id, _)| SEGMENT_CHILDREN.contains(id))
        else {
            break;
        };
        let Some(element) = ebml_size(r, position + id_width) else {
            break;
        };
        let data = position + id_width + element.width;
        if element.unknown {
            if id != CLUSTER {
                break;
            }
            position = end_of_open_cluster(r, data, limit);
        } else {
            position = data + element.value;
        }
    }
    (position > body).then(|| Carved::new(format, position.min(limit) - start))
}

/// A cluster of unknown size ends where an element that is not one of its children begins.
fn end_of_open_cluster(r: &mut Reader, offset: u64, limit: u64) -> u64 {
    const CHILDREN: [u64; 7] = [0xE7, 0xA3, 0xA0, 0xA7, 0xAB, 0xEC, 0xBF];
    let mut position = offset;
    while position < limit {
        let Some((id, width)) = element_id(r, position) else {
            break;
        };
        let Some(element) =
            ebml_size(r, position + width).filter(|e| CHILDREN.contains(&id) && !e.unknown)
        else {
            return position;
        };
        position += width + element.width + element.value;
    }
    position
}

/// An element ID keeps its length marker bits, as the spec writes them.
fn element_id(r: &mut Reader, offset: u64) -> Option<(u64, u64)> {
    let first = r.byte(offset).filter(|b| *b != 0)?;
    let width = u64::from(first.leading_zeros()) + 1;
    if width > 4 {
        return None;
    }
    let bytes = r.bytes(offset, width as usize)?;
    Some((bytes.iter().fold(0, |v, b| v << 8 | u64::from(*b)), width))
}

struct EbmlSize {
    value: u64,
    width: u64,
    unknown: bool,
}

/// A size without its marker bit; all ones means "unknown".
fn ebml_size(r: &mut Reader, offset: u64) -> Option<EbmlSize> {
    let first = r.byte(offset).filter(|b| *b != 0)?;
    let width = u64::from(first.leading_zeros()) + 1;
    let bytes = r.bytes(offset, width as usize)?;
    let mask = if width == 8 { 0 } else { 0xFFu64 >> width };
    let value = bytes[1..]
        .iter()
        .fold(u64::from(first) & mask, |v, b| v << 8 | u64::from(*b));
    Some(EbmlSize {
        value,
        width,
        unknown: value == (1u64 << (7 * width)) - 1,
    })
}

// MARK: MP3

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MpegFrame {
    pub length: u64,
    pub samples: u32,
    pub sample_rate: u32,
}

const BITRATES: [[u32; 15]; 5] = [
    [
        0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448,
    ],
    [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384,
    ],
    [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
    ],
    [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256,
    ],
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
];

impl MpegFrame {
    pub fn parse(header: u32) -> Option<Self> {
        if header >> 21 != 0x7FF {
            return None;
        }
        let version = (header >> 19 & 3) as usize;
        let layer = (header >> 17 & 3) as usize;
        let bitrate_index = (header >> 12 & 0xF) as usize;
        let rate_index = (header >> 10 & 3) as usize;
        if version == 1 || layer == 0 || !(1..=14).contains(&bitrate_index) || rate_index == 3 {
            return None;
        }
        let mpeg1 = version == 3;
        let table = if mpeg1 {
            3 - layer
        } else if layer == 3 {
            3
        } else {
            4
        };
        let bitrate = BITRATES[table][bitrate_index] * 1000;
        let shift = if mpeg1 {
            0
        } else if version == 2 {
            1
        } else {
            2
        };
        let rate = [44_100, 48_000, 32_000][rate_index] >> shift;
        let padding = header >> 9 & 1;
        let (length, samples) = match layer {
            3 => ((12 * bitrate / rate + padding) * 4, 384),
            2 => (144 * bitrate / rate + padding, 1152),
            _ => (
                (if mpeg1 { 144 } else { 72 }) * bitrate / rate + padding,
                if mpeg1 { 1152 } else { 576 },
            ),
        };
        Some(Self {
            length: u64::from(length),
            samples,
            sample_rate: rate,
        })
    }
}

/// With an ID3 tag the start is certain; bare frames need a long run of
/// consistent headers before they count, since `FF Ex` is common in any data.
pub fn mp3(r: &mut Reader, start: u64) -> Option<Carved> {
    let mut position = start;
    let tagged = r.ascii("ID3", start);
    if tagged {
        let flags = r.byte(start + 5)?;
        let raw = r
            .bytes(start + 6, 4)
            .filter(|b| b.iter().all(|x| *x < 0x80))?;
        let tag = raw.iter().fold(0u64, |v, b| v << 7 | u64::from(*b));
        position = start + 10 + tag + if flags & 0x10 != 0 { 10 } else { 0 };
        // Some encoders pad the tag with zeros.
        let mut padding = 0;
        while padding < 65_536 && r.byte(position) == Some(0) {
            position += 1;
            padding += 1;
        }
    }
    let limit = r.size().min(start + AUDIO_LIMIT);
    let (mut frames, mut samples, mut rate) = (0u32, 0u64, 0u32);
    while position + 4 <= limit {
        let Some(frame) = r.u32be(position).and_then(MpegFrame::parse) else {
            break;
        };
        if frames > 0 && frame.sample_rate != rate {
            break;
        }
        rate = frame.sample_rate;
        position += frame.length;
        frames += 1;
        samples += u64::from(frame.samples);
    }
    if frames < if tagged { 4 } else { 32 } {
        return None;
    }
    if r.ascii("TAG", position) {
        position += 128;
    }
    let mut carved = Carved::new(Format::Mp3, position.min(limit) - start);
    carved.details.duration = Some(Duration::from_secs_f64(samples as f64 / f64::from(rate)));
    Some(carved)
}
