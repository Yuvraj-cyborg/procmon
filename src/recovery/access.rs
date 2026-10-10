//! Opens a disk for reading, sector by sector, asking the system for
//! permission where the current user may not read it.
//!
//! - Linux: UDisks2 checks with polkit, which asks for a password through the
//!   desktop, and hands back one read-only file descriptor over D-Bus.
//! - Windows: raw disks open only for administrators, so Procmon offers to
//!   restart itself elevated.
//!
//! Procmon never writes to the disk being recovered.

use std::fs::File;
use std::io;

use super::disks::Disk;
use super::reader::RawDevice;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccessError {
    /// The password prompt was dismissed.
    Cancelled,
    /// Windows: only an administrator can read disks directly.
    NeedsAdministrator,
    Failed(String),
}

impl std::fmt::Display for AccessError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AccessError::Cancelled => f.write_str("Reading the disk needs an administrator's password."),
            AccessError::NeedsAdministrator => f.write_str("Reading disks directly needs administrator rights."),
            AccessError::Failed(detail) => write!(f, "The disk couldn't be opened: {detail}"),
        }
    }
}

/// Opens `disk` read-only, asking for permission only if it must. Blocks
/// while a password prompt is up: never call on the UI thread.
pub fn open(disk: &Disk) -> Result<RawDevice, AccessError> {
    let device = |file: File| RawDevice::from_file(file, &disk.path).map_err(|e| AccessError::Failed(e.to_string()));
    match open_direct(disk) {
        Ok(file) => device(file),
        Err(err) if err.kind() == io::ErrorKind::PermissionDenied => device(open_authorized(disk)?),
        Err(err) => Err(AccessError::Failed(err.to_string())),
    }
}

#[cfg(windows)]
fn open_direct(disk: &Disk) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt as _;
    use windows_sys::Win32::Storage::FileSystem::{FILE_SHARE_READ, FILE_SHARE_WRITE};
    // Other programs keep the disk open; sharing is what lets us read it too.
    File::options()
        .read(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .open(&disk.path)
}

#[cfg(not(windows))]
fn open_direct(disk: &Disk) -> io::Result<File> {
    File::open(&disk.path)
}

#[cfg(target_os = "linux")]
fn open_authorized(disk: &Disk) -> Result<File, AccessError> {
    use std::collections::HashMap;

    use zbus::zvariant::{OwnedFd, Value};

    // UDisks2 names objects after the kernel's device names, escaping anything
    // that is not a letter, digit or underscore.
    let escaped: String = disk
        .id
        .bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b == b'_' { char::from(b).to_string() } else { format!("_{b:02x}") })
        .collect();
    let path = format!("/org/freedesktop/UDisks2/block_devices/{escaped}");
    let result: zbus::Result<OwnedFd> = async_io::block_on(async {
        let connection = zbus::Connection::system().await?;
        let proxy = zbus::Proxy::new(&connection, "org.freedesktop.UDisks2", path.as_str(), "org.freedesktop.UDisks2.Block").await?;
        let options: HashMap<&str, Value> = HashMap::new();
        proxy.call("OpenDevice", &("r", options)).await
    });
    match result {
        Ok(fd) => Ok(File::from(std::os::fd::OwnedFd::from(fd))),
        Err(zbus::Error::MethodError(name, _, _)) if name.as_str().contains("NotAuthorized") => Err(AccessError::Cancelled),
        Err(err) => Err(AccessError::Failed(format!(
            "{err}. Install udisks2, or run Procmon with sudo to read disks directly"
        ))),
    }
}

#[cfg(windows)]
fn open_authorized(_disk: &Disk) -> Result<File, AccessError> {
    Err(AccessError::NeedsAdministrator)
}

#[cfg(not(any(target_os = "linux", windows)))]
fn open_authorized(_disk: &Disk) -> Result<File, AccessError> {
    Err(AccessError::Failed("run Procmon with sudo to read disks directly".into()))
}

/// Whether this process may read disks directly.
#[cfg(windows)]
pub fn is_elevated() -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::Security::{GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    // SAFETY: the token handle is closed before returning; the output is plain data.
    unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return false;
        }
        let mut elevation: TOKEN_ELEVATION = std::mem::zeroed();
        let mut size = 0u32;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            std::ptr::from_mut(&mut elevation).cast(),
            size_of::<TOKEN_ELEVATION>() as u32,
            &mut size,
        );
        CloseHandle(token);
        ok != 0 && elevation.TokenIsElevated != 0
    }
}

#[cfg(not(windows))]
pub fn is_elevated() -> bool {
    true
}

/// Starts Procmon again as administrator on the Recovery page; Windows shows
/// its own consent prompt. Returns whether the new copy started.
#[cfg(windows)]
pub fn relaunch_elevated() -> bool {
    use std::os::windows::ffi::OsStrExt as _;
    use windows_sys::Win32::UI::Shell::ShellExecuteW;
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
    let Ok(exe) = std::env::current_exe() else { return false };
    let wide = |text: &std::ffi::OsStr| text.encode_wide().chain([0]).collect::<Vec<u16>>();
    let (verb, file, parameters) = (wide("runas".as_ref()), wide(exe.as_os_str()), wide("--page recovery".as_ref()));
    // SAFETY: NUL-terminated strings that outlive the call.
    let result = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            file.as_ptr(),
            parameters.as_ptr(),
            std::ptr::null(),
            SW_SHOWNORMAL,
        )
    };
    // Values above 32 mean success.
    result as usize > 32
}

#[cfg(not(windows))]
pub fn relaunch_elevated() -> bool {
    false
}
