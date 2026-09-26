/// Hardware family, used for grouping and icons.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum DeviceClass {
    Usb,
    Thunderbolt,
    Bluetooth,
    Display,
    Audio,
    Camera,
    Network,
    Storage,
}

impl DeviceClass {
    pub const ALL: [DeviceClass; 8] = [
        DeviceClass::Usb,
        DeviceClass::Thunderbolt,
        DeviceClass::Bluetooth,
        DeviceClass::Display,
        DeviceClass::Audio,
        DeviceClass::Camera,
        DeviceClass::Network,
        DeviceClass::Storage,
    ];

    pub fn label(self) -> &'static str {
        match self {
            DeviceClass::Usb => "USB",
            DeviceClass::Thunderbolt => "Thunderbolt / USB4",
            DeviceClass::Bluetooth => "Bluetooth",
            DeviceClass::Display => "Displays & GPU",
            DeviceClass::Audio => "Audio",
            DeviceClass::Camera => "Cameras",
            DeviceClass::Network => "Network interfaces",
            DeviceClass::Storage => "Storage devices",
        }
    }
}

/// Whether a device is present and healthy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum DeviceStatus {
    /// Something is wrong (e.g. SMART failing, display offline).
    Faulty,
    Connected,
    /// Known to the system (paired, configured) but not currently attached.
    Available,
}

impl DeviceStatus {
    pub fn label(self) -> &'static str {
        match self {
            DeviceStatus::Faulty => "Problem",
            DeviceStatus::Connected => "Connected",
            DeviceStatus::Available => "Not connected",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub class: DeviceClass,
    pub name: String,
    pub status: DeviceStatus,
    /// Short facts shown under the name, e.g. "Apple Inc.", "40 Gb/s".
    pub facts: Vec<String>,
    /// Kernel driver bound to the device, when the OS reports one.
    pub driver: Option<String>,
}

#[cfg_attr(
    not(target_os = "macos"),
    allow(dead_code, reason = "only the macOS collector reports drivers so far")
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriverKind {
    /// Classic kernel extension loaded into the kernel.
    KernelExtension,
    /// User-space system extension (network, endpoint security, camera, …).
    SystemExtension,
    /// User-space hardware driver (DriverKit `.dext`).
    DriverKit,
}

impl DriverKind {
    pub fn label(self) -> &'static str {
        match self {
            DriverKind::KernelExtension => "Kernel extension",
            DriverKind::SystemExtension => "System extension",
            DriverKind::DriverKit => "DriverKit",
        }
    }
}

#[cfg_attr(
    not(target_os = "macos"),
    allow(dead_code, reason = "only the macOS collector reports drivers so far")
)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriverState {
    /// Loaded / activated and enabled: working.
    Running,
    /// Installed but blocked until the user approves it in System Settings.
    AwaitingApproval,
    /// Installed but switched off.
    Disabled,
    /// Anything else the OS reports, verbatim.
    Other(String),
}

impl DriverState {
    pub fn is_healthy(&self) -> bool {
        matches!(self, DriverState::Running)
    }

    pub fn label(&self) -> &str {
        match self {
            DriverState::Running => "Running",
            DriverState::AwaitingApproval => "Needs approval",
            DriverState::Disabled => "Disabled",
            DriverState::Other(state) => state,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Driver {
    pub bundle_id: String,
    /// Human-readable name when the OS provides one.
    pub name: Option<String>,
    pub version: Option<String>,
    pub kind: DriverKind,
    pub state: DriverState,
    /// How many other kexts link against this one; a rough "importance".
    pub references: Option<u32>,
}

impl Driver {
    pub fn is_third_party(&self) -> bool {
        !self.bundle_id.starts_with("com.apple.")
    }

    pub fn display_name(&self) -> &str {
        self.name.as_deref().unwrap_or(&self.bundle_id)
    }
}

/// Everything collected in one pass of the device probe.
#[derive(Debug, Clone, Default)]
pub struct Inventory {
    pub devices: Vec<Device>,
    pub drivers: Vec<Driver>,
    /// Probes that failed, so the UI can say what it could not see.
    pub errors: Vec<String>,
}
