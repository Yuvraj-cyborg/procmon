//! Copies found files off the disk being recovered into a new folder.

use std::fs::{self, File};
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};

use super::found::{FoundFile, Timestamp};
use super::reader::{ByteSource, ReadError};
use crate::units::Bytes;

#[derive(Debug, Default)]
pub struct ExportProgress {
    files: AtomicUsize,
    bytes: AtomicU64,
    cancelled: AtomicBool,
}

impl ExportProgress {
    pub fn files(&self) -> usize {
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
pub struct ExportReport {
    pub folder: PathBuf,
    pub saved: usize,
    pub bytes: Bytes,
    /// Bytes the disk could not return; saved as zeros.
    pub unreadable: Bytes,
    pub failures: Vec<String>,
}

/// Saves `files` into a new folder in `destination`, one folder per kind.
/// Files that still have their names keep them, and their old folders.
pub fn export(
    files: &[FoundFile],
    source: &dyn ByteSource,
    source_name: &str,
    destination: &Path,
    progress: &ExportProgress,
) -> io::Result<ExportReport> {
    let now = local_now();
    let stamp = format!(
        "{:04}-{:02}-{:02} {:02}.{:02}",
        now.year, now.month, now.day, now.hour, now.minute
    );
    let folder = unique(&destination.join(safe(&format!("Recovered from {source_name} {stamp}"))));
    fs::create_dir_all(&folder)?;
    let mut report = ExportReport {
        folder: folder.clone(),
        saved: 0,
        bytes: Bytes::ZERO,
        unreadable: Bytes::ZERO,
        failures: Vec::new(),
    };
    let mut buffer = vec![0u8; 1 << 20];
    for file in files {
        if progress.is_cancelled() {
            break;
        }
        let mut directory = folder.join(file.kind.label());
        for part in file.folder.as_deref().unwrap_or_default().split('/').filter(|p| !p.is_empty()) {
            directory.push(safe(part));
        }
        let outcome = fs::create_dir_all(&directory).and_then(|()| {
            let path = unique(&directory.join(safe(&file.display_name())));
            let lost = copy(file, source, &path, &mut buffer, progress)?;
            if let Some(date) = file.date
                && let Ok(handle) = File::options().write(true).open(&path)
            {
                handle.set_modified(system_time(date)).ok();
            }
            Ok(lost)
        });
        match outcome {
            Ok(lost) => {
                report.saved += 1;
                report.bytes += file.size();
                report.unreadable += Bytes(lost);
            }
            Err(err) => report.failures.push(format!("{}: {err}", file.display_name())),
        }
        progress.files.fetch_add(1, Ordering::Relaxed);
    }
    Ok(report)
}

/// Returns the bytes that could not be read and were written as zeros.
fn copy(file: &FoundFile, source: &dyn ByteSource, path: &Path, buffer: &mut [u8], progress: &ExportProgress) -> io::Result<u64> {
    let mut output = io::BufWriter::new(File::create(path)?);
    let mut lost = 0;
    for extent in &file.extents {
        let mut position = extent.offset;
        while position < extent.end() {
            let count = buffer.len().min((extent.end() - position) as usize);
            let slice = &mut buffer[..count];
            let got = match source.read_at(slice, position) {
                Ok(got) => got,
                Err(ReadError::Disconnected) => {
                    return Err(io::Error::new(io::ErrorKind::NotFound, "the disk was disconnected"));
                }
                Err(ReadError::Unreadable) => {
                    slice.fill(0);
                    lost += count as u64;
                    count
                }
            };
            if got == 0 {
                break;
            }
            output.write_all(&slice[..got])?;
            position += got as u64;
            progress.bytes.fetch_add(got as u64, Ordering::Relaxed);
        }
    }
    output.flush()?;
    Ok(lost)
}

/// Names safe on any file system: no path separators or characters Windows
/// refuses, not hidden, and not one of Windows' reserved device names.
pub fn safe(name: &str) -> String {
    let mut cleaned: String = name
        .chars()
        .map(|c| if matches!(c, '/' | '\\' | ':' | '<' | '>' | '"' | '|' | '?' | '*') || c.is_control() { '-' } else { c })
        .collect();
    cleaned = cleaned.trim_start_matches('.').trim_end_matches(['.', ' ']).to_string();
    if cleaned.is_empty() {
        return "Untitled".into();
    }
    let stem = cleaned.split('.').next().unwrap_or_default().to_ascii_uppercase();
    let reserved = matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (stem.len() == 4 && (stem.starts_with("COM") || stem.starts_with("LPT")) && stem.ends_with(|c: char| c.is_ascii_digit()));
    if reserved { format!("_{cleaned}") } else { cleaned }
}

/// `name 2.ext`, `name 3.ext`… when the name is taken.
pub fn unique(path: &Path) -> PathBuf {
    if !path.exists() {
        return path.to_path_buf();
    }
    let parent = path.parent().unwrap_or(Path::new("."));
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = path.extension().map(|e| e.to_string_lossy().into_owned());
    (2..)
        .map(|n| parent.join(match &ext {
            Some(ext) => format!("{stem} {n}.{ext}"),
            None => format!("{stem} {n}"),
        }))
        .find(|candidate| !candidate.exists())
        .unwrap_or_else(|| path.to_path_buf())
}

/// A file system's local date as a point in time: the zone it was written in
/// is unknown, so this Mac's or PC's own zone is the best guess.
fn system_time(date: Timestamp) -> std::time::SystemTime {
    let seconds = local_to_unix(date);
    if seconds >= 0 {
        std::time::UNIX_EPOCH + std::time::Duration::from_secs(seconds as u64)
    } else {
        std::time::UNIX_EPOCH
    }
}

#[cfg(unix)]
fn local_to_unix(date: Timestamp) -> i64 {
    // SAFETY: `tm` is plain data; `mktime` only reads and normalises it.
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        tm.tm_year = i32::from(date.year) - 1900;
        tm.tm_mon = i32::from(date.month) - 1;
        tm.tm_mday = i32::from(date.day);
        tm.tm_hour = i32::from(date.hour);
        tm.tm_min = i32::from(date.minute);
        tm.tm_sec = i32::from(date.second);
        tm.tm_isdst = -1;
        libc::mktime(&mut tm)
    }
}

#[cfg(not(unix))]
fn local_to_unix(date: Timestamp) -> i64 {
    date.as_unix()
}

/// Now, in local time.
#[cfg(unix)]
pub fn local_now() -> Timestamp {
    // SAFETY: `localtime_r` fills the `tm` it is given.
    let tm = unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&now, &mut tm);
        tm
    };
    Timestamp {
        year: (tm.tm_year + 1900) as u16,
        month: (tm.tm_mon + 1) as u8,
        day: tm.tm_mday as u8,
        hour: tm.tm_hour as u8,
        minute: tm.tm_min as u8,
        second: tm.tm_sec as u8,
    }
}

/// Now, in local time.
#[cfg(windows)]
pub fn local_now() -> Timestamp {
    use windows_sys::Win32::Foundation::SYSTEMTIME;
    // SAFETY: `GetLocalTime` fills the struct it is given.
    let time: SYSTEMTIME = unsafe {
        let mut time: SYSTEMTIME = std::mem::zeroed();
        windows_sys::Win32::System::SystemInformation::GetLocalTime(&mut time);
        time
    };
    Timestamp {
        year: time.wYear,
        month: time.wMonth as u8,
        day: time.wDay as u8,
        hour: time.wHour as u8,
        minute: time.wMinute as u8,
        second: time.wSecond as u8,
    }
}

/// Now, in local time.
#[cfg(not(any(unix, windows)))]
pub fn local_now() -> Timestamp {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    Timestamp::from_unix(seconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_safe_everywhere() {
        assert_eq!(safe("a/b:c?.jpg"), "a-b-c-.jpg");
        assert_eq!(safe(".hidden"), "hidden");
        assert_eq!(safe("CON.txt"), "_CON.txt");
        assert_eq!(safe("COM3"), "_COM3");
        assert_eq!(safe("trailing. "), "trailing");
        assert_eq!(safe("..."), "Untitled");
    }

    #[test]
    fn taken_names_get_a_number() {
        let dir = std::env::temp_dir().join(format!("procmon-unique-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("photo.jpg"), b"x").unwrap();
        assert_eq!(unique(&dir.join("photo.jpg")), dir.join("photo 2.jpg"));
        assert_eq!(unique(&dir.join("new.jpg")), dir.join("new.jpg"));
        fs::remove_dir_all(dir).ok();
    }
}
