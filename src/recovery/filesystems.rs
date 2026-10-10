//! Deleted files with their names, from FAT and exFAT: the file systems on
//! almost every memory card, camera and USB stick.
//!
//! Deleting a file there only marks its directory entry as free and releases
//! its clusters. Until something new is written over them, the entry still
//! holds the name, size, date and first cluster, and the clusters still hold
//! the data. Live files are reported too, as ranges the content scan can skip.

use std::collections::HashSet;
use std::ops::Range;

use super::found::{Condition, Details, Extent, FoundFile, Kind, Origin, Timestamp};
use super::reader::{ByteSource, Reader};

/// A partition, or the whole disk when it has no partition table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Partition {
    pub offset: u64,
    pub length: u64,
}

/// Partitions from an MBR or GPT; the whole disk when there is neither, as on
/// cards formatted without one.
pub fn partitions(r: &mut Reader, sector: u64) -> Vec<Partition> {
    let whole = vec![Partition {
        offset: 0,
        length: r.size(),
    }];
    if r.u16le(510) != Some(0xAA55) || is_boot_sector(r, 0) {
        return whole;
    }
    let mut found = Vec::new();
    for index in 0..4 {
        let entry = 446 + index * 16;
        let (Some(kind), Some(first), Some(count)) =
            (r.byte(entry + 4), r.u32le(entry + 8), r.u32le(entry + 12))
        else {
            continue;
        };
        if kind == 0 || count == 0 || matches!(kind, 0x05 | 0x0F) {
            continue;
        }
        if kind == 0xEE {
            return gpt(r, sector).unwrap_or(whole);
        }
        let offset = u64::from(first) * sector;
        if offset < r.size() {
            found.push(Partition {
                offset,
                length: (u64::from(count) * sector).min(r.size() - offset),
            });
        }
    }
    if found.is_empty() { whole } else { found }
}

fn gpt(r: &mut Reader, sector: u64) -> Option<Vec<Partition>> {
    if !r.ascii("EFI PART", sector) {
        return None;
    }
    let table = r.u64le(sector + 72)?;
    let count = r.u32le(sector + 80).filter(|c| *c <= 1024)?;
    let entry_size = r.u32le(sector + 84).filter(|s| *s >= 128)?;
    let mut found = Vec::new();
    for index in 0..u64::from(count) {
        let entry = table * sector + index * u64::from(entry_size);
        // An all-zero type marks an unused entry.
        if r.bytes(entry, 16)
            .is_none_or(|kind| kind.iter().all(|b| *b == 0))
        {
            continue;
        }
        let (Some(first), Some(last)) = (r.u64le(entry + 32), r.u64le(entry + 40)) else {
            continue;
        };
        let offset = first * sector;
        if last >= first && offset < r.size() {
            found.push(Partition {
                offset,
                length: ((last - first + 1) * sector).min(r.size() - offset),
            });
        }
    }
    Some(found)
}

/// A FAT or exFAT boot sector, rather than a partition table.
pub fn is_boot_sector(r: &mut Reader, offset: u64) -> bool {
    r.ascii("EXFAT   ", offset + 3) || FatVolume::read(r, offset).is_some()
}

/// What the directory pass learned about one volume.
#[derive(Debug, Default)]
pub struct DirectoryScan {
    /// Deleted files, by their old names. `id` is assigned later.
    pub files: Vec<FoundFile>,
    /// Byte ranges on the disk that live files occupy.
    pub allocated: Vec<Range<u64>>,
    pub format: &'static str,
}

/// Folders systems fill with their own bookkeeping.
const SKIPPED_FOLDERS: [&str; 4] = [
    ".Spotlight-V100",
    ".fseventsd",
    ".TemporaryItems",
    "System Volume Information",
];

/// Copies macOS leaves next to each file, and other metadata nobody misses.
fn is_noise(name: &str) -> bool {
    name.starts_with("._") || matches!(name, ".DS_Store" | "Thumbs.db" | "desktop.ini")
}

/// Reads a FAT or exFAT volume in `partition`, if there is one.
pub fn scan(
    source: &dyn ByteSource,
    partition: Partition,
    cancelled: &dyn Fn() -> bool,
) -> Option<DirectoryScan> {
    let mut reader = Reader::new(source);
    if let Some(volume) = ExFatVolume::read(&mut reader, partition.offset) {
        return Some(volume.scan(&mut reader, cancelled));
    }
    let volume = FatVolume::read(&mut reader, partition.offset)?;
    Some(volume.scan(source, &mut reader, cancelled))
}

/// FAT dates are local time, packed into 16 bits each.
pub fn fat_date(date: u16, time: u16) -> Option<Timestamp> {
    Timestamp::new(
        1980 + (date >> 9),
        (date >> 5 & 0x0F) as u8,
        (date & 0x1F) as u8,
        (time >> 11) as u8,
        (time >> 5 & 0x3F) as u8,
        ((time & 0x1F) * 2) as u8,
    )
}

/// Whether `range` overlaps any of the sorted, merged `ranges`.
pub fn overlaps(range: Range<u64>, ranges: &[Range<u64>]) -> bool {
    let index = ranges.partition_point(|r| r.end <= range.start);
    ranges.get(index).is_some_and(|r| r.start < range.end)
}

/// Appends a cluster's byte range, merging it with the previous one.
fn mark(ranges: &mut Vec<Range<u64>>, start: u64, length: u64) {
    match ranges.last_mut() {
        Some(last) if last.end == start => last.end = start + length,
        _ => ranges.push(start..start + length),
    }
}

// MARK: FAT12, FAT16, FAT32

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FatKind {
    Fat12,
    Fat16,
    Fat32,
}

#[derive(Debug, Clone, Copy)]
pub struct FatVolume {
    kind: FatKind,
    cluster_size: u64,
    /// Disk offsets of the first FAT, the FAT12/16 root folder and cluster 2.
    fat_offset: u64,
    root_offset: u64,
    root_entries: u64,
    root_cluster: u32,
    data_offset: u64,
    cluster_count: u32,
    end: u64,
}

type LongName = Vec<(u8, Vec<u16>)>;

impl FatVolume {
    pub fn read(r: &mut Reader, start: u64) -> Option<Self> {
        if !matches!(r.byte(start)?, 0xEB | 0xE9) || r.u16le(start + 510)? != 0xAA55 {
            return None;
        }
        let sector = u64::from(
            r.u16le(start + 11)
                .filter(|s| [512, 1024, 2048, 4096].contains(s))?,
        );
        let per_cluster = r.byte(start + 13).filter(|p| p.is_power_of_two())?;
        let reserved = u64::from(r.u16le(start + 14).filter(|r| *r > 0)?);
        let fats = u64::from(r.byte(start + 16).filter(|f| (1..=2).contains(f))?);
        let root_entries = u64::from(r.u16le(start + 17)?);
        let small = r.u16le(start + 19)?;
        let fat_small = r.u16le(start + 22)?;
        let large = r.u32le(start + 32)?;
        let fat_large = r.u32le(start + 36)?;
        let root_cluster = r.u32le(start + 44)?;
        let total = if small != 0 {
            u64::from(small)
        } else {
            u64::from(large)
        };
        let fat_sectors = if fat_small != 0 {
            u64::from(fat_small)
        } else {
            u64::from(fat_large)
        };
        let root_sectors = (root_entries * 32).div_ceil(sector);
        let first_data = reserved + fats * fat_sectors + root_sectors;
        if total <= first_data || fat_sectors == 0 {
            return None;
        }
        let clusters = (total - first_data) / u64::from(per_cluster);
        let kind = match clusters {
            0..4085 => FatKind::Fat12,
            4085..65525 => FatKind::Fat16,
            _ => FatKind::Fat32,
        };
        if kind == FatKind::Fat32 && (fat_small != 0 || root_entries != 0) {
            return None;
        }
        let fat_offset = start + reserved * sector;
        let volume = Self {
            kind,
            cluster_size: sector * u64::from(per_cluster),
            fat_offset,
            root_offset: fat_offset + fats * fat_sectors * sector,
            root_entries,
            root_cluster,
            data_offset: start + first_data * sector,
            cluster_count: clusters.min(u64::from(u32::MAX - 16)) as u32,
            end: start + total * sector,
        };
        (volume.end <= r.size() + sector).then_some(volume)
    }

    fn format_name(&self) -> &'static str {
        match self.kind {
            FatKind::Fat12 => "FAT12",
            FatKind::Fat16 => "FAT16",
            FatKind::Fat32 => "FAT32",
        }
    }

    fn is_cluster(&self, cluster: u32) -> bool {
        cluster >= 2 && cluster < self.cluster_count.saturating_add(2)
    }

    fn offset_of(&self, cluster: u32) -> u64 {
        self.data_offset + u64::from(cluster - 2) * self.cluster_size
    }

    /// The FAT entry for `cluster`: 0 free, a cluster number, or end of chain.
    fn entry(&self, cluster: u32, r: &mut Reader) -> Option<u32> {
        let cluster64 = u64::from(cluster);
        match self.kind {
            FatKind::Fat32 => r
                .u32le(self.fat_offset + cluster64 * 4)
                .map(|v| v & 0x0FFF_FFFF),
            FatKind::Fat16 => r.u16le(self.fat_offset + cluster64 * 2).map(u32::from),
            FatKind::Fat12 => r
                .u16le(self.fat_offset + cluster64 + cluster64 / 2)
                .map(|v| u32::from(if cluster & 1 == 1 { v >> 4 } else { v & 0xFFF })),
        }
    }

    /// Every cluster in use, as merged byte ranges on the disk.
    fn allocated(&self, source: &dyn ByteSource, r: &mut Reader) -> Vec<Range<u64>> {
        let mut ranges = Vec::new();
        let last = self.cluster_count.saturating_add(2);
        let width: u64 = match self.kind {
            FatKind::Fat32 => 4,
            FatKind::Fat16 => 2,
            FatKind::Fat12 => {
                for cluster in 2..last {
                    if self.entry(cluster, r).unwrap_or(0) != 0 {
                        mark(&mut ranges, self.offset_of(cluster), self.cluster_size);
                    }
                }
                return ranges;
            }
        };
        // Read the table in large pieces: a 64 GB card has millions of entries.
        let mut cluster: u32 = 0;
        while cluster < last {
            let Some(bytes) =
                source.bytes_at(self.fat_offset + u64::from(cluster) * width, 1 << 20)
            else {
                break;
            };
            let entries = bytes.len() / width as usize;
            if entries == 0 {
                break;
            }
            for (index, chunk) in bytes.chunks_exact(width as usize).enumerate() {
                let current = cluster + index as u32;
                if current >= last {
                    break;
                }
                let value = if width == 4 {
                    u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) & 0x0FFF_FFFF
                } else {
                    u32::from(u16::from_le_bytes([chunk[0], chunk[1]]))
                };
                if value != 0 && current >= 2 {
                    mark(&mut ranges, self.offset_of(current), self.cluster_size);
                }
            }
            cluster += entries as u32;
        }
        ranges
    }

    fn scan(
        &self,
        source: &dyn ByteSource,
        r: &mut Reader,
        cancelled: &dyn Fn() -> bool,
    ) -> DirectoryScan {
        let allocated = self.allocated(source, r);
        let mut result = DirectoryScan {
            format: self.format_name(),
            ..Default::default()
        };
        let mut visited = HashSet::new();
        let mut queue: Vec<(u32, String, bool, u32)> = Vec::new();
        let mut entries_read = 0usize;
        if self.kind == FatKind::Fat32 {
            queue.push((self.root_cluster, "/".into(), false, 0));
        } else if let Some(root) = r.bytes(self.root_offset, (self.root_entries * 32) as usize) {
            self.visit(
                &root,
                "/",
                false,
                0,
                &allocated,
                &mut result.files,
                &mut queue,
                &mut entries_read,
            );
        }
        while let Some((cluster, path, deleted, depth)) = queue.pop() {
            if cancelled() {
                break;
            }
            if !visited.insert(cluster) {
                continue;
            }
            let bytes = if deleted {
                self.deleted_folder(cluster, r)
            } else {
                self.chain(cluster, r)
            };
            self.visit(
                &bytes,
                &path,
                deleted,
                depth,
                &allocated,
                &mut result.files,
                &mut queue,
                &mut entries_read,
            );
        }
        result.allocated = allocated;
        result
    }

    #[allow(
        clippy::too_many_arguments,
        reason = "one folder's walk needs the whole scan's state"
    )]
    fn visit(
        &self,
        entries: &[u8],
        path: &str,
        parent_deleted: bool,
        depth: u32,
        allocated: &[Range<u64>],
        files: &mut Vec<FoundFile>,
        queue: &mut Vec<(u32, String, bool, u32)>,
        entries_read: &mut usize,
    ) {
        // Short entries with the long name entries stored before each.
        let mut records: Vec<(&[u8], LongName)> = Vec::new();
        let mut long_name: LongName = Vec::new();
        for entry in entries.as_chunks::<32>().0 {
            if *entries_read >= 500_000 || entry[0] == 0x00 {
                break;
            }
            *entries_read += 1;
            if entry[11] == 0x0F {
                long_name.push((entry[13], long_name_characters(entry)));
            } else {
                records.push((entry.as_slice(), std::mem::take(&mut long_name)));
            }
        }
        let live_names: Vec<String> = records
            .iter()
            .filter(|(e, _)| e[0] != 0xE5)
            .map(|(e, _)| short_name(e))
            .collect();

        for (entry, long_name) in records {
            let attributes = entry[11];
            if attributes & 0x08 != 0 {
                continue;
            }
            let erased = entry[0] == 0xE5;
            let deleted = parent_deleted || erased;
            let short = short_name(entry);
            if short == "." || short == ".." {
                continue;
            }
            // A deleted short name lost its first letter to the 0xE5 mark.
            let name = assemble_name(entry, &long_name, erased).unwrap_or_else(|| {
                if erased {
                    let mut raw = entry.to_vec();
                    raw[0] = b'_';
                    restore_first_letter(&short_name(&raw), &live_names)
                } else {
                    short.clone()
                }
            });
            let low = u32::from(u16::from_le_bytes([entry[26], entry[27]]));
            let high = if self.kind == FatKind::Fat32 {
                u32::from(u16::from_le_bytes([entry[20], entry[21]])) << 16
            } else {
                0
            };
            let cluster = high | low;
            let size = u64::from(u32::from_le_bytes([
                entry[28], entry[29], entry[30], entry[31],
            ]));
            let modified = fat_date(
                u16::from_le_bytes([entry[24], entry[25]]),
                u16::from_le_bytes([entry[22], entry[23]]),
            );

            if attributes & 0x10 != 0 {
                if self.is_cluster(cluster)
                    && depth < 32
                    && !SKIPPED_FOLDERS.contains(&name.as_str())
                {
                    queue.push((cluster, format!("{path}{name}/"), deleted, depth + 1));
                }
                continue;
            }
            if !deleted || size == 0 || !self.is_cluster(cluster) || is_noise(&name) {
                continue;
            }
            // FAT forgets a deleted file's cluster chain; cameras write files
            // in one piece, so the data most likely follows on.
            let start = self.offset_of(cluster);
            let length = size.min(self.end.saturating_sub(start));
            if length == 0 {
                continue;
            }
            let condition = if overlaps(start..start + length, allocated) {
                Condition::Overwritten
            } else if length < size {
                Condition::Damaged
            } else {
                Condition::Good
            };
            files.push(FoundFile {
                id: 0,
                format: None,
                kind: Kind::guess(&name),
                extents: vec![Extent {
                    offset: start,
                    length,
                }],
                name: Some(name),
                folder: Some(path.to_string()),
                date: modified,
                condition,
                details: Details::default(),
                origin: Origin::Directory,
            });
        }
    }

    /// A live folder's clusters, following the FAT.
    fn chain(&self, start: u32, r: &mut Reader) -> Vec<u8> {
        let mut bytes = Vec::new();
        let mut cluster = start;
        let mut seen = HashSet::new();
        while self.is_cluster(cluster) && seen.insert(cluster) && bytes.len() < 8 << 20 {
            let Some(data) = r.bytes(self.offset_of(cluster), self.cluster_size as usize) else {
                break;
            };
            bytes.extend_from_slice(&data);
            let Some(next) = self.entry(cluster, r) else {
                break;
            };
            cluster = next;
        }
        bytes
    }

    /// A deleted folder's chain is gone: read on while the clusters still
    /// look like folder entries.
    fn deleted_folder(&self, start: u32, r: &mut Reader) -> Vec<u8> {
        let mut bytes: Vec<u8> = Vec::new();
        let mut cluster = start;
        while self.is_cluster(cluster) && bytes.len() < 1 << 20 {
            let Some(data) = r.bytes(self.offset_of(cluster), self.cluster_size as usize) else {
                break;
            };
            let plausible = data.len() >= 32
                && (data[0] == 0xE5 || data[0] >= 0x20)
                && (data[11] == 0x0F || data[11] & 0xC0 == 0);
            if !bytes.is_empty() && !plausible {
                break;
            }
            bytes.extend_from_slice(&data);
            cluster += 1;
        }
        bytes
    }
}

/// The 8.3 name. Windows and macOS keep all-lowercase names short and note
/// the case in two flag bits instead of writing a long name.
fn short_name(entry: &[u8]) -> String {
    let mut base = entry[0..8].to_vec();
    if base[0] == 0x05 {
        base[0] = 0xE5;
    }
    let mut name = String::from_utf8_lossy(&base).trim_end().to_string();
    let mut ext = String::from_utf8_lossy(&entry[8..11])
        .trim_end()
        .to_string();
    if entry.len() > 12 {
        if entry[12] & 0x08 != 0 {
            name = name.to_lowercase();
        }
        if entry[12] & 0x10 != 0 {
            ext = ext.to_lowercase();
        }
    }
    if ext.is_empty() {
        name
    } else {
        format!("{name}.{ext}")
    }
}

/// Camera file names, for putting back a lost first letter.
const CAMERA_PREFIXES: [&str; 10] = [
    "IMG_", "DSC_", "DSCF", "DSCN", "MVI_", "VID_", "GOPR", "PXL_", "DJI_", "MOV_",
];

/// `_MG_0002.JPG` next to `IMG_0001.JPG` was `IMG_0002.JPG`. Siblings sharing
/// the next three letters decide; failing that, the usual camera prefixes;
/// failing both, the underscore stays.
pub fn restore_first_letter(name: &str, siblings: &[String]) -> String {
    let rest: String = name.chars().skip(1).collect();
    if rest.chars().count() < 3 {
        return name.to_string();
    }
    let probe: String = rest.chars().take(3).collect::<String>().to_lowercase();
    let letters: HashSet<char> = siblings
        .iter()
        .filter(|s| s.chars().count() == name.chars().count())
        .filter_map(|sibling| {
            let first = sibling.chars().next()?;
            let next: String = sibling
                .chars()
                .skip(1)
                .take(3)
                .collect::<String>()
                .to_lowercase();
            (first != '_' && next == probe).then_some(first)
        })
        .collect();
    if letters.len() == 1
        && let Some(letter) = letters.into_iter().next()
    {
        return format!("{letter}{rest}");
    }
    let upper = rest.to_uppercase();
    if let Some(prefix) = CAMERA_PREFIXES.iter().find(|p| upper.starts_with(&p[1..])) {
        let letter = &prefix[..1];
        let lowercase = rest.chars().next().is_some_and(char::is_lowercase);
        return format!(
            "{}{rest}",
            if lowercase {
                letter.to_lowercase()
            } else {
                letter.to_string()
            }
        );
    }
    name.to_string()
}

fn long_name_characters(entry: &[u8]) -> Vec<u16> {
    [1..11, 14..26, 28..32]
        .into_iter()
        .flat_map(|range| {
            entry[range]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|pair| u16::from_le_bytes(*pair))
                .collect::<Vec<_>>()
        })
        .collect()
}

/// The long name stored before a short entry, or `None` without one. A
/// deleted entry lost its first letter; the checksum in the long name tells
/// which letter it was. The checksum is only 8 bits, so the long name's own
/// first letter, the usual source of the short one, is tried first.
fn assemble_name(entry: &[u8], long_name: &LongName, erased: bool) -> Option<String> {
    let mut raw: Vec<u8> = entry[..11].to_vec();
    if erased {
        let checksum = long_name.first()?.0;
        let hint = long_name
            .last()
            .and_then(|(_, text)| text.first())
            .and_then(|unit| char::from_u32(u32::from(*unit)))
            .map(|c| c.to_ascii_uppercase())
            .filter(char::is_ascii)
            .map(|c| c as u8);
        let candidates = hint
            .into_iter()
            .chain(*b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$%'-@~!(){}^#&");
        let letter = candidates.into_iter().find(|candidate| {
            raw[0] = *candidate;
            short_checksum(&raw) == checksum
        })?;
        raw[0] = letter;
    }
    if long_name.is_empty()
        || !long_name
            .iter()
            .all(|(checksum, _)| *checksum == short_checksum(&raw))
    {
        if !erased {
            return None;
        }
        let mut full = raw.clone();
        full.extend_from_slice(&entry[11..]);
        return Some(short_name(&full));
    }
    // Long name entries are stored last part first.
    let units: Vec<u16> = long_name
        .iter()
        .rev()
        .flat_map(|(_, text)| text.iter().copied())
        .take_while(|unit| *unit != 0 && *unit != 0xFFFF)
        .collect();
    Some(String::from_utf16_lossy(&units))
}

fn short_checksum(name: &[u8]) -> u8 {
    name.iter().take(11).fold(0u8, |sum, byte| {
        ((sum & 1) << 7 | sum >> 1).wrapping_add(*byte)
    })
}

// MARK: exFAT

#[derive(Debug, Clone, Copy)]
pub struct ExFatVolume {
    cluster_size: u64,
    fat_offset: u64,
    heap_offset: u64,
    cluster_count: u32,
    root_cluster: u32,
}

impl ExFatVolume {
    pub fn read(r: &mut Reader, start: u64) -> Option<Self> {
        if !r.ascii("EXFAT   ", start + 3) {
            return None;
        }
        let fat = u64::from(r.u32le(start + 80)?);
        let heap = u64::from(r.u32le(start + 88)?);
        let clusters = r.u32le(start + 92).filter(|c| *c > 0)?;
        let root = r.u32le(start + 96)?;
        let sector_shift = r.byte(start + 108).filter(|s| (9..=12).contains(s))?;
        let cluster_shift = r.byte(start + 109).filter(|c| *c <= 25 - sector_shift)?;
        let sector = 1u64 << sector_shift;
        let volume = Self {
            cluster_size: sector << cluster_shift,
            fat_offset: start + fat * sector,
            heap_offset: start + heap * sector,
            cluster_count: clusters,
            root_cluster: root,
        };
        volume.is_cluster(root).then_some(volume)
    }

    fn is_cluster(&self, cluster: u32) -> bool {
        cluster >= 2 && cluster < self.cluster_count.saturating_add(2)
    }

    fn offset_of(&self, cluster: u32) -> u64 {
        self.heap_offset + u64::from(cluster - 2) * self.cluster_size
    }

    /// Clusters of a chain: contiguous when the entry says so, else through the FAT.
    fn clusters(&self, first: u32, length: u64, contiguous: bool, r: &mut Reader) -> Vec<u32> {
        let needed = length.div_ceil(self.cluster_size) as usize;
        if !self.is_cluster(first) || needed == 0 {
            return Vec::new();
        }
        if contiguous {
            return (0..needed as u32)
                .map(|i| first + i)
                .filter(|c| self.is_cluster(*c))
                .collect();
        }
        let mut chain = Vec::new();
        let mut cluster = first;
        let mut seen = HashSet::new();
        while chain.len() < needed && self.is_cluster(cluster) && seen.insert(cluster) {
            chain.push(cluster);
            let Some(next) = r.u32le(self.fat_offset + u64::from(cluster) * 4) else {
                break;
            };
            cluster = next;
        }
        chain
    }

    /// Clusters as merged extents on the disk.
    fn extents(&self, clusters: &[u32], length: u64) -> Vec<Extent> {
        let mut extents: Vec<Extent> = Vec::new();
        let mut remaining = length;
        for cluster in clusters {
            if remaining == 0 {
                break;
            }
            let take = self.cluster_size.min(remaining);
            let start = self.offset_of(*cluster);
            match extents.last_mut() {
                Some(last) if last.end() == start => last.length += take,
                _ => extents.push(Extent {
                    offset: start,
                    length: take,
                }),
            }
            remaining -= take;
        }
        extents
    }

    fn scan(&self, r: &mut Reader, cancelled: &dyn Fn() -> bool) -> DirectoryScan {
        let mut bitmap: Vec<u8> = Vec::new();
        let root = self.clusters(self.root_cluster, 64 << 20, false, r);
        let mut queue: Vec<(Vec<u32>, String, bool, u32)> = vec![(root, "/".into(), false, 0)];
        let mut visited = HashSet::new();
        let mut files: Vec<FoundFile> = Vec::new();
        let mut entries_read = 0usize;

        while let Some((clusters, path, folder_deleted, depth)) = queue.pop() {
            if cancelled() {
                break;
            }
            let Some(first) = clusters.first() else {
                continue;
            };
            if !visited.insert(*first) {
                continue;
            }
            let mut bytes = Vec::new();
            for cluster in &clusters {
                if bytes.len() >= 64 << 20 {
                    break;
                }
                let Some(data) = r.bytes(self.offset_of(*cluster), self.cluster_size as usize)
                else {
                    break;
                };
                bytes.extend_from_slice(&data);
            }
            let le16 = |b: &[u8], at: usize| u16::from_le_bytes([b[at], b[at + 1]]);
            let le32 =
                |b: &[u8], at: usize| u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]]);
            let le64 = |b: &[u8], at: usize| {
                u64::from_le_bytes(b[at..at + 8].try_into().unwrap_or_default())
            };
            let mut index = 0;
            while index + 32 <= bytes.len() && entries_read < 500_000 {
                let kind = bytes[index];
                entries_read += 1;
                if kind == 0x00 {
                    break;
                }
                if kind == 0x81 && depth == 0 && bitmap.is_empty() {
                    let start = le32(&bytes, index + 20);
                    let length = le64(&bytes, index + 24);
                    for cluster in self.clusters(start, length, true, r) {
                        bitmap.extend(
                            r.bytes(self.offset_of(cluster), self.cluster_size as usize)
                                .unwrap_or_default(),
                        );
                    }
                    bitmap.truncate(length as usize);
                }
                // A file is a primary entry, then its stream and name entries.
                if kind != 0x85 && kind != 0x05 {
                    index += 32;
                    continue;
                }
                let secondary = usize::from(bytes[index + 1]);
                if secondary < 2
                    || index + 32 * (secondary + 1) > bytes.len()
                    || bytes[index + 32] & 0x7F != 0x40
                {
                    index += 32;
                    continue;
                }
                let deleted = folder_deleted || kind == 0x05;
                let attributes = le16(&bytes, index + 4);
                let modified = le32(&bytes, index + 12);
                let stream = index + 32;
                let contiguous = bytes[stream + 1] & 0x02 != 0;
                let name_length = usize::from(bytes[stream + 3]);
                let first_cluster = le32(&bytes, stream + 20);
                let data_length = le64(&bytes, stream + 24);
                let mut units = Vec::new();
                for part in 0..secondary - 1 {
                    let entry = stream + 32 * (part + 1);
                    if bytes[entry] & 0x7F != 0x41 {
                        break;
                    }
                    units.extend((0..15).map(|c| le16(&bytes, entry + 2 + c * 2)));
                }
                units.truncate(name_length);
                let name = String::from_utf16_lossy(&units);
                index += 32 * (secondary + 1);
                if name.is_empty() {
                    continue;
                }
                if attributes & 0x10 != 0 {
                    if depth < 32
                        && !SKIPPED_FOLDERS.contains(&name.as_str())
                        && self.is_cluster(first_cluster)
                    {
                        let chain = self.clusters(
                            first_cluster,
                            data_length.max(self.cluster_size),
                            contiguous,
                            r,
                        );
                        queue.push((chain, format!("{path}{name}/"), deleted, depth + 1));
                    }
                    continue;
                }
                if !deleted
                    || data_length == 0
                    || !self.is_cluster(first_cluster)
                    || is_noise(&name)
                {
                    continue;
                }
                // A deleted file's FAT chain may already be reused; trust it
                // only when it is long enough, else assume one piece.
                let mut chain = self.clusters(first_cluster, data_length, contiguous, r);
                if chain.len() < data_length.div_ceil(self.cluster_size) as usize {
                    chain = self.clusters(first_cluster, data_length, true, r);
                }
                let extents = self.extents(&chain, data_length);
                let recovered: u64 = extents.iter().map(|e| e.length).sum();
                if recovered == 0 {
                    continue;
                }
                files.push(FoundFile {
                    id: 0,
                    format: None,
                    kind: Kind::guess(&name),
                    extents,
                    name: Some(name),
                    folder: Some(path.clone()),
                    date: fat_date((modified >> 16) as u16, (modified & 0xFFFF) as u16),
                    condition: if recovered < data_length {
                        Condition::Damaged
                    } else {
                        Condition::Good
                    },
                    details: Details::default(),
                    origin: Origin::Directory,
                });
            }
        }

        // The allocation bitmap: one bit per cluster, set while in use.
        let mut allocated = Vec::new();
        for (byte_index, byte) in bitmap.iter().enumerate() {
            for bit in 0..8 {
                if byte >> bit & 1 == 1 {
                    let cluster = (byte_index * 8 + bit) as u32 + 2;
                    if self.is_cluster(cluster) {
                        mark(&mut allocated, self.offset_of(cluster), self.cluster_size);
                    }
                }
            }
        }
        for file in &mut files {
            if file.condition == Condition::Good
                && file
                    .extents
                    .iter()
                    .any(|e| overlaps(e.offset..e.end(), &allocated))
            {
                file.condition = Condition::Overwritten;
            }
        }
        DirectoryScan {
            files,
            allocated,
            format: "exFAT",
        }
    }
}
