//! Connected hardware and loaded drivers.

#[cfg(target_os = "macos")]
mod macos;
mod model;

pub use model::{Device, DeviceClass, DeviceStatus, Driver, Inventory};

/// Collects the current device inventory. Slow (hundreds of milliseconds);
/// call from a background thread.
pub fn collect() -> Inventory {
    #[cfg(target_os = "macos")]
    {
        macos::collect()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Inventory {
            errors: vec!["Device inventory is only implemented for macOS so far.".into()],
            ..Inventory::default()
        }
    }
}
