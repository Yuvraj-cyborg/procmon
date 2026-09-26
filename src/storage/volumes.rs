use std::path::PathBuf;

use sysinfo::{DiskKind, Disks};

use crate::units::Bytes;

#[derive(Debug, Clone, PartialEq)]
pub struct Volume {
    pub name: String,
    pub mount_point: PathBuf,
    pub file_system: String,
    pub total: Bytes,
    pub available: Bytes,
    pub removable: bool,
    pub kind: VolumeKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VolumeKind {
    Ssd,
    Hdd,
    Unknown,
}

impl Volume {
    pub fn used(&self) -> Bytes {
        self.total - self.available
    }
}

/// Mounted volumes worth showing to a person. On macOS this hides the
/// APFS helper volumes (Preboot, VM, Update, …) under `/System/Volumes`
/// except the Data volume, which is where user files actually live.
pub fn list_volumes() -> Vec<Volume> {
    let disks = Disks::new_with_refreshed_list();
    let mut volumes: Vec<Volume> = disks
        .list()
        .iter()
        .filter(|disk| {
            let mount = disk.mount_point();
            !mount.starts_with("/System/Volumes")
                || mount == std::path::Path::new("/System/Volumes/Data")
        })
        .filter(|disk| disk.total_space() > 0)
        .map(|disk| Volume {
            name: disk.name().to_string_lossy().into_owned(),
            mount_point: disk.mount_point().to_path_buf(),
            file_system: disk.file_system().to_string_lossy().into_owned(),
            total: Bytes(disk.total_space()),
            available: Bytes(disk.available_space()),
            removable: disk.is_removable(),
            kind: match disk.kind() {
                DiskKind::SSD => VolumeKind::Ssd,
                DiskKind::HDD => VolumeKind::Hdd,
                DiskKind::Unknown(_) => VolumeKind::Unknown,
            },
        })
        .collect();
    volumes.sort_by(|a, b| a.removable.cmp(&b.removable).then(b.total.cmp(&a.total)));
    volumes
}
