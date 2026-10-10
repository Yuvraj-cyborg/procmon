//! Disks recovery can read: every physical drive, card and attached disk
//! image, with the volumes on it.

use std::path::PathBuf;

use crate::units::Bytes;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum DiskKind {
    /// Memory cards, USB sticks and external drives: where recovery works.
    External,
    /// Disk image files attached as disks.
    Image,
    /// This computer's own drives.
    Internal,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DiskVolume {
    pub name: Option<String>,
    /// e.g. "vfat", "exfat", "NTFS".
    pub format: Option<String>,
    pub size: Bytes,
    pub mount_point: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Disk {
    /// Kernel or system name: `sdb`, `mmcblk0`, `PhysicalDrive1`.
    pub id: String,
    /// What to open: `/dev/sdb`, `\\.\PhysicalDrive1`.
    pub path: PathBuf,
    pub name: String,
    pub size: Bytes,
    /// "USB", "SD card", "NVMe"…
    pub connection: Option<String>,
    pub kind: DiskKind,
    pub volumes: Vec<DiskVolume>,
}

impl Disk {
    pub fn summary(&self) -> String {
        let mut parts = vec![self.size.decimal().to_string()];
        parts.extend(self.connection.clone());
        let names: Vec<&str> = self.volumes.iter().filter_map(|v| v.name.as_deref()).collect();
        if !names.is_empty() {
            parts.push(names.join(", "));
        }
        parts.join(" · ")
    }
}

/// Every disk, external ones first.
pub fn list() -> Vec<Disk> {
    let mut disks = platform::list();
    disks.sort_by(|a, b| (a.kind, &a.id).cmp(&(b.kind, &b.id)));
    disks
}

/// The disk (by [`Disk::id`]) holding `path`, so recovered files are never
/// saved onto the disk being recovered.
pub fn holding(path: &std::path::Path) -> Option<String> {
    platform::holding(path)
}

#[cfg(windows)]
pub use platform::device_geometry;

/// The `E:KEY=value` properties of a udev database entry.
#[cfg(any(target_os = "linux", test))]
fn parse_udev(text: &str) -> std::collections::HashMap<String, String> {
    text.lines()
        .filter_map(|line| line.strip_prefix("E:")?.split_once('='))
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect()
}

/// Device to mount point and file system, from `/proc/self/mounts`, whose
/// fields escape spaces as `\040`.
#[cfg(any(target_os = "linux", test))]
fn parse_mounts(text: &str) -> std::collections::HashMap<String, (PathBuf, String)> {
    text.lines()
        .filter_map(|line| {
            let mut fields = line.split(' ');
            let device = fields.next()?;
            let mount = fields.next()?.replace("\\040", " ").replace("\\011", "\t");
            let format = fields.next()?;
            device
                .starts_with("/dev/")
                .then(|| (device.to_string(), (PathBuf::from(mount), format.to_string())))
        })
        .collect()
}

#[cfg(target_os = "linux")]
mod platform {
    use std::collections::HashMap;
    use std::fs;
    use std::path::{Path, PathBuf};

    use super::{Disk, DiskKind, DiskVolume};
    use crate::units::Bytes;

    pub fn list() -> Vec<Disk> {
        let mounts = fs::read_to_string("/proc/self/mounts").map(|text| parse_mounts(&text)).unwrap_or_default();
        let Ok(entries) = fs::read_dir("/sys/block") else { return Vec::new() };
        entries
            .flatten()
            .filter_map(|entry| disk(&entry.path(), &entry.file_name().to_string_lossy(), &mounts))
            .collect()
    }

    fn read(path: impl AsRef<Path>) -> Option<String> {
        let text = fs::read_to_string(path).ok()?;
        let text = text.trim();
        (!text.is_empty()).then(|| text.to_string())
    }

    fn disk(sys: &Path, name: &str, mounts: &HashMap<String, (PathBuf, String)>) -> Option<Disk> {
        if ["ram", "zram", "dm-", "md", "sr", "fd", "nbd"].iter().any(|p| name.starts_with(p)) {
            return None;
        }
        let size = read(sys.join("size"))?.parse::<u64>().ok()? * 512;
        if size == 0 {
            return None;
        }
        let image = name.starts_with("loop");
        let backing = image.then(|| read(sys.join("loop/backing_file"))).flatten();
        if image && backing.is_none() {
            return None;
        }
        let device = fs::canonicalize(sys.join("device")).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let usb = device.contains("/usb");
        let card = name.starts_with("mmcblk");
        let removable = read(sys.join("removable")).as_deref() == Some("1");
        let connection = if image {
            "Disk image"
        } else if card {
            "SD card"
        } else if usb {
            "USB"
        } else if name.starts_with("nvme") {
            "NVMe"
        } else {
            "SATA"
        };
        let kind = if image {
            DiskKind::Image
        } else if removable || usb || card {
            DiskKind::External
        } else {
            DiskKind::Internal
        };
        let label = match &backing {
            Some(file) => Path::new(file).file_name().map(|n| n.to_string_lossy().into_owned()),
            None if card => read(sys.join("device/name")),
            None => {
                let vendor = read(sys.join("device/vendor")).unwrap_or_default();
                let model = read(sys.join("device/model")).unwrap_or_default();
                let joined = format!("{vendor} {model}").trim().to_string();
                (!joined.is_empty()).then_some(joined)
            }
        };
        let mut volumes: Vec<DiskVolume> = fs::read_dir(sys)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|child| child.path().join("partition").exists())
            .filter_map(|child| volume(&child.path(), &child.file_name().to_string_lossy(), mounts))
            .collect();
        if volumes.is_empty()
            && let Some(whole) = volume(sys, name, mounts).filter(|v| v.format.is_some())
        {
            // A card formatted without a partition table.
            volumes.push(whole);
        }
        Some(Disk {
            id: name.to_string(),
            path: PathBuf::from(format!("/dev/{name}")),
            name: label.unwrap_or_else(|| name.to_string()),
            size: Bytes(size),
            connection: Some(connection.to_string()),
            kind,
            volumes,
        })
    }

    fn volume(sys: &Path, name: &str, mounts: &HashMap<String, (PathBuf, String)>) -> Option<DiskVolume> {
        let size = read(sys.join("size"))?.parse::<u64>().ok()? * 512;
        let udev = read(sys.join("dev"))
            .and_then(|dev| fs::read_to_string(format!("/run/udev/data/b{dev}")).ok())
            .map(|text| parse_udev(&text))
            .unwrap_or_default();
        let mount = mounts.get(&format!("/dev/{name}"));
        Some(DiskVolume {
            name: udev.get("ID_FS_LABEL").cloned(),
            format: udev.get("ID_FS_TYPE").cloned().or_else(|| mount.map(|(_, fs)| fs.clone())),
            size: Bytes(size),
            mount_point: mount.map(|(path, _)| path.clone()),
        })
    }

    use super::{parse_mounts, parse_udev};

    pub fn holding(path: &Path) -> Option<String> {
        use std::os::unix::fs::MetadataExt as _;
        let dev = fs::metadata(path).ok()?.dev();
        let (major, minor) = (libc::major(dev), libc::minor(dev));
        let device = fs::canonicalize(format!("/sys/dev/block/{major}:{minor}")).ok()?;
        let disk = if device.join("partition").exists() { device.parent()? } else { device.as_path() };
        Some(disk.file_name()?.to_string_lossy().into_owned())
    }
}

#[cfg(windows)]
mod platform {
    use std::collections::HashMap;
    use std::ffi::c_void;
    use std::fs::File;
    use std::io;
    use std::os::windows::ffi::OsStrExt as _;
    use std::os::windows::io::AsRawHandle as _;
    use std::path::{Path, PathBuf};

    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_SHARE_READ, FILE_SHARE_WRITE, GetDiskFreeSpaceExW, GetLogicalDrives, GetVolumeInformationW,
        GetVolumePathNameW, OPEN_EXISTING,
    };
    use windows_sys::Win32::System::IO::DeviceIoControl;
    use windows_sys::Win32::System::Ioctl::{
        DISK_GEOMETRY_EX, GET_LENGTH_INFORMATION, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, IOCTL_DISK_GET_LENGTH_INFO,
        IOCTL_STORAGE_GET_DEVICE_NUMBER, IOCTL_STORAGE_QUERY_PROPERTY, PropertyStandardQuery, STORAGE_DEVICE_DESCRIPTOR,
        STORAGE_DEVICE_NUMBER, STORAGE_PROPERTY_QUERY, StorageDeviceProperty,
    };

    use super::{Disk, DiskKind, DiskVolume};
    use crate::units::Bytes;

    fn wide(text: &str) -> Vec<u16> {
        std::ffi::OsStr::new(text).encode_wide().chain([0]).collect()
    }

    /// Opens a device for queries only: no access rights, so no administrator needed.
    fn open_query(path: &str) -> Option<HANDLE> {
        let name = wide(path);
        // SAFETY: a NUL-terminated name and no security attributes or template.
        let handle = unsafe {
            CreateFileW(name.as_ptr(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, std::ptr::null(), OPEN_EXISTING, 0, std::ptr::null_mut())
        };
        (handle != INVALID_HANDLE_VALUE).then_some(handle)
    }

    /// Runs an ioctl that fills `output`; `false` when the device refused.
    fn control<T>(handle: HANDLE, code: u32, input: Option<&[u8]>, output: &mut T) -> bool {
        let mut returned = 0u32;
        let (input_pointer, input_size) = input.map_or((std::ptr::null(), 0), |i| (i.as_ptr().cast::<c_void>(), i.len() as u32));
        // SAFETY: the buffers are valid for the sizes passed, and the call is synchronous.
        unsafe {
            DeviceIoControl(
                handle,
                code,
                input_pointer,
                input_size,
                std::ptr::from_mut(output).cast::<c_void>(),
                size_of::<T>() as u32,
                &mut returned,
                std::ptr::null_mut(),
            ) != 0
        }
    }

    fn device_number(handle: HANDLE) -> Option<u32> {
        // SAFETY: plain data, filled by the ioctl.
        let mut number: STORAGE_DEVICE_NUMBER = unsafe { std::mem::zeroed() };
        control(handle, IOCTL_STORAGE_GET_DEVICE_NUMBER, None, &mut number).then_some(number.DeviceNumber)
    }

    /// Volumes with drive letters, by the number of the disk they are on.
    fn volumes() -> HashMap<u32, Vec<DiskVolume>> {
        let mut found: HashMap<u32, Vec<DiskVolume>> = HashMap::new();
        // SAFETY: no arguments.
        let mask = unsafe { GetLogicalDrives() };
        for index in 0..26u8 {
            if mask & (1 << index) == 0 {
                continue;
            }
            let letter = char::from(b'A' + index);
            let Some(handle) = open_query(&format!(r"\\.\{letter}:")) else { continue };
            let number = device_number(handle);
            // SAFETY: the handle came from CreateFileW.
            unsafe { CloseHandle(handle) };
            let Some(number) = number else { continue };
            let root = wide(&format!("{letter}:\\"));
            let mut label = [0u16; 261];
            let mut system = [0u16; 261];
            let mut total = 0u64;
            // SAFETY: buffers sized as declared; unused outputs are null.
            unsafe {
                GetVolumeInformationW(
                    root.as_ptr(),
                    label.as_mut_ptr(),
                    label.len() as u32,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    system.as_mut_ptr(),
                    system.len() as u32,
                );
                GetDiskFreeSpaceExW(root.as_ptr(), std::ptr::null_mut(), &mut total, std::ptr::null_mut());
            }
            let text = |buffer: &[u16]| {
                let text = String::from_utf16_lossy(&buffer[..buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len())]);
                (!text.is_empty()).then_some(text)
            };
            found.entry(number).or_default().push(DiskVolume {
                name: text(&label).or_else(|| Some(format!("{letter}:"))),
                format: text(&system),
                size: Bytes(total),
                mount_point: Some(PathBuf::from(format!("{letter}:\\"))),
            });
        }
        found
    }

    pub fn list() -> Vec<Disk> {
        let mut volumes = volumes();
        (0..32u32)
            .filter_map(|number| {
                let path = format!(r"\\.\PhysicalDrive{number}");
                let handle = open_query(&path)?;
                let described = describe(handle);
                // SAFETY: plain data, filled by the ioctl.
                let mut geometry: DISK_GEOMETRY_EX = unsafe { std::mem::zeroed() };
                let sized = control(handle, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, None, &mut geometry);
                // SAFETY: the handle came from CreateFileW.
                unsafe { CloseHandle(handle) };
                let (name, bus, removable) = described?;
                if !sized || geometry.DiskSize <= 0 {
                    return None;
                }
                // STORAGE_BUS_TYPE values.
                let connection = match bus {
                    7 => "USB",
                    0x0C => "SD card",
                    0x0D => "MMC",
                    0x11 => "NVMe",
                    0x0B => "SATA",
                    0x0E | 0x0F => "Virtual disk",
                    0x0A => "SAS",
                    _ => "Disk",
                };
                let kind = if matches!(bus, 0x0E | 0x0F) {
                    DiskKind::Image
                } else if removable || matches!(bus, 7 | 0x0C | 0x0D) {
                    DiskKind::External
                } else {
                    DiskKind::Internal
                };
                Some(Disk {
                    id: format!("PhysicalDrive{number}"),
                    path: PathBuf::from(path),
                    name: name.unwrap_or_else(|| format!("Disk {number}")),
                    size: Bytes(geometry.DiskSize as u64),
                    connection: Some(connection.to_string()),
                    kind,
                    volumes: volumes.remove(&number).unwrap_or_default(),
                })
            })
            .collect()
    }

    /// Vendor and product, bus type and whether the media is removable.
    fn describe(handle: HANDLE) -> Option<(Option<String>, i32, bool)> {
        // SAFETY: plain data.
        let mut query: STORAGE_PROPERTY_QUERY = unsafe { std::mem::zeroed() };
        query.PropertyId = StorageDeviceProperty;
        query.QueryType = PropertyStandardQuery;
        // SAFETY: the query is plain data viewed as bytes.
        let input = unsafe {
            std::slice::from_raw_parts(std::ptr::from_ref(&query).cast::<u8>(), size_of::<STORAGE_PROPERTY_QUERY>())
        };
        let mut buffer = [0u8; 1024];
        if !control(handle, IOCTL_STORAGE_QUERY_PROPERTY, Some(input), &mut buffer) {
            return None;
        }
        // SAFETY: the ioctl wrote a STORAGE_DEVICE_DESCRIPTOR at the start of the buffer.
        let descriptor: STORAGE_DEVICE_DESCRIPTOR = unsafe { std::ptr::read_unaligned(buffer.as_ptr().cast()) };
        let text = |offset: u32| {
            let start = offset as usize;
            if start == 0 || start >= buffer.len() {
                return None;
            }
            let end = buffer[start..].iter().position(|b| *b == 0).map_or(buffer.len(), |i| start + i);
            let text = String::from_utf8_lossy(&buffer[start..end]).trim().to_string();
            (!text.is_empty()).then_some(text)
        };
        let name = [text(descriptor.VendorIdOffset), text(descriptor.ProductIdOffset)]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" ");
        Some(((!name.is_empty()).then_some(name), descriptor.BusType, descriptor.RemovableMedia))
    }

    /// Size and sector size of an open disk.
    pub fn device_geometry(file: &File) -> io::Result<(u64, usize)> {
        let handle = file.as_raw_handle() as HANDLE;
        // SAFETY: plain data, filled by the ioctls.
        let mut length: GET_LENGTH_INFORMATION = unsafe { std::mem::zeroed() };
        if !control(handle, IOCTL_DISK_GET_LENGTH_INFO, None, &mut length) {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: as above.
        let mut geometry: DISK_GEOMETRY_EX = unsafe { std::mem::zeroed() };
        let sector = if control(handle, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, None, &mut geometry) {
            geometry.Geometry.BytesPerSector as usize
        } else {
            512
        };
        Ok((length.Length as u64, sector.max(512)))
    }

    pub fn holding(path: &Path) -> Option<String> {
        let name = wide(&path.to_string_lossy());
        let mut root = [0u16; 261];
        // SAFETY: NUL-terminated input; the output buffer is sized as declared.
        if unsafe { GetVolumePathNameW(name.as_ptr(), root.as_mut_ptr(), root.len() as u32) } == 0 {
            return None;
        }
        let root = String::from_utf16_lossy(&root[..root.iter().position(|c| *c == 0)?]);
        let volume = format!(r"\\.\{}", root.trim_end_matches('\\'));
        let handle = open_query(&volume)?;
        let number = device_number(handle);
        // SAFETY: the handle came from CreateFileW.
        unsafe { CloseHandle(handle) };
        Some(format!("PhysicalDrive{}", number?))
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod platform {
    use super::Disk;

    /// The shipped macOS app lists disks itself; this build reads disk images only.
    pub fn list() -> Vec<Disk> {
        Vec::new()
    }

    pub fn holding(_path: &std::path::Path) -> Option<String> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::{parse_mounts, parse_udev};

    #[test]
    fn reads_udev_properties_and_mounts() {
        let udev = parse_udev("S:disk/by-label/CARD\nE:ID_FS_TYPE=vfat\nE:ID_FS_LABEL=CARD\nG:systemd\n");
        assert_eq!(udev.get("ID_FS_TYPE").map(String::as_str), Some("vfat"));
        assert_eq!(udev.get("ID_FS_LABEL").map(String::as_str), Some("CARD"));
        let mounts = parse_mounts("/dev/sdb1 /media/me/MY\\040CARD vfat rw 0 0\nproc /proc proc rw 0 0\n");
        assert_eq!(mounts["/dev/sdb1"].0.to_string_lossy(), "/media/me/MY CARD");
        assert_eq!(mounts.len(), 1);
    }
}
