//! Recovery tested on files made the way apps make them: photos encoded by the
//! `image` crate's real encoders, short videos and audio from ffmpeg in
//! `tests/fixtures/recovery`, and the rest built byte by byte.

use std::collections::HashMap;
use std::io::Cursor;
use std::sync::Arc;

use image::{DynamicImage, ImageFormat, RgbImage};

use super::carver::{self, Progress, Stage};
use super::filesystems::{self, Partition};
use super::found::{Condition, Extent, Format, Origin};
use super::photo::Carved;
use super::reader::{ByteSource, MemorySource, ReadError, Reader};
use super::scanner::RecoveryScan;

const MP4: &[u8] = include_bytes!("../../tests/fixtures/recovery/clip.mp4");
const MOV: &[u8] = include_bytes!("../../tests/fixtures/recovery/clip.mov");
const M4A: &[u8] = include_bytes!("../../tests/fixtures/recovery/tone.m4a");
const HEIC: &[u8] = include_bytes!("../../tests/fixtures/recovery/photo.heic");

fn image(format: ImageFormat, width: u32, height: u32) -> Vec<u8> {
    let pixels = RgbImage::from_fn(width, height, |x, y| {
        image::Rgb([(x * 255 / width) as u8, (y * 255 / height) as u8, ((x * y) % 7 * 36) as u8])
    });
    let mut out = Cursor::new(Vec::new());
    DynamicImage::ImageRgb8(pixels).write_to(&mut out, format).unwrap();
    out.into_inner()
}

fn jpeg(width: u32, height: u32) -> Vec<u8> {
    image(ImageFormat::Jpeg, width, height)
}

fn le16(value: u16) -> [u8; 2] {
    value.to_le_bytes()
}
fn le32(value: u32) -> [u8; 4] {
    value.to_le_bytes()
}
fn le64(value: u64) -> [u8; 8] {
    value.to_le_bytes()
}

fn wav() -> Vec<u8> {
    let rate = 8_000u32;
    let data = rate as usize * 2;
    let mut bytes = b"RIFF".to_vec();
    bytes.extend(le32(36 + data as u32));
    bytes.extend(b"WAVEfmt ");
    bytes.extend(le32(16));
    bytes.extend(le16(1));
    bytes.extend(le16(1));
    bytes.extend(le32(rate));
    bytes.extend(le32(rate * 2));
    bytes.extend(le16(2));
    bytes.extend(le16(16));
    bytes.extend(b"data");
    bytes.extend(le32(data as u32));
    bytes.extend(vec![0x11; data]);
    bytes
}

/// An ID3 tag, then silent MPEG-1 Layer III frames at 128 kbps.
fn mp3(tagged: bool, frames: usize) -> Vec<u8> {
    let mut bytes = if tagged {
        let mut tag = b"ID3".to_vec();
        tag.extend([3, 0, 0, 0, 0, 0, 10]);
        tag.extend([0; 10]);
        tag
    } else {
        Vec::new()
    };
    for index in 0..frames {
        // 44.1 kHz frames alternate between 417 and 418 bytes with padding.
        let padded = index % 3 == 0;
        bytes.extend([0xFF, 0xFB, if padded { 0x92 } else { 0x90 }, 0x64]);
        bytes.extend(vec![0x55; if padded { 418 } else { 417 } - 4]);
    }
    bytes
}

fn webm(known_size: bool) -> Vec<u8> {
    let doc_type = [&[0x42, 0x82, 0x84][..], b"webm"].concat();
    let mut header = vec![0x1A, 0x45, 0xDF, 0xA3, 0x80 | doc_type.len() as u8];
    header.extend(&doc_type);
    let info = [0x15, 0x49, 0xA9, 0x66, 0x85, 0x2A, 0xD7, 0xB1, 0x81, 0x01];
    let blocks = [0xA3, 0x84, 0x81, 0x00, 0x00, 0x80];
    let mut cluster = vec![0x1F, 0x43, 0xB6, 0x75, 0x80 | (blocks.len() + 3) as u8, 0xE7, 0x81, 0x00];
    cluster.extend(blocks);
    let body = [&info[..], &cluster].concat();
    let mut bytes = header;
    bytes.extend([0x18, 0x53, 0x80, 0x67]);
    bytes.push(if known_size { 0x80 | body.len() as u8 } else { 0xFF });
    bytes.extend(body);
    bytes
}

fn avi() -> Vec<u8> {
    let mut list = b"LIST".to_vec();
    list.extend(le32(4 + 64));
    list.extend(b"hdrl");
    list.extend([0x22; 64]);
    let mut movi = b"LIST".to_vec();
    movi.extend(le32(4 + 1000));
    movi.extend(b"movi");
    movi.extend([0x33; 1000]);
    let body = [&b"AVI "[..], &list, &movi].concat();
    let mut bytes = b"RIFF".to_vec();
    bytes.extend(le32(body.len() as u32));
    bytes.extend(body);
    bytes
}

fn pdf(updated: bool) -> Vec<u8> {
    let mut text = String::from(
        "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\nxref\n0 3\n0000000000 65535 f \ntrailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n120\n%%EOF\n",
    );
    if updated {
        text.push_str("12 0 obj\n<< /Type /Annot >>\nendobj\nxref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 13 >>\nstartxref\n9\n%%EOF\n");
    }
    text.into_bytes()
}

/// A stored (uncompressed) ZIP with these entries.
fn zip(entries: &[(&str, &str)]) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut central = Vec::new();
    for (name, text) in entries {
        let offset = bytes.len() as u32;
        let content = text.as_bytes();
        let crc = crc32(content);
        let mut header = Vec::new();
        for value in [20u16, 0, 0, 0, 0] {
            header.extend(le16(value));
        }
        header.extend(le32(crc));
        header.extend(le32(content.len() as u32));
        header.extend(le32(content.len() as u32));
        bytes.extend([0x50, 0x4B, 0x03, 0x04]);
        bytes.extend(&header);
        bytes.extend(le16(name.len() as u16));
        bytes.extend(le16(0));
        bytes.extend(name.as_bytes());
        bytes.extend(content);
        central.extend([0x50, 0x4B, 0x01, 0x02]);
        central.extend(le16(20));
        central.extend(&header);
        central.extend(le16(name.len() as u16));
        for value in [0u16, 0, 0, 0] {
            central.extend(le16(value));
        }
        central.extend(le32(0));
        central.extend(le32(offset));
        central.extend(name.as_bytes());
    }
    let directory = bytes.len() as u32;
    bytes.extend(&central);
    bytes.extend([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0]);
    bytes.extend(le16(entries.len() as u16));
    bytes.extend(le16(entries.len() as u16));
    bytes.extend(le32(central.len() as u32));
    bytes.extend(le32(directory));
    bytes.extend(le16(0));
    bytes
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

/// Pseudo-random bytes with a fixed seed: realistic noise between files.
fn noise(count: usize, seed: u64) -> Vec<u8> {
    let mut state = seed;
    (0..count)
        .map(|_| {
            state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            (state >> 33) as u8
        })
        .collect()
}

/// Lays files out like a file system would: each on a block boundary, with
/// leftovers of older data in between.
#[derive(Default)]
struct DiskLayout {
    bytes: Vec<u8>,
}

impl DiskLayout {
    fn align(&mut self) {
        let rest = self.bytes.len() % 512;
        if rest != 0 {
            self.bytes.extend(vec![0; 512 - rest]);
        }
    }

    fn gap(&mut self, count: usize) {
        let seed = self.bytes.len() as u64 + 1;
        self.bytes.extend(noise(count, seed));
        self.align();
    }

    fn place(&mut self, file: &[u8]) -> u64 {
        self.align();
        let offset = self.bytes.len() as u64;
        self.bytes.extend_from_slice(file);
        // The rest of the last block holds whatever was there before.
        let tail = (512 - self.bytes.len() % 512) % 512;
        self.bytes.extend(noise(tail, offset + 7));
        offset
    }
}

fn found(bytes: Vec<u8>, skipping: &[std::ops::Range<u64>]) -> HashMap<u64, Carved> {
    let mut files = HashMap::new();
    carver::scan(&MemorySource(bytes), None, skipping, &Progress::default(), |carved, offset| {
        files.insert(offset, carved);
    })
    .unwrap();
    files
}

#[test]
fn finds_every_format_with_its_exact_length() {
    let files: Vec<(Format, Vec<u8>)> = vec![
        (Format::Jpeg, jpeg(96, 64)),
        (Format::Png, image(ImageFormat::Png, 96, 64)),
        (Format::Gif, image(ImageFormat::Gif, 96, 64)),
        (Format::Bmp, image(ImageFormat::Bmp, 96, 64)),
        (Format::Tiff, image(ImageFormat::Tiff, 96, 64)),
        (Format::Webp, image(ImageFormat::WebP, 96, 64)),
        (Format::Heic, HEIC.to_vec()),
        (Format::Mp4, MP4.to_vec()),
        (Format::Mov, MOV.to_vec()),
        (Format::M4a, M4A.to_vec()),
        (Format::Wav, wav()),
        (Format::Mp3, mp3(true, 40)),
        (Format::Webm, webm(true)),
        (Format::Avi, avi()),
        (Format::Pdf, pdf(false)),
        (Format::Docx, zip(&[("[Content_Types].xml", "<Types/>"), ("word/document.xml", "<w:document/>")])),
        (Format::Zip, zip(&[("notes.txt", "hello"), ("more/data.csv", "1,2,3")])),
    ];
    let mut disk = DiskLayout::default();
    let mut expected = HashMap::new();
    for (format, bytes) in &files {
        disk.gap(1536);
        expected.insert(disk.place(bytes), (*format, bytes.len() as u64));
    }
    disk.gap(4096);
    let found = found(disk.bytes, &[]);
    for (offset, (format, length)) in &expected {
        let carved = found.get(offset).unwrap_or_else(|| panic!("{format:?} at {offset} was not found"));
        assert_eq!(carved.format, *format);
        assert_eq!(carved.length, *length, "{format:?}");
        assert_eq!(carved.condition, Condition::Good, "{format:?}");
    }
    let invented: Vec<_> = found.keys().filter(|offset| !expected.contains_key(offset)).collect();
    assert!(invented.is_empty(), "found files in the noise at {invented:?}");
}

#[test]
fn reads_sizes_and_durations() {
    let mut disk = DiskLayout::default();
    let photo = disk.place(&jpeg(120, 80));
    let movie = disk.place(MP4);
    let song = disk.place(&mp3(true, 380));
    disk.gap(2048);
    let found = found(disk.bytes, &[]);
    assert_eq!(found[&photo].details.pixels, Some((120, 80)));
    assert_eq!(found[&movie].details.pixels, Some((64, 48)));
    assert!((found[&movie].details.duration.unwrap().as_secs_f64() - 1.0).abs() < 0.1);
    // 380 frames of 1152 samples at 44.1 kHz.
    assert!((found[&song].details.duration.unwrap().as_secs_f64() - 9.93).abs() < 0.01);
}

#[test]
fn a_photo_cut_short_is_kept_and_what_follows_is_still_found() {
    let photo = jpeg(300, 200);
    let mut disk = DiskLayout::default();
    let mut cut = photo[..photo.len() / 2].to_vec();
    cut.extend(vec![0; 4096]);
    let damaged = disk.place(&cut);
    let png = disk.place(&image(ImageFormat::Png, 40, 30));
    disk.gap(1024);
    let found = found(disk.bytes, &[]);
    assert_eq!(found[&damaged].format, Format::Jpeg);
    assert_eq!(found[&damaged].condition, Condition::Damaged);
    assert!(found[&damaged].length >= photo.len() as u64 / 2);
    assert_eq!(found[&png].format, Format::Png);
}

#[test]
fn thumbnails_inside_a_photo_are_not_reported_separately() {
    let inner = jpeg(32, 24);
    let mut outer = jpeg(400, 300);
    let mut comment = vec![0x20; 512 - 6];
    comment.extend(&inner);
    let length = (comment.len() + 2) as u16;
    let mut segment = vec![0xFF, 0xFE];
    segment.extend(length.to_be_bytes());
    segment.extend(comment);
    outer.splice(2..2, segment);
    let mut disk = DiskLayout::default();
    let offset = disk.place(&outer);
    disk.gap(512);
    let found = found(disk.bytes, &[]);
    assert_eq!(found.len(), 1);
    assert_eq!(found[&offset].length, outer.len() as u64);
}

#[test]
fn edited_pdfs_and_open_recordings_are_measured() {
    let mut disk = DiskLayout::default();
    let updated = pdf(true);
    let document = disk.place(&updated);
    let live = webm(false);
    let recording = disk.place(&live);
    disk.gap(1024);
    let found = found(disk.bytes, &[]);
    assert_eq!(found[&document].length, updated.len() as u64);
    assert_eq!(found[&recording].format, Format::Webm);
    assert_eq!(found[&recording].length, live.len() as u64);
}

#[test]
fn bare_mp3_frames_need_a_long_run() {
    let mut disk = DiskLayout::default();
    let short = disk.place(&mp3(false, 8));
    disk.gap(512);
    let long = disk.place(&mp3(false, 64));
    disk.gap(512);
    let found = found(disk.bytes, &[]);
    assert!(!found.contains_key(&short));
    assert_eq!(found[&long].format, Format::Mp3);
}

#[test]
fn live_files_are_skipped() {
    let mut disk = DiskLayout::default();
    let kept = disk.place(&jpeg(64, 48));
    let live = disk.place(&image(ImageFormat::Png, 64, 48));
    disk.gap(512);
    let found = found(disk.bytes, &[live..live + 512]);
    assert!(found.contains_key(&kept));
    assert!(!found.contains_key(&live));
}

/// A source with a patch that cannot be read, or that vanishes.
struct Flaky {
    inner: MemorySource,
    bad: std::ops::Range<u64>,
    gone: bool,
}

impl ByteSource for Flaky {
    fn size(&self) -> u64 {
        self.inner.size()
    }
    fn block_size(&self) -> usize {
        512
    }
    fn read_at(&self, buffer: &mut [u8], offset: u64) -> Result<usize, ReadError> {
        let end = offset + buffer.len() as u64;
        if self.bad.start < end && offset < self.bad.end {
            return Err(if self.gone { ReadError::Disconnected } else { ReadError::Unreadable });
        }
        self.inner.read_at(buffer, offset)
    }
}

#[test]
fn unreadable_blocks_are_counted_and_passed_over() {
    let mut disk = DiskLayout::default();
    disk.gap(256 * 1024);
    let after = disk.place(&jpeg(64, 48));
    disk.gap(512);
    let source = Flaky {
        inner: MemorySource(disk.bytes),
        bad: 64 * 1024..128 * 1024,
        gone: false,
    };
    let progress = Progress::default();
    let mut offsets = Vec::new();
    carver::scan(&source, None, &[], &progress, |_, offset| offsets.push(offset)).unwrap();
    assert_eq!(offsets, vec![after]);
    assert_eq!(progress.unreadable().0, 64 * 1024);

    let gone = Flaky {
        inner: MemorySource(vec![0; 1 << 20]),
        bad: 0..1,
        gone: true,
    };
    assert_eq!(carver::scan(&gone, None, &[], &Progress::default(), |_, _| {}), Err(ReadError::Disconnected));
}

#[test]
fn classifies_iso_media_brands() {
    let brands = |list: &[&[u8; 4]]| list.iter().map(|b| b.to_vec()).collect::<Vec<_>>();
    assert_eq!(super::media::classify(&brands(&[b"heic", b"mif1"])), Format::Heic);
    assert_eq!(super::media::classify(&brands(&[b"mif1", b"avif"])), Format::Avif);
    assert_eq!(super::media::classify(&brands(&[b"qt  "])), Format::Mov);
    assert_eq!(super::media::classify(&brands(&[b"crx "])), Format::Cr3);
    assert_eq!(super::media::classify(&brands(&[b"M4A ", b"isom"])), Format::M4a);
    assert_eq!(super::media::classify(&brands(&[b"3gp4"])), Format::ThreeGp);
    assert_eq!(super::media::classify(&brands(&[b"isom", b"avc1"])), Format::Mp4);
    assert_eq!(super::media::quicktime_date(0), None);
    assert_eq!(super::media::quicktime_date(3_803_976_000).map(|d| d.year), Some(2024));
}

// MARK: FAT32 and exFAT, built in memory

/// A FAT32 volume with 512-byte sectors and clusters.
struct Fat32 {
    bytes: Vec<u8>,
}

impl Fat32 {
    const RESERVED: usize = 32;
    const CLUSTERS: usize = 65_600;
    const FAT_SECTORS: usize = ((Self::CLUSTERS + 2) * 4).div_ceil(512);
    const DATA_SECTOR: usize = Self::RESERVED + 2 * Self::FAT_SECTORS;

    fn new() -> Self {
        let mut image = Self {
            bytes: vec![0; (Self::DATA_SECTOR + Self::CLUSTERS) * 512],
        };
        image.bytes[..3].copy_from_slice(&[0xEB, 0x58, 0x90]);
        image.put(11, &le16(512));
        image.bytes[13] = 1;
        image.put(14, &le16(Self::RESERVED as u16));
        image.bytes[16] = 2;
        image.bytes[21] = 0xF8;
        image.put(32, &le32((Self::DATA_SECTOR + Self::CLUSTERS) as u32));
        image.put(36, &le32(Self::FAT_SECTORS as u32));
        image.put(44, &le32(2));
        image.put(82, b"FAT32   ");
        image.put(510, &[0x55, 0xAA]);
        image.set_fat(0, 0x0FFF_FFF8);
        image.set_fat(1, 0x0FFF_FFFF);
        image.set_fat(2, 0x0FFF_FFFF);
        image
    }

    fn put(&mut self, at: usize, value: &[u8]) {
        self.bytes[at..at + value.len()].copy_from_slice(value);
    }

    fn offset(cluster: usize) -> usize {
        (Self::DATA_SECTOR + cluster - 2) * 512
    }

    fn set_fat(&mut self, cluster: usize, value: u32) {
        self.put(Self::RESERVED * 512 + cluster * 4, &le32(value));
    }

    /// Writes `content` from `cluster` on; a live file also gets its chain.
    fn store(&mut self, content: &[u8], cluster: usize, live: bool) {
        self.put(Self::offset(cluster), content);
        if live {
            let count = content.len().div_ceil(512);
            for index in 0..count {
                let next = if index == count - 1 { 0x0FFF_FFFF } else { (cluster + index + 1) as u32 };
                self.set_fat(cluster + index, next);
            }
        }
    }

    /// A 32-byte short entry; `deleted` replaces the first letter with 0xE5.
    fn short_entry(name: &str, cluster: usize, size: usize, folder: bool, deleted: bool, lowercase: bool) -> Vec<u8> {
        let (base, ext) = if name == "." { (".", "") } else { name.split_once('.').unwrap_or((name, "")) };
        let mut entry = format!("{base:<8}{ext:<3}").into_bytes();
        if deleted {
            entry[0] = 0xE5;
        }
        entry.push(if folder { 0x10 } else { 0x20 });
        entry.push(if lowercase { 0x18 } else { 0 });
        entry.extend([0; 19]);
        entry[20..22].copy_from_slice(&le16((cluster >> 16) as u16));
        // 14 July 2024, 18:22:30.
        entry[22..24].copy_from_slice(&le16(18 << 11 | 22 << 5 | 15));
        entry[24..26].copy_from_slice(&le16((2024 - 1980) << 9 | 7 << 5 | 14));
        entry[26..28].copy_from_slice(&le16((cluster & 0xFFFF) as u16));
        entry[28..32].copy_from_slice(&le32(size as u32));
        entry
    }

    /// Long name entries for `name`, last part first, as stored on disk.
    fn long_entries(name: &str, short: &str, deleted: bool) -> Vec<u8> {
        let raw = &Self::short_entry(short, 0, 0, false, false, false)[..11];
        let checksum = raw.iter().fold(0u8, |sum, byte| ((sum & 1) << 7 | sum >> 1).wrapping_add(*byte));
        let mut units: Vec<u16> = name.encode_utf16().chain([0]).collect();
        while !units.len().is_multiple_of(13) {
            units.push(0xFFFF);
        }
        let parts = units.len() / 13;
        let mut entries = Vec::new();
        for part in (0..parts).rev() {
            let mut entry = vec![0u8; 32];
            entry[0] = if deleted { 0xE5 } else { (part + 1) as u8 | if part == parts - 1 { 0x40 } else { 0 } };
            entry[11] = 0x0F;
            entry[13] = checksum;
            for (index, unit) in units[part * 13..part * 13 + 13].iter().enumerate() {
                let position = match index {
                    0..5 => 1 + index * 2,
                    5..11 => 14 + (index - 5) * 2,
                    _ => 28 + (index - 11) * 2,
                };
                entry[position..position + 2].copy_from_slice(&unit.to_le_bytes());
            }
            entries.extend(entry);
        }
        entries
    }
}

#[test]
fn deleted_fat_files_come_back_with_their_names() {
    let mut image = Fat32::new();
    let photo = jpeg(96, 64);
    let song = mp3(true, 40);
    // A live photo now sits in cluster 10, where OLD.PNG used to be.
    image.store(&photo, 10, true);
    image.store(&photo, 100, false);
    image.store(&photo, 200, false);
    image.store(&song, 300, false);
    image.store(&photo, 500, false);

    let mut root = Fat32::short_entry("LIVE.JPG", 10, photo.len(), false, false, false);
    root.extend(Fat32::short_entry("IMG_0002.JPG", 100, photo.len(), false, true, false));
    root.extend(Fat32::long_entries("Holiday photo.jpg", "HOLIDA~1.JPG", true));
    root.extend(Fat32::short_entry("HOLIDA~1.JPG", 200, photo.len(), false, true, false));
    root.extend(Fat32::short_entry("SONG.MP3", 300, song.len(), false, true, true));
    root.extend(Fat32::short_entry("OLD.PNG", 10, 4096, false, true, false));
    root.extend(Fat32::long_entries("._IMG_0002.JPG", "_IMG_0~1.JPG", true));
    root.extend(Fat32::short_entry("_IMG_0~1.JPG", 700, 4096, false, true, false));
    root.extend(Fat32::short_entry("TRIP", 400, 0, true, true, false));
    image.put(Fat32::offset(2), &root);
    image.set_fat(2, 3);
    image.set_fat(3, 0x0FFF_FFFF);
    let mut trip = Fat32::short_entry(".", 400, 0, true, false, false);
    trip.extend(Fat32::short_entry("DSC_0001.JPG", 500, photo.len(), false, true, false));
    image.put(Fat32::offset(400), &trip);

    let source = MemorySource(image.bytes);
    let scan = filesystems::scan(&source, Partition { offset: 0, length: source.size() }, &|| false).unwrap();
    assert_eq!(scan.format, "FAT32");
    let by_name: HashMap<String, _> = scan.files.iter().map(|f| (f.name.clone().unwrap(), f)).collect();
    let mut names: Vec<&str> = by_name.keys().map(String::as_str).collect();
    names.sort_unstable();
    assert_eq!(names, ["DSC_0001.JPG", "Holiday photo.jpg", "IMG_0002.JPG", "_LD.PNG", "_ong.mp3"]);
    let photo_file = by_name["IMG_0002.JPG"];
    assert_eq!(photo_file.extents, vec![Extent { offset: Fat32::offset(100) as u64, length: photo.len() as u64 }]);
    assert_eq!(photo_file.condition, Condition::Good);
    assert_eq!(photo_file.date.map(|d| (d.year, d.month, d.day, d.hour, d.minute)), Some((2024, 7, 14, 18, 22)));
    assert_eq!(by_name["DSC_0001.JPG"].folder.as_deref(), Some("/_RIP/"));
    assert_eq!(by_name["_LD.PNG"].condition, Condition::Overwritten);
    let live = Fat32::offset(10) as u64;
    assert!(filesystems::overlaps(live..live + 512, &scan.allocated));
    let deleted = Fat32::offset(100) as u64;
    assert!(!filesystems::overlaps(deleted..deleted + 512, &scan.allocated));
}

#[test]
fn a_whole_scan_merges_named_and_found_files() {
    let mut image = Fat32::new();
    let photo = jpeg(96, 64);
    image.store(&photo, 100, false);
    // A photo from before the card was formatted: no entry at all.
    image.store(&jpeg(50, 40), 900, false);
    let root = Fat32::short_entry("IMG_0042.JPG", 100, photo.len(), false, true, false);
    image.put(Fat32::offset(2), &root);

    let scan = RecoveryScan::new(Arc::new(MemorySource(image.bytes)));
    scan.run().unwrap();
    let files = scan.collect();
    assert_eq!(files.len(), 2);
    let named = files.iter().find(|f| f.origin == Origin::Directory).unwrap();
    // The lost first letter comes back from the camera's naming pattern.
    assert_eq!(named.name.as_deref(), Some("IMG_0042.JPG"));
    assert_eq!(named.format, Some(Format::Jpeg));
    assert_eq!(named.details.pixels, Some((96, 64)));
    let carved = files.iter().find(|f| f.origin == Origin::Contents).unwrap();
    assert_eq!(carved.offset(), Fat32::offset(900) as u64);
    assert_ne!(named.id, carved.id);
    assert_eq!(scan.progress().stage(), Stage::Finished);
    assert_eq!(scan.file_systems(), ["FAT32"]);
}

#[test]
fn lost_first_letters_come_back_when_the_pattern_says_so() {
    use filesystems::restore_first_letter as restore;
    let siblings = ["IMG_0001.JPG".to_string(), "IMG_0003.JPG".to_string()];
    assert_eq!(restore("_MG_0002.JPG", &siblings), "IMG_0002.JPG");
    assert_eq!(restore("_SC_0100.JPG", &[]), "DSC_0100.JPG");
    assert_eq!(restore("_lip.mp4", &["notes.txt".into()]), "_lip.mp4");
    assert_eq!(restore("_AT_1.TXT", &["CAT_2.TXT".into(), "BAT_3.TXT".into()]), "_AT_1.TXT");
}

/// An exFAT volume with 512-byte sectors and clusters.
struct ExFat {
    bytes: Vec<u8>,
}

impl ExFat {
    const FAT_SECTOR: usize = 24;
    const HEAP_SECTOR: usize = 64;
    const CLUSTERS: usize = 1000;

    fn new() -> Self {
        let mut image = Self {
            bytes: vec![0; (Self::HEAP_SECTOR + Self::CLUSTERS) * 512],
        };
        image.put(0, &[0xEB, 0x76, 0x90]);
        image.put(3, b"EXFAT   ");
        image.put(72, &le64((Self::HEAP_SECTOR + Self::CLUSTERS) as u64));
        image.put(80, &le32(Self::FAT_SECTOR as u32));
        image.put(84, &le32(8));
        image.put(88, &le32(Self::HEAP_SECTOR as u32));
        image.put(92, &le32(Self::CLUSTERS as u32));
        image.put(96, &le32(4));
        image.bytes[108] = 9;
        image.put(510, &[0x55, 0xAA]);
        image
    }

    fn put(&mut self, at: usize, value: &[u8]) {
        self.bytes[at..at + value.len()].copy_from_slice(value);
    }

    fn offset(cluster: usize) -> usize {
        (Self::HEAP_SECTOR + cluster - 2) * 512
    }

    fn chain(&mut self, clusters: &[usize]) {
        for (index, cluster) in clusters.iter().enumerate() {
            let next = clusters.get(index + 1).map_or(0xFFFF_FFFF, |c| *c as u32);
            self.put(Self::FAT_SECTOR * 512 + cluster * 4, &le32(next));
        }
    }

    /// A file's directory entry set: file, stream extension and names.
    fn file_set(name: &str, cluster: usize, size: usize, contiguous: bool, deleted: bool) -> Vec<u8> {
        let units: Vec<u16> = name.encode_utf16().collect();
        let names = units.len().div_ceil(15);
        let mut file = vec![0u8; 32];
        file[0] = if deleted { 0x05 } else { 0x85 };
        file[1] = (1 + names) as u8;
        file[4..6].copy_from_slice(&le16(0x20));
        let stamp: u32 = (2024 - 1980) << 25 | 7 << 21 | 14 << 16 | 18 << 11 | 22 << 5;
        file[12..16].copy_from_slice(&le32(stamp));
        let mut stream = vec![0u8; 32];
        stream[0] = if deleted { 0x40 } else { 0xC0 };
        stream[1] = if contiguous { 0x03 } else { 0x01 };
        stream[3] = units.len() as u8;
        stream[8..16].copy_from_slice(&le64(size as u64));
        stream[20..24].copy_from_slice(&le32(cluster as u32));
        stream[24..32].copy_from_slice(&le64(size as u64));
        let mut entries = [file, stream].concat();
        for part in 0..names {
            let mut entry = vec![0u8; 32];
            entry[0] = if deleted { 0x41 } else { 0xC1 };
            for (index, unit) in units.iter().skip(part * 15).take(15).enumerate() {
                entry[2 + index * 2..4 + index * 2].copy_from_slice(&le16(*unit));
            }
            entries.extend(entry);
        }
        entries
    }
}

#[test]
fn deleted_exfat_files_keep_names_and_fragments() {
    let mut image = ExFat::new();
    let photo = jpeg(96, 64);
    let photo_clusters = photo.len().div_ceil(512);
    // The bitmap in cluster 2 marks itself, the root (4) and the live file (10…).
    let mut bitmap = vec![0u8; 125];
    for cluster in [2, 4].into_iter().chain(10..10 + photo_clusters) {
        bitmap[(cluster - 2) / 8] |= 1 << ((cluster - 2) % 8);
    }
    image.put(ExFat::offset(2), &bitmap);
    image.chain(&[4]);
    image.put(ExFat::offset(10), &photo);
    image.put(ExFat::offset(100), &photo);
    // A deleted file in two pieces, linked through the FAT.
    let pieces = noise(2048, 9);
    image.put(ExFat::offset(200), &pieces[..1024]);
    image.put(ExFat::offset(300), &pieces[1024..]);
    image.chain(&[200, 201, 300, 301]);
    let mut bitmap_entry = vec![0u8; 32];
    bitmap_entry[0] = 0x81;
    bitmap_entry[20..24].copy_from_slice(&le32(2));
    bitmap_entry[24..32].copy_from_slice(&le64(125));
    let mut root = bitmap_entry;
    root.extend(ExFat::file_set("live.jpg", 10, photo.len(), true, false));
    root.extend(ExFat::file_set("Summer holiday photo.jpg", 100, photo.len(), true, true));
    root.extend(ExFat::file_set("split.bin", 200, 2048, false, true));
    image.put(ExFat::offset(4), &root);

    let source = MemorySource(image.bytes);
    let scan = filesystems::scan(&source, Partition { offset: 0, length: source.size() }, &|| false).unwrap();
    assert_eq!(scan.format, "exFAT");
    let by_name: HashMap<String, _> = scan.files.iter().map(|f| (f.name.clone().unwrap(), f)).collect();
    assert_eq!(by_name.len(), 2);
    assert_eq!(
        by_name["Summer holiday photo.jpg"].extents,
        vec![Extent { offset: ExFat::offset(100) as u64, length: photo.len() as u64 }]
    );
    assert_eq!(
        by_name["split.bin"].extents,
        vec![
            Extent { offset: ExFat::offset(200) as u64, length: 1024 },
            Extent { offset: ExFat::offset(300) as u64, length: 1024 },
        ]
    );
    let live = ExFat::offset(10) as u64;
    assert!(filesystems::overlaps(live..live + 512, &scan.allocated));
}

#[test]
fn partition_tables_are_read() {
    // MBR with one FAT32 partition.
    let mut disk = vec![0u8; 4 << 20];
    disk[446 + 4] = 0x0C;
    disk[446 + 8..446 + 12].copy_from_slice(&le32(2048));
    disk[446 + 12..446 + 16].copy_from_slice(&le32(4096));
    disk[510..512].copy_from_slice(&[0x55, 0xAA]);
    let source = MemorySource(disk.clone());
    assert_eq!(
        filesystems::partitions(&mut Reader::new(&source), 512),
        [Partition { offset: 2048 * 512, length: 4096 * 512 }]
    );
    // GPT behind a protective MBR.
    disk[446 + 4] = 0xEE;
    disk[512..520].copy_from_slice(b"EFI PART");
    disk[512 + 72..512 + 80].copy_from_slice(&le64(2));
    disk[512 + 80..512 + 84].copy_from_slice(&le32(4));
    disk[512 + 84..512 + 88].copy_from_slice(&le32(128));
    disk[1024..1040].copy_from_slice(&[0xAB; 16]);
    disk[1024 + 32..1024 + 40].copy_from_slice(&le64(40));
    disk[1024 + 40..1024 + 48].copy_from_slice(&le64(4039));
    let source = MemorySource(disk);
    assert_eq!(
        filesystems::partitions(&mut Reader::new(&source), 512),
        [Partition { offset: 40 * 512, length: 4000 * 512 }]
    );
    // A card formatted without a table.
    let card = MemorySource(Fat32::new().bytes);
    assert_eq!(filesystems::partitions(&mut Reader::new(&card), 512).len(), 1);
}

#[test]
fn exported_files_match_the_originals() {
    let photo = jpeg(80, 60);
    let mut disk = DiskLayout::default();
    let offset = disk.place(&photo);
    disk.gap(1024);
    let scan = RecoveryScan::new(Arc::new(MemorySource(disk.bytes)));
    scan.run().unwrap();
    let files = scan.collect();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].offset(), offset);
    let destination = std::env::temp_dir().join(format!("procmon-export-{}", std::process::id()));
    let report = super::export(&files, scan.source().as_ref(), "card", &destination, &super::ExportProgress::default()).unwrap();
    assert_eq!(report.saved, 1);
    assert!(report.failures.is_empty());
    let saved = report.folder.join("Photos").join(files[0].display_name());
    assert_eq!(std::fs::read(&saved).unwrap(), photo);
    std::fs::remove_dir_all(destination).ok();
}

/// Scans a real disk image and saves everything found:
/// `RECOVER_IMAGE=card.img RECOVER_OUT=/tmp/out cargo test recover_live -- --ignored --nocapture`.
#[test]
#[ignore]
fn recover_live() {
    let image = std::env::var("RECOVER_IMAGE").unwrap();
    let device = super::RawDevice::open(std::path::Path::new(&image)).unwrap();
    let scan = RecoveryScan::new(Arc::new(device));
    let started = std::time::Instant::now();
    scan.run().unwrap();
    let mut files = scan.collect();
    files.sort_by_key(super::FoundFile::offset);
    println!("{} bytes in {:?}; {:?}; {} files", scan.source().size(), started.elapsed(), scan.file_systems(), files.len());
    for file in &files {
        println!(
            "  {:?} {:?} {} {} bytes at {} {:?} {}",
            file.origin,
            file.format,
            file.display_name(),
            file.size().0,
            file.offset(),
            file.condition,
            file.details.summary().unwrap_or_default()
        );
    }
    if let Ok(out) = std::env::var("RECOVER_OUT") {
        let report = super::export(&files, scan.source().as_ref(), "image", std::path::Path::new(&out), &super::ExportProgress::default()).unwrap();
        println!("saved {} to {}", report.saved, report.folder.display());
    }
}

#[test]
fn thumbnails_are_bgra_and_small() {
    let png = image(ImageFormat::Png, 400, 300);
    let mut disk = DiskLayout::default();
    disk.place(&png);
    let scan = RecoveryScan::new(Arc::new(MemorySource(disk.bytes)));
    scan.run().unwrap();
    let file = scan.collect().remove(0);
    let preview = super::thumbnail(&file, scan.source().as_ref(), 120).unwrap();
    assert!(preview.image.width() <= 120 && preview.image.height() <= 120);
    assert_eq!(preview.pixels, Some((400, 300)));
    // The top-right corner is red with no blue; in BGRA order red comes third.
    let corner = preview.image.get_pixel(preview.image.width() - 1, 0).0;
    assert!(corner[2] > 200 && corner[0] < 100, "{corner:?}");
    assert!(!super::has_preview(Some(Format::Heic)));
}
