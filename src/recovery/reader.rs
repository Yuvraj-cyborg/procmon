//! Read-only access to the bytes recovery works on: a raw disk, a disk image
//! file, or (for tests) bytes in memory.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::File;
use std::io;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadError {
    /// The device is gone, e.g. a card pulled out mid-scan.
    Disconnected,
    /// These bytes could not be read; the rest of the device may still be.
    Unreadable,
}

impl ReadError {
    fn from_io(err: &io::Error) -> Self {
        #[cfg(unix)]
        let gone = [libc::ENXIO, libc::ENODEV, libc::EBADF];
        // ERROR_INVALID_HANDLE, ERROR_NOT_READY, ERROR_NO_SUCH_DEVICE, ERROR_DEVICE_NOT_CONNECTED.
        #[cfg(windows)]
        let gone = [6, 21, 433, 1167];
        #[cfg(not(any(unix, windows)))]
        let gone: [i32; 0] = [];
        match err.raw_os_error() {
            Some(code) if gone.contains(&code) => ReadError::Disconnected,
            _ => ReadError::Unreadable,
        }
    }
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            ReadError::Disconnected => "The disk was disconnected.",
            ReadError::Unreadable => "Part of the disk couldn't be read.",
        })
    }
}

/// Something recovery can read from.
pub trait ByteSource: Send + Sync {
    fn size(&self) -> u64;
    /// Reads at offsets and lengths that are multiples of this are fastest;
    /// raw disks accept nothing else, and [`ByteSource::read_at`] handles the rest.
    fn block_size(&self) -> usize;
    /// Reads up to `buffer.len()` bytes at `offset`; returns how many, 0 at the end.
    fn read_at(&self, buffer: &mut [u8], offset: u64) -> Result<usize, ReadError>;

    /// Up to `count` bytes at `offset`, or `None` if any of them is unreadable.
    fn bytes_at(&self, offset: u64, count: usize) -> Option<Vec<u8>> {
        if offset >= self.size() {
            return Some(Vec::new());
        }
        let count = count.min((self.size() - offset) as usize);
        let mut bytes = vec![0; count];
        let read = self.read_at(&mut bytes, offset).ok()?;
        (read == count).then_some(bytes)
    }
}

/// A disk or disk image, read through one file handle with positioned
/// reads, which are safe from several threads at once.
pub struct RawDevice {
    file: File,
    size: u64,
    block_size: usize,
}

impl RawDevice {
    /// Opens a file (a disk image) that needs no special permission.
    pub fn open(path: &Path) -> io::Result<Self> {
        Self::from_file(File::open(path)?, path)
    }

    pub fn from_file(file: File, path: &Path) -> io::Result<Self> {
        let (size, block_size) = geometry(&file, path)?;
        Ok(Self {
            file,
            size,
            block_size: block_size.max(512),
        })
    }

    fn read_aligned(&self, buffer: &mut [u8], offset: u64) -> Result<usize, ReadError> {
        let mut done = 0;
        while done < buffer.len() {
            match positioned_read(&self.file, &mut buffer[done..], offset + done as u64) {
                Ok(0) => break,
                Ok(read) => done += read,
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(ReadError::from_io(&err)),
            }
        }
        Ok(done)
    }
}

impl ByteSource for RawDevice {
    fn size(&self) -> u64 {
        self.size
    }

    fn block_size(&self) -> usize {
        self.block_size
    }

    fn read_at(&self, buffer: &mut [u8], offset: u64) -> Result<usize, ReadError> {
        if offset >= self.size || buffer.is_empty() {
            return Ok(0);
        }
        let wanted = buffer.len().min((self.size - offset) as usize);
        let block = self.block_size as u64;
        if offset.is_multiple_of(block) && wanted.is_multiple_of(self.block_size) {
            return self.read_aligned(&mut buffer[..wanted], offset);
        }
        // Read the whole blocks around the request, then copy out the middle.
        let start = offset / block * block;
        let end = self
            .size
            .min((offset + wanted as u64).div_ceil(block) * block);
        let mut scratch = vec![0; (end - start) as usize];
        let got = self.read_aligned(&mut scratch, start)?;
        let skip = (offset - start) as usize;
        let copied = wanted.min(got.saturating_sub(skip));
        buffer[..copied].copy_from_slice(&scratch[skip..skip + copied]);
        Ok(copied)
    }
}

#[cfg(unix)]
fn positioned_read(file: &File, buffer: &mut [u8], offset: u64) -> io::Result<usize> {
    std::os::unix::fs::FileExt::read_at(file, buffer, offset)
}

#[cfg(windows)]
fn positioned_read(file: &File, buffer: &mut [u8], offset: u64) -> io::Result<usize> {
    std::os::windows::fs::FileExt::seek_read(file, buffer, offset)
}

/// Size and block size: from the device itself for disks, else the file length.
#[cfg(unix)]
fn geometry(file: &File, _path: &Path) -> io::Result<(u64, usize)> {
    use std::os::unix::fs::FileTypeExt as _;
    use std::os::unix::io::AsRawFd as _;
    let file_type = file.metadata()?.file_type();
    if !(file_type.is_block_device() || file_type.is_char_device()) {
        return Ok((file.metadata()?.len(), 512));
    }
    let fd = file.as_raw_fd();
    #[cfg(target_os = "linux")]
    {
        // BLKGETSIZE64 and BLKSSZGET from <linux/fs.h>.
        let mut size: u64 = 0;
        let mut sector: libc::c_int = 0;
        // SAFETY: both ioctls write one integer of the given type.
        unsafe {
            if libc::ioctl(fd, 0x8008_1272, &mut size) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::ioctl(fd, 0x1268, &mut sector) != 0 {
                sector = 512;
            }
        }
        Ok((size, sector.max(512) as usize))
    }
    #[cfg(target_os = "macos")]
    {
        // DKIOCGETBLOCKSIZE and DKIOCGETBLOCKCOUNT from <sys/disk.h>.
        let mut sector: u32 = 0;
        let mut count: u64 = 0;
        // SAFETY: both ioctls write one integer of the given type.
        unsafe {
            if libc::ioctl(fd, 0x4004_6418, &mut sector) != 0
                || libc::ioctl(fd, 0x4008_6419, &mut count) != 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        Ok((count * u64::from(sector), sector.max(512) as usize))
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = fd;
        Ok((file.metadata()?.len(), 512))
    }
}

#[cfg(windows)]
fn geometry(file: &File, path: &Path) -> io::Result<(u64, usize)> {
    if path.to_string_lossy().starts_with(r"\\.\") {
        crate::recovery::disks::device_geometry(file)
    } else {
        Ok((file.metadata()?.len(), 512))
    }
}

/// Bytes in memory, for tests.
#[cfg(test)]
pub struct MemorySource(pub Vec<u8>);

#[cfg(test)]
impl ByteSource for MemorySource {
    fn size(&self) -> u64 {
        self.0.len() as u64
    }

    fn block_size(&self) -> usize {
        512
    }

    fn read_at(&self, buffer: &mut [u8], offset: u64) -> Result<usize, ReadError> {
        let Some(rest) = self.0.get(offset as usize..) else {
            return Ok(0);
        };
        let count = buffer.len().min(rest.len());
        buffer[..count].copy_from_slice(&rest[..count]);
        Ok(count)
    }
}

/// Random access for the format parsers: small reads close together,
/// served from a few cached pages.
pub struct Reader<'a> {
    source: &'a dyn ByteSource,
    pages: HashMap<u64, Vec<u8>>,
    order: VecDeque<u64>,
    /// Pages that failed to read, so they are not retried byte by byte.
    bad: HashSet<u64>,
}

impl<'a> Reader<'a> {
    const PAGE: u64 = 256 * 1024;
    const PAGE_LIMIT: usize = 24;

    pub fn new(source: &'a dyn ByteSource) -> Self {
        Self {
            source,
            pages: HashMap::new(),
            order: VecDeque::new(),
            bad: HashSet::new(),
        }
    }

    pub fn size(&self) -> u64 {
        self.source.size()
    }

    /// The cached page with this index, or `None` past the end or when unreadable.
    fn page(&mut self, index: u64) -> Option<&[u8]> {
        if !self.pages.contains_key(&index) {
            if self.bad.contains(&index) || index * Self::PAGE >= self.size() {
                return None;
            }
            let Some(page) = self
                .source
                .bytes_at(index * Self::PAGE, Self::PAGE as usize)
            else {
                self.bad.insert(index);
                return None;
            };
            if self.order.len() >= Self::PAGE_LIMIT
                && let Some(old) = self.order.pop_front()
            {
                self.pages.remove(&old);
            }
            self.pages.insert(index, page);
            self.order.push_back(index);
        }
        self.pages.get(&index).map(Vec::as_slice)
    }

    pub fn byte(&mut self, offset: u64) -> Option<u8> {
        let page = self.page(offset / Self::PAGE)?;
        page.get((offset % Self::PAGE) as usize).copied()
    }

    /// Exactly `count` bytes, or `None` if any is past the end or unreadable.
    pub fn bytes(&mut self, offset: u64, count: usize) -> Option<Vec<u8>> {
        if offset.checked_add(count as u64)? > self.size() {
            return None;
        }
        let mut result = Vec::with_capacity(count);
        let mut position = offset;
        while result.len() < count {
            let page = self.page(position / Self::PAGE)?;
            let start = (position % Self::PAGE) as usize;
            let take = (count - result.len()).min(page.len().checked_sub(start)?);
            if take == 0 {
                return None;
            }
            result.extend_from_slice(&page[start..start + take]);
            position += take as u64;
        }
        Some(result)
    }

    pub fn matches(&mut self, pattern: &[u8], offset: u64) -> bool {
        self.bytes(offset, pattern.len()).as_deref() == Some(pattern)
    }

    pub fn ascii(&mut self, text: &str, offset: u64) -> bool {
        self.matches(text.as_bytes(), offset)
    }

    fn integer(&mut self, offset: u64, width: usize, big_endian: bool) -> Option<u64> {
        let bytes = self.bytes(offset, width)?;
        let fold = |value: u64, byte: &u8| value << 8 | u64::from(*byte);
        Some(if big_endian {
            bytes.iter().fold(0, fold)
        } else {
            bytes.iter().rev().fold(0, fold)
        })
    }

    pub fn u16le(&mut self, offset: u64) -> Option<u16> {
        self.integer(offset, 2, false).map(|v| v as u16)
    }
    pub fn u16be(&mut self, offset: u64) -> Option<u16> {
        self.integer(offset, 2, true).map(|v| v as u16)
    }
    pub fn u32le(&mut self, offset: u64) -> Option<u32> {
        self.integer(offset, 4, false).map(|v| v as u32)
    }
    pub fn u32be(&mut self, offset: u64) -> Option<u32> {
        self.integer(offset, 4, true).map(|v| v as u32)
    }
    pub fn u64le(&mut self, offset: u64) -> Option<u64> {
        self.integer(offset, 8, false)
    }
    pub fn u64be(&mut self, offset: u64) -> Option<u64> {
        self.integer(offset, 8, true)
    }

    /// Where `pattern` next starts at or after `offset`, looking no further
    /// than `limit`. Stops at the first unreadable page.
    pub fn find(&mut self, pattern: &[u8], offset: u64, limit: u64) -> Option<u64> {
        let first = *pattern.first()?;
        let end = limit.min(self.size());
        let mut position = offset;
        while position < end {
            let page_start = position / Self::PAGE * Self::PAGE;
            let start = (position - page_start) as usize;
            // Searched in place: JPEG parsing calls this once per 0xFF byte.
            let (hit, crossing, stop) = {
                let page = self.page(position / Self::PAGE)?;
                let stop = page.len().min(start + (end - position) as usize);
                let mut cursor = start;
                let mut hit = None;
                let mut crossing = None;
                while let Some(found) = page[cursor..stop].iter().position(|b| *b == first) {
                    let index = cursor + found;
                    match page.get(index..index + pattern.len()) {
                        Some(window) if window == pattern => {
                            hit = Some(index);
                            break;
                        }
                        Some(_) => cursor = index + 1,
                        None => {
                            crossing = Some(index);
                            break;
                        }
                    }
                }
                (hit, crossing, stop)
            };
            if let Some(index) = hit {
                let candidate = page_start + index as u64;
                return (candidate < end).then_some(candidate);
            }
            if let Some(index) = crossing {
                // The pattern would run into the next page.
                let candidate = page_start + index as u64;
                if self.matches(pattern, candidate) {
                    return (candidate < end).then_some(candidate);
                }
                position = candidate + 1;
                continue;
            }
            position = page_start + stop as u64;
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_across_pages_and_finds_patterns() {
        let mut data = vec![0u8; 600 * 1024];
        data[262_140..262_148].copy_from_slice(b"%%EOF%%E");
        let source = MemorySource(data);
        let mut reader = Reader::new(&source);
        assert_eq!(reader.find(b"%%EOF", 0, source.size()), Some(262_140));
        assert_eq!(reader.bytes(262_143, 4).unwrap(), b"OF%%");
        assert_eq!(reader.u16le(262_140), Some(u16::from_le_bytes(*b"%%")));
        assert!(reader.bytes(source.size() - 2, 4).is_none());
        assert_eq!(reader.find(b"%%EOF", 262_141, source.size()), None);
    }

    #[test]
    fn unaligned_reads_of_files_work() {
        let path = std::env::temp_dir().join(format!("procmon-raw-{}", std::process::id()));
        std::fs::write(&path, (0..=255u8).cycle().take(4096).collect::<Vec<_>>()).unwrap();
        let device = RawDevice::open(&path).unwrap();
        let mut buffer = [0u8; 5];
        assert_eq!(device.read_at(&mut buffer, 510).unwrap(), 5);
        assert_eq!(buffer, [254, 255, 0, 1, 2]);
        assert_eq!(device.size(), 4096);
        std::fs::remove_file(path).ok();
    }
}
