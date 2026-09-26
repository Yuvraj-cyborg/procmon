//! Device inventory from `system_profiler`, `kmutil` and `systemextensionsctl`.
//!
//! These are Apple's supported, stable interfaces for this information; the
//! JSON keys differ between macOS versions, so parsing is defensive and every
//! field is optional.

use std::collections::HashSet;
use std::process::Command;

use serde_json::Value;

use super::model::{Device, DeviceClass, DeviceStatus, Driver, DriverKind, DriverState, Inventory};

const PROFILER_TYPES: [&str; 9] = [
    "SPUSBHostDataType",
    "SPUSBDataType",
    "SPThunderboltDataType",
    "SPBluetoothDataType",
    "SPDisplaysDataType",
    "SPAudioDataType",
    "SPCameraDataType",
    "SPNetworkDataType",
    "SPStorageDataType",
];

pub fn collect() -> Inventory {
    let mut inventory = Inventory::default();
    match run(
        "/usr/sbin/system_profiler",
        &[&["-json", "-detailLevel", "mini"][..], &PROFILER_TYPES].concat(),
    ) {
        Ok(json) => match serde_json::from_str::<Value>(&json) {
            Ok(report) => inventory.devices = parse_profiler(&report),
            Err(err) => inventory.errors.push(format!("system_profiler: {err}")),
        },
        Err(err) => inventory.errors.push(err),
    }
    match run("/usr/bin/kmutil", &["showloaded", "--list-only"]) {
        Ok(text) => inventory.drivers.extend(parse_kmutil(&text)),
        Err(err) => inventory.errors.push(err),
    }
    match run("/usr/bin/systemextensionsctl", &["list"]) {
        Ok(text) => inventory.drivers.extend(parse_system_extensions(&text)),
        Err(err) => inventory.errors.push(err),
    }
    inventory
}

fn run(program: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|err| format!("{program}: {err}"))?;
    if !output.status.success() {
        return Err(format!("{program} exited with {}", output.status));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn text<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

fn items(value: &Value) -> impl Iterator<Item = &Value> {
    value
        .get("_items")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
}

fn section<'a>(report: &'a Value, key: &str) -> impl Iterator<Item = &'a Value> {
    report
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
}

/// Strips `system_profiler`'s enum-ish prefixes: `spdisplays_internal` → `internal`.
fn humanize(raw: &str, prefix: &str) -> String {
    raw.strip_prefix(prefix).unwrap_or(raw).replace('_', " ")
}

fn parse_profiler(report: &Value) -> Vec<Device> {
    let mut devices = Vec::new();
    for key in ["SPUSBHostDataType", "SPUSBDataType"] {
        for bus in section(report, key) {
            collect_usb(bus, &mut devices);
        }
    }
    for bus in section(report, "SPThunderboltDataType") {
        collect_thunderbolt(bus, &mut devices);
    }
    for controller in section(report, "SPBluetoothDataType") {
        collect_bluetooth(controller, &mut devices);
    }
    for gpu in section(report, "SPDisplaysDataType") {
        collect_display(gpu, &mut devices);
    }
    for group in section(report, "SPAudioDataType") {
        devices.extend(items(group).filter_map(audio_device));
    }
    devices.extend(section(report, "SPCameraDataType").filter_map(camera_device));
    devices.extend(section(report, "SPNetworkDataType").filter_map(network_device));
    devices.extend(storage_devices(section(report, "SPStorageDataType")));
    devices.sort_by(|a, b| (a.class, a.status, &a.name).cmp(&(b.class, b.status, &b.name)));
    devices
}

/// USB buses are built into the Mac; only what hangs off them is interesting.
fn collect_usb(node: &Value, out: &mut Vec<Device>) {
    for child in items(node) {
        if let Some(name) = text(child, &["_name"]) {
            let facts = [
                text(child, &["USBDeviceKeyVendorName", "manufacturer"]),
                text(child, &["USBDeviceKeyLinkSpeed", "device_speed"]),
            ]
            .into_iter()
            .flatten()
            .map(|s| humanize(s, "usb_"))
            .collect();
            out.push(Device {
                class: DeviceClass::Usb,
                name: name.to_string(),
                status: DeviceStatus::Connected,
                facts,
                driver: text(child, &["Driver"]).map(str::to_string),
            });
        }
        collect_usb(child, out);
    }
}

fn collect_thunderbolt(node: &Value, out: &mut Vec<Device>) {
    for child in items(node) {
        if let Some(name) = text(child, &["_name", "device_name_key"]) {
            out.push(Device {
                class: DeviceClass::Thunderbolt,
                name: name.to_string(),
                status: DeviceStatus::Connected,
                facts: [
                    text(child, &["vendor_name_key"]),
                    text(child, &["mode_key"]),
                ]
                .into_iter()
                .flatten()
                .map(str::to_string)
                .collect(),
                driver: None,
            });
        }
        collect_thunderbolt(child, out);
    }
}

fn collect_bluetooth(controller: &Value, out: &mut Vec<Device>) {
    for (key, status) in [
        ("device_connected", DeviceStatus::Connected),
        ("device_not_connected", DeviceStatus::Available),
    ] {
        let Some(list) = controller.get(key).and_then(Value::as_array) else {
            continue;
        };
        // Each entry is a single-key object: `{ "Device name": { ...props } }`.
        for (name, props) in list.iter().filter_map(Value::as_object).flatten() {
            let battery = text(props, &["device_batteryLevelMain", "device_batteryLevel"])
                .map(|level| format!("Battery {level}"));
            out.push(Device {
                class: DeviceClass::Bluetooth,
                name: name.clone(),
                status,
                facts: [
                    text(props, &["device_minorType"]).map(str::to_string),
                    battery,
                ]
                .into_iter()
                .flatten()
                .collect(),
                driver: None,
            });
        }
    }
}

fn collect_display(gpu: &Value, out: &mut Vec<Device>) {
    if let Some(name) = text(gpu, &["_name", "sppci_model"]) {
        let cores = text(gpu, &["sppci_cores"]).map(|c| format!("{c} GPU cores"));
        let metal = text(gpu, &["spdisplays_mtlgpufamilysupport"])
            .map(|m| humanize(m, "spdisplays_").replace("metal", "Metal "));
        out.push(Device {
            class: DeviceClass::Display,
            name: name.to_string(),
            status: DeviceStatus::Connected,
            facts: [cores, metal].into_iter().flatten().collect(),
            driver: None,
        });
    }
    for display in gpu
        .get("spdisplays_ndrvs")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(name) = text(display, &["_name"]) else {
            continue;
        };
        let online = text(display, &["spdisplays_online"]) != Some("spdisplays_no");
        out.push(Device {
            class: DeviceClass::Display,
            name: name.to_string(),
            status: if online {
                DeviceStatus::Connected
            } else {
                DeviceStatus::Faulty
            },
            facts: [
                text(
                    display,
                    &["_spdisplays_resolution", "spdisplays_resolution"],
                )
                .map(str::to_string),
                text(display, &["spdisplays_connection_type"]).map(|c| humanize(c, "spdisplays_")),
            ]
            .into_iter()
            .flatten()
            .collect(),
            driver: None,
        });
    }
}

fn audio_device(item: &Value) -> Option<Device> {
    let name = text(item, &["_name"])?;
    let channels = |key: &str| item.get(key).and_then(Value::as_u64).filter(|n| *n > 0);
    let direction = match (
        channels("coreaudio_device_input"),
        channels("coreaudio_device_output"),
    ) {
        (Some(_), Some(_)) => Some("Input & output"),
        (Some(_), None) => Some("Input"),
        (None, Some(_)) => Some("Output"),
        (None, None) => None,
    };
    let transport = text(item, &["coreaudio_device_transport"])
        .map(|t| humanize(t, "coreaudio_device_type_"))
        .filter(|t| t != "unknown");
    let is_default = [
        "coreaudio_default_audio_input_device",
        "coreaudio_default_audio_output_device",
    ]
    .iter()
    .any(|key| text(item, &[key]) == Some("spaudio_yes"));
    Some(Device {
        class: DeviceClass::Audio,
        name: name.to_string(),
        status: DeviceStatus::Connected,
        facts: [
            direction.map(str::to_string),
            transport,
            is_default.then(|| "Default".to_string()),
        ]
        .into_iter()
        .flatten()
        .collect(),
        driver: None,
    })
}

fn camera_device(item: &Value) -> Option<Device> {
    Some(Device {
        class: DeviceClass::Camera,
        name: text(item, &["_name"])?.to_string(),
        status: DeviceStatus::Connected,
        facts: text(item, &["spcamera_model-id"])
            .map(str::to_string)
            .into_iter()
            .collect(),
        driver: None,
    })
}

fn network_device(item: &Value) -> Option<Device> {
    let has_address = item
        .get("ip_address")
        .and_then(Value::as_array)
        .is_some_and(|addrs| !addrs.is_empty());
    Some(Device {
        class: DeviceClass::Network,
        name: text(item, &["_name"])?.to_string(),
        status: if has_address {
            DeviceStatus::Connected
        } else {
            DeviceStatus::Available
        },
        facts: [
            text(item, &["interface"]),
            text(item, &["hardware", "type"]),
        ]
        .into_iter()
        .flatten()
        .map(str::to_string)
        .collect(),
        driver: None,
    })
}

/// One device per physical drive (volumes share drives); disk images are skipped.
fn storage_devices<'a>(volumes: impl Iterator<Item = &'a Value>) -> Vec<Device> {
    let mut seen = HashSet::new();
    volumes
        .filter_map(|volume| volume.get("physical_drive"))
        .filter(|drive| text(drive, &["protocol"]) != Some("Disk Image"))
        .filter_map(|drive| {
            let name = text(drive, &["device_name"])?;
            seen.insert(name.to_string()).then_some((name, drive))
        })
        .map(|(name, drive)| {
            let smart = text(drive, &["smart_status"]);
            let internal = text(drive, &["is_internal_disk"]) == Some("yes");
            Device {
                class: DeviceClass::Storage,
                name: name.to_string(),
                status: match smart {
                    Some(status) if status != "Verified" => DeviceStatus::Faulty,
                    _ => DeviceStatus::Connected,
                },
                facts: [
                    text(drive, &["protocol"]).map(str::to_string),
                    text(drive, &["medium_type"]).map(str::to_uppercase),
                    Some(if internal { "Internal" } else { "External" }.to_string()),
                    smart.map(|s| format!("SMART {s}")),
                ]
                .into_iter()
                .flatten()
                .collect(),
                driver: None,
            }
        })
        .collect()
}

/// Parses `kmutil showloaded --list-only`:
/// `Index Refs Address Size Wired Name (Version) UUID <Linked Against>`.
fn parse_kmutil(text: &str) -> Vec<Driver> {
    text.lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            fields.next()?.parse::<u32>().ok()?;
            let references = fields.next()?.parse().ok();
            let bundle_id = fields.nth(3)?.to_string();
            let version = fields
                .next()
                .and_then(|v| v.strip_prefix('(')?.strip_suffix(')'))
                .map(str::to_string);
            Some(Driver {
                bundle_id,
                name: None,
                version,
                kind: DriverKind::KernelExtension,
                state: DriverState::Running,
                references,
            })
        })
        .collect()
}

/// Parses `systemextensionsctl list`, whose rows are tab-separated:
/// `enabled  active  teamID  bundleID (version)  name  [state]`,
/// grouped under `--- com.apple.system_extension.<category>` headers.
fn parse_system_extensions(text: &str) -> Vec<Driver> {
    let mut kind = DriverKind::SystemExtension;
    let mut drivers = Vec::new();
    for line in text.lines() {
        if let Some(header) = line.strip_prefix("--- ") {
            kind = if header.contains("driver_extension") {
                DriverKind::DriverKit
            } else {
                DriverKind::SystemExtension
            };
            continue;
        }
        let columns: Vec<&str> = line.split('\t').collect();
        if columns.len() < 6 || columns[0] == "enabled" {
            continue;
        }
        let (bundle_id, version) = match columns[3].split_once(" (") {
            Some((id, version)) => (id, version.strip_suffix(')')),
            None => (columns[3], None),
        };
        let state = columns[5]
            .trim()
            .trim_start_matches('[')
            .trim_end_matches(']');
        drivers.push(Driver {
            bundle_id: bundle_id.trim().to_string(),
            name: Some(columns[4].trim().to_string()).filter(|n| !n.is_empty()),
            version: version.map(str::to_string),
            kind,
            state: match state {
                "activated enabled" => DriverState::Running,
                s if s.contains("waiting for user") => DriverState::AwaitingApproval,
                s if s.contains("disabled") => DriverState::Disabled,
                s => DriverState::Other(s.to_string()),
            },
            references: None,
        });
    }
    drivers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_kmutil_rows() {
        let text = "    3  228 0                  0          0          com.apple.kpi.bsd (25.6.0) B445A6D8 <>\n\
                    121    0 0xfffffe0007 0x4000 0x4000 com.example.driver (1.2.3) ABCD <3 5>\n";
        let drivers = parse_kmutil(text);
        assert_eq!(drivers.len(), 2);
        assert_eq!(drivers[0].bundle_id, "com.apple.kpi.bsd");
        assert_eq!(drivers[0].references, Some(228));
        assert_eq!(drivers[1].version.as_deref(), Some("1.2.3"));
        assert!(drivers[1].is_third_party());
    }

    #[test]
    fn parses_system_extension_states() {
        let text = "2 extension(s)\n\
            --- com.apple.system_extension.cmio (Go to 'System Settings')\n\
            enabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n\
            \t*\t2MMRE5MTB8\tcom.obsproject.obs-studio.mac-camera-extension (31.1.2/165)\tOBS Virtual Camera\t[activated waiting for user]\n\
            --- com.apple.system_extension.driver_extension\n\
            *\t*\tABCDE12345\tcom.vendor.usbdriver (2.0)\tVendor USB\t[activated enabled]\n";
        let drivers = parse_system_extensions(text);
        assert_eq!(drivers.len(), 2);
        assert_eq!(drivers[0].state, DriverState::AwaitingApproval);
        assert_eq!(drivers[0].display_name(), "OBS Virtual Camera");
        assert_eq!(drivers[0].version.as_deref(), Some("31.1.2/165"));
        assert_eq!(drivers[1].kind, DriverKind::DriverKit);
        assert!(drivers[1].state.is_healthy());
    }

    #[test]
    fn parses_profiler_sections() {
        let report: Value = serde_json::from_str(
            r#"{
            "SPUSBHostDataType": [{"_name": "USB 3.1 Bus", "_items": [
                {"_name": "Keyboard", "USBDeviceKeyVendorName": "Keychron", "Driver": "AppleUSBHostHIDDevice",
                 "_items": [{"_name": "Hub child"}]}
            ]}],
            "SPBluetoothDataType": [{
                "device_connected": [{"AirPods": {"device_minorType": "Headphones", "device_batteryLevelMain": "80%"}}],
                "device_not_connected": [{"Mouse": {"device_minorType": "Mouse"}}]
            }],
            "SPDisplaysDataType": [{"_name": "Apple M4", "sppci_cores": "10",
                "spdisplays_ndrvs": [{"_name": "Color LCD", "spdisplays_online": "spdisplays_no"}]}],
            "SPStorageDataType": [
                {"physical_drive": {"device_name": "SSD", "protocol": "Apple Fabric", "smart_status": "Verified", "is_internal_disk": "yes"}},
                {"physical_drive": {"device_name": "SSD", "protocol": "Apple Fabric"}},
                {"physical_drive": {"device_name": "Disk Image", "protocol": "Disk Image"}},
                {"physical_drive": {"device_name": "Old HDD", "protocol": "USB", "smart_status": "Failing"}}
            ]
        }"#,
        )
        .unwrap();
        let devices = parse_profiler(&report);
        let find = |name: &str| devices.iter().find(|d| d.name == name).unwrap();

        assert_eq!(
            find("Keyboard").driver.as_deref(),
            Some("AppleUSBHostHIDDevice")
        );
        assert_eq!(find("Hub child").class, DeviceClass::Usb);
        assert!(!devices.iter().any(|d| d.name == "USB 3.1 Bus"));
        assert_eq!(find("AirPods").facts, vec!["Headphones", "Battery 80%"]);
        assert_eq!(find("Mouse").status, DeviceStatus::Available);
        assert_eq!(find("Color LCD").status, DeviceStatus::Faulty);
        assert_eq!(devices.iter().filter(|d| d.name == "SSD").count(), 1);
        assert!(!devices.iter().any(|d| d.name == "Disk Image"));
        assert_eq!(find("Old HDD").status, DeviceStatus::Faulty);
    }
}
