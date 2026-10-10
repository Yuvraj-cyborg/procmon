//! How busy the GPU is, how much memory it holds, and which processes use it.
//!
//! - Linux: AMD cards report their load in sysfs; NVIDIA's management
//!   library is loaded if the driver installed it; every DRM driver (Intel,
//!   AMD, and others) reports each client's engine time in `/proc/*/fdinfo`.
//! - Windows: the "GPU Engine" performance counters Task Manager reads.

use std::collections::HashMap;
use std::time::Duration;

use crate::units::{Bytes, Percent, Pid, Ratio};

#[derive(Debug, Clone, PartialEq)]
pub struct GpuStats {
    pub name: Option<String>,
    /// `None` where the driver doesn't say.
    pub utilization: Option<Ratio>,
    pub memory_used: Option<Bytes>,
    pub memory_total: Option<Bytes>,
}

/// How much of the GPU one process used.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GpuUsage {
    /// Share of the GPU's time over the last interval.
    pub share: Percent,
    /// GPU memory the process holds, where the driver reports it.
    pub memory: Option<Bytes>,
}

pub struct GpuProbe {
    platform: platform::Probe,
}

impl GpuProbe {
    pub fn new() -> Self {
        Self { platform: platform::Probe::new() }
    }

    /// Readings for the busiest GPU, and each process's share when
    /// `per_process` is set (on Linux that walks every open file, so it is
    /// asked for only while someone looks).
    pub fn sample(&mut self, per_process: bool, elapsed: Duration) -> (Option<GpuStats>, HashMap<Pid, GpuUsage>) {
        self.platform.sample(per_process, elapsed)
    }
}

/// Engine time each DRM client used, from one `/proc/<pid>/fdinfo/<fd>` file:
/// its client id, nanoseconds per engine, and the memory it holds.
#[cfg(any(target_os = "linux", test))]
pub fn parse_fdinfo(text: &str) -> Option<(String, HashMap<String, u64>, Option<u64>)> {
    let mut client = None;
    let mut engines = HashMap::new();
    let mut memory: Option<u64> = None;
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else { continue };
        let value = value.trim();
        if key == "drm-client-id" {
            client = Some(value.to_string());
        } else if let Some(engine) = key.strip_prefix("drm-engine-") {
            if let Some(ns) = value.strip_suffix("ns").and_then(|n| n.trim().parse().ok()) {
                engines.insert(engine.to_string(), ns);
            }
        } else if key.starts_with("drm-total-") || key == "drm-memory-vram" {
            // `drm-total-<region>: 1024 KiB` (or MiB), summed over regions.
            let mut parts = value.split_whitespace();
            if let (Some(number), unit) = (parts.next().and_then(|n| n.parse::<u64>().ok()), parts.next()) {
                let scale = match unit {
                    Some("KiB") => 1 << 10,
                    Some("MiB") => 1 << 20,
                    Some("GiB") => 1 << 30,
                    _ => 1,
                };
                *memory.get_or_insert(0) += number * scale;
            }
        }
    }
    Some((client?, engines, memory))
}

/// The marketing name in a `pci.ids` device entry, e.g. `Radeon RX 6600` from
/// `Navi 23 [Radeon RX 6600/6600 XT/6600M]`, under its vendor's short name.
#[cfg(any(target_os = "linux", test))]
pub fn pci_name(ids: &str, vendor: &str, device: &str) -> Option<String> {
    let mut in_vendor = false;
    let mut vendor_name = String::new();
    for line in ids.lines() {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        if !line.starts_with('\t') {
            if in_vendor {
                break;
            }
            if let Some(name) = line.strip_prefix(vendor).and_then(|rest| rest.strip_prefix("  ")) {
                in_vendor = true;
                vendor_name = name.to_string();
            }
            continue;
        }
        if in_vendor
            && let Some(name) = line.strip_prefix('\t').and_then(|l| l.strip_prefix(device)).and_then(|l| l.strip_prefix("  "))
        {
            let model = match (name.find('['), name.rfind(']')) {
                (Some(open), Some(close)) if close > open => &name[open + 1..close],
                _ => name,
            };
            let maker = match vendor {
                "1002" => "AMD",
                "10de" => "NVIDIA",
                "8086" => "Intel",
                _ => vendor_name.split_whitespace().next().unwrap_or_default(),
            };
            return Some(format!("{maker} {model}"));
        }
    }
    None
}

/// Windows names each engine counter instance like
/// `pid_1234_luid_0x0_0x1D1B5_phys_0_eng_3_engtype_3D`: the process, the
/// engine, and the engine's kind.
#[cfg(any(windows, test))]
pub fn parse_engine_instance(name: &str) -> Option<(u32, String, String)> {
    let rest = name.strip_prefix("pid_")?;
    let (pid, rest) = rest.split_once('_')?;
    let (engine, kind) = rest.rsplit_once("_engtype_")?;
    Some((pid.parse().ok()?, engine.to_string(), kind.to_string()))
}

#[cfg(target_os = "linux")]
mod platform {
    use std::collections::HashMap;
    use std::ffi::{CStr, c_char, c_uint, c_void};
    use std::fs;
    use std::path::PathBuf;
    use std::time::Duration;

    use super::{GpuStats, GpuUsage, parse_fdinfo, pci_name};
    use crate::units::{Bytes, Percent, Pid, Ratio};

    struct Card {
        device: PathBuf,
        name: Option<String>,
    }

    pub struct Probe {
        cards: Vec<Card>,
        nvml: Option<Nvml>,
        /// Engine nanoseconds per (process, DRM client), from the last walk.
        clients: HashMap<(u32, String), HashMap<String, u64>>,
    }

    impl Probe {
        pub fn new() -> Self {
            Self {
                cards: cards(),
                nvml: Nvml::load(),
                clients: HashMap::new(),
            }
        }

        pub fn sample(&mut self, per_process: bool, elapsed: Duration) -> (Option<GpuStats>, HashMap<Pid, GpuUsage>) {
            let mut usage = HashMap::new();
            let mut busiest_engine = None;
            if per_process {
                let (per_pid, engine_load) = self.walk_clients(elapsed);
                usage = per_pid;
                busiest_engine = engine_load;
            } else {
                self.clients.clear();
            }
            if let Some(nvml) = &mut self.nvml {
                let stats = nvml.stats();
                if per_process {
                    for (pid, share) in nvml.processes() {
                        usage.entry(pid).or_insert(GpuUsage { share, memory: None }).share = share;
                    }
                }
                return (Some(stats), usage);
            }
            let mut best: Option<GpuStats> = None;
            for card in &self.cards {
                let read = |file: &str| fs::read_to_string(card.device.join(file)).ok().and_then(|t| t.trim().parse::<u64>().ok());
                let stats = GpuStats {
                    name: card.name.clone(),
                    utilization: read("gpu_busy_percent").map(|p| Ratio::new(p as f64 / 100.0)).or(busiest_engine),
                    memory_used: read("mem_info_vram_used").map(Bytes),
                    memory_total: read("mem_info_vram_total").map(Bytes),
                };
                let load = |s: &GpuStats| s.utilization.map_or(-1.0, Ratio::get);
                if best.as_ref().is_none_or(|b| load(&stats) > load(b)) {
                    best = Some(stats);
                }
            }
            (best, usage)
        }

        /// Each process's share from its DRM clients' engine time, and the
        /// busiest engine overall (used where the card reports no load).
        fn walk_clients(&mut self, elapsed: Duration) -> (HashMap<Pid, GpuUsage>, Option<Ratio>) {
            let mut current: HashMap<(u32, String), HashMap<String, u64>> = HashMap::new();
            let mut memory: HashMap<u32, u64> = HashMap::new();
            let Ok(processes) = fs::read_dir("/proc") else { return (HashMap::new(), None) };
            for process in processes.flatten() {
                let Ok(pid) = process.file_name().to_string_lossy().parse::<u32>() else { continue };
                let Ok(fds) = fs::read_dir(process.path().join("fd")) else { continue };
                for fd in fds.flatten() {
                    let is_gpu = fs::read_link(fd.path()).is_ok_and(|target| target.starts_with("/dev/dri/"));
                    if !is_gpu {
                        continue;
                    }
                    let info = process.path().join("fdinfo").join(fd.file_name());
                    let Some((client, engines, held)) = fs::read_to_string(info).ok().as_deref().and_then(parse_fdinfo) else {
                        continue;
                    };
                    // Several descriptors can share one client; count it once.
                    if current.contains_key(&(pid, client.clone())) {
                        continue;
                    }
                    if let Some(held) = held {
                        *memory.entry(pid).or_default() += held;
                    }
                    current.insert((pid, client), engines);
                }
            }
            let nanos = elapsed.as_nanos().max(1) as f64;
            let mut usage: HashMap<Pid, GpuUsage> = HashMap::new();
            let mut per_engine: HashMap<String, u64> = HashMap::new();
            for (key, engines) in &current {
                let before = self.clients.get(key);
                let mut busiest = 0.0f64;
                for (engine, now) in engines {
                    let delta = before.and_then(|b| b.get(engine)).map_or(0, |was| now.saturating_sub(*was));
                    *per_engine.entry(engine.clone()).or_default() += delta;
                    busiest = busiest.max(delta as f64 / nanos);
                }
                let entry = usage.entry(Pid(key.0)).or_insert(GpuUsage {
                    share: Percent::ZERO,
                    memory: memory.get(&key.0).copied().map(Bytes),
                });
                entry.share = Percent::new(entry.share.get() + busiest * 100.0);
            }
            let engine_load = per_engine.values().map(|ns| *ns as f64 / nanos).fold(None, |best: Option<f64>, load| {
                Some(best.map_or(load, |b| b.max(load)))
            });
            let had_baseline = !self.clients.is_empty();
            self.clients = current;
            (usage, engine_load.filter(|_| had_baseline).map(Ratio::new))
        }
    }

    fn cards() -> Vec<Card> {
        let ids = ["/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids", "/usr/share/pci.ids"]
            .iter()
            .find_map(|path| fs::read_to_string(path).ok())
            .unwrap_or_default();
        let Ok(entries) = fs::read_dir("/sys/class/drm") else { return Vec::new() };
        entries
            .flatten()
            .filter(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                name.strip_prefix("card").is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
            })
            .map(|entry| {
                let device = entry.path().join("device");
                let uevent = fs::read_to_string(device.join("uevent")).unwrap_or_default();
                let name = uevent
                    .lines()
                    .find_map(|l| l.strip_prefix("PCI_ID="))
                    .and_then(|id| id.split_once(':'))
                    .and_then(|(vendor, device)| pci_name(&ids, &vendor.to_lowercase(), &device.to_lowercase()));
                Card { device, name }
            })
            .collect()
    }

    /// NVIDIA's management library, loaded only if the driver installed it.
    struct Nvml {
        device: *mut c_void,
        name: Option<String>,
        utilization: unsafe extern "C" fn(*mut c_void, *mut [c_uint; 2]) -> i32,
        memory: unsafe extern "C" fn(*mut c_void, *mut [u64; 3]) -> i32,
        processes: unsafe extern "C" fn(*mut c_void, *mut ProcessSample, *mut c_uint, u64) -> i32,
        last_seen: u64,
    }

    // SAFETY: the NVML device handle may be used from any thread.
    unsafe impl Send for Nvml {}

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct ProcessSample {
        pid: c_uint,
        timestamp: u64,
        sm: c_uint,
        memory: c_uint,
        encoder: c_uint,
        decoder: c_uint,
    }

    impl Nvml {
        fn load() -> Option<Self> {
            // SAFETY: symbols are looked up by name and called with the
            // signatures NVML documents.
            unsafe {
                let library = libc::dlopen(c"libnvidia-ml.so.1".as_ptr(), libc::RTLD_LAZY);
                if library.is_null() {
                    return None;
                }
                let symbol = |name: &CStr| {
                    let pointer = libc::dlsym(library, name.as_ptr());
                    (!pointer.is_null()).then_some(pointer)
                };
                let init: unsafe extern "C" fn() -> i32 = std::mem::transmute(symbol(c"nvmlInit_v2")?);
                let handle: unsafe extern "C" fn(c_uint, *mut *mut c_void) -> i32 =
                    std::mem::transmute(symbol(c"nvmlDeviceGetHandleByIndex_v2")?);
                let name: unsafe extern "C" fn(*mut c_void, *mut c_char, c_uint) -> i32 =
                    std::mem::transmute(symbol(c"nvmlDeviceGetName")?);
                if init() != 0 {
                    return None;
                }
                let mut device = std::ptr::null_mut();
                if handle(0, &mut device) != 0 {
                    return None;
                }
                let mut buffer = [0 as c_char; 96];
                let label = (name(device, buffer.as_mut_ptr(), buffer.len() as c_uint) == 0)
                    .then(|| CStr::from_ptr(buffer.as_ptr()).to_string_lossy().into_owned());
                Some(Self {
                    device,
                    name: label,
                    utilization: std::mem::transmute(symbol(c"nvmlDeviceGetUtilizationRates")?),
                    memory: std::mem::transmute(symbol(c"nvmlDeviceGetMemoryInfo")?),
                    processes: std::mem::transmute(symbol(c"nvmlDeviceGetProcessUtilization")?),
                    last_seen: 0,
                })
            }
        }

        fn stats(&self) -> GpuStats {
            let mut rates = [0 as c_uint; 2];
            let mut memory = [0u64; 3];
            // SAFETY: NVML fills the structs it is given.
            let (rated, measured) = unsafe { ((self.utilization)(self.device, &mut rates) == 0, (self.memory)(self.device, &mut memory) == 0) };
            GpuStats {
                name: self.name.clone(),
                utilization: rated.then(|| Ratio::new(f64::from(rates[0]) / 100.0)),
                memory_used: measured.then_some(Bytes(memory[2])),
                memory_total: measured.then_some(Bytes(memory[0])),
            }
        }

        fn processes(&mut self) -> Vec<(Pid, Percent)> {
            let mut count: c_uint = 0;
            // SAFETY: the first call only reports how many samples there are.
            unsafe { (self.processes)(self.device, std::ptr::null_mut(), &mut count, self.last_seen) };
            if count == 0 {
                return Vec::new();
            }
            let mut samples = vec![ProcessSample::default(); count as usize];
            // SAFETY: the buffer holds `count` samples.
            if unsafe { (self.processes)(self.device, samples.as_mut_ptr(), &mut count, self.last_seen) } != 0 {
                return Vec::new();
            }
            samples.truncate(count as usize);
            self.last_seen = samples.iter().map(|s| s.timestamp).max().unwrap_or(self.last_seen);
            samples.into_iter().map(|s| (Pid(s.pid), Percent::new(f64::from(s.sm)))).collect()
        }
    }
}

#[cfg(windows)]
mod platform {
    use std::collections::HashMap;
    use std::time::Duration;

    use windows_sys::Win32::System::Performance::{
        PDH_FMT_COUNTERVALUE_ITEM_W, PDH_FMT_DOUBLE, PDH_FMT_LARGE, PDH_HCOUNTER, PDH_HQUERY, PDH_MORE_DATA,
        PdhAddEnglishCounterW, PdhCollectQueryData, PdhGetFormattedCounterArrayW, PdhOpenQueryW,
    };

    use super::{GpuStats, GpuUsage, parse_engine_instance};
    use crate::units::{Bytes, Percent, Pid, Ratio};

    pub struct Probe {
        query: PDH_HQUERY,
        engines: PDH_HCOUNTER,
        adapter_memory: PDH_HCOUNTER,
        process_memory: PDH_HCOUNTER,
        adapter: Option<(String, u64)>,
        primed: bool,
    }

    // SAFETY: PDH handles may be used from any thread, one call at a time,
    // and the sampler owns the probe exclusively.
    unsafe impl Send for Probe {}

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain([0]).collect()
    }

    impl Probe {
        pub fn new() -> Self {
            let mut probe = Self {
                query: std::ptr::null_mut(),
                engines: std::ptr::null_mut(),
                adapter_memory: std::ptr::null_mut(),
                process_memory: std::ptr::null_mut(),
                adapter: adapter(),
                primed: false,
            };
            // SAFETY: PDH writes the handles it is given; paths are NUL-terminated.
            unsafe {
                if PdhOpenQueryW(std::ptr::null(), 0, &mut probe.query) == 0 {
                    PdhAddEnglishCounterW(probe.query, wide(r"\GPU Engine(*)\Utilization Percentage").as_ptr(), 0, &mut probe.engines);
                    PdhAddEnglishCounterW(probe.query, wide(r"\GPU Adapter Memory(*)\Dedicated Usage").as_ptr(), 0, &mut probe.adapter_memory);
                    PdhAddEnglishCounterW(probe.query, wide(r"\GPU Process Memory(*)\Dedicated Usage").as_ptr(), 0, &mut probe.process_memory);
                }
            }
            probe
        }

        pub fn sample(&mut self, _per_process: bool, _elapsed: Duration) -> (Option<GpuStats>, HashMap<Pid, GpuUsage>) {
            if self.query.is_null() {
                return (None, HashMap::new());
            }
            // SAFETY: the query handle came from PdhOpenQueryW.
            unsafe { PdhCollectQueryData(self.query) };
            let name = self.adapter.as_ref().map(|(name, _)| name.clone());
            let total = self.adapter.as_ref().map(|(_, memory)| Bytes(*memory)).filter(|b| b.0 > 0);
            if !self.primed {
                // Utilization is a rate: it needs a second collection.
                self.primed = true;
                return (Some(GpuStats { name, utilization: None, memory_used: None, memory_total: total }), HashMap::new());
            }
            // Task Manager's arithmetic: an engine's load is the sum over the
            // processes using it; the GPU's is its busiest engine; a process's
            // is its busiest engine kind.
            let mut engines: HashMap<String, f64> = HashMap::new();
            let mut by_kind: HashMap<(u32, String), f64> = HashMap::new();
            for (instance, value) in values(self.engines, PDH_FMT_DOUBLE) {
                let Some((pid, engine, kind)) = parse_engine_instance(&instance) else { continue };
                *engines.entry(engine).or_default() += value;
                *by_kind.entry((pid, kind)).or_default() += value;
            }
            let mut memory: HashMap<u32, u64> = HashMap::new();
            for (instance, value) in values(self.process_memory, PDH_FMT_LARGE) {
                if let Some(pid) = instance.strip_prefix("pid_").and_then(|r| r.split('_').next()).and_then(|p| p.parse().ok()) {
                    *memory.entry(pid).or_default() += value as u64;
                }
            }
            let mut usage: HashMap<Pid, GpuUsage> = HashMap::new();
            for ((pid, _), share) in by_kind {
                let entry = usage.entry(Pid(pid)).or_insert(GpuUsage {
                    share: Percent::ZERO,
                    memory: memory.get(&pid).copied().map(Bytes),
                });
                entry.share = Percent::new(entry.share.get().max(share));
            }
            let used = values(self.adapter_memory, PDH_FMT_LARGE).into_iter().map(|(_, v)| v as u64).max();
            let busiest = engines.values().copied().fold(0.0f64, f64::max);
            let stats = GpuStats {
                name,
                utilization: (!engines.is_empty()).then(|| Ratio::new(busiest / 100.0)),
                memory_used: used.map(Bytes),
                memory_total: total,
            };
            (Some(stats), usage)
        }
    }

    /// Every instance of a wildcard counter, with its value.
    fn values(counter: PDH_HCOUNTER, format: u32) -> Vec<(String, f64)> {
        let (mut size, mut count) = (0u32, 0u32);
        // SAFETY: the first call reports the buffer size; the second fills it.
        unsafe {
            if PdhGetFormattedCounterArrayW(counter, format, &mut size, &mut count, std::ptr::null_mut()) != PDH_MORE_DATA as u32 {
                return Vec::new();
            }
            let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
            let items = buffer.as_mut_ptr().cast::<PDH_FMT_COUNTERVALUE_ITEM_W>();
            if PdhGetFormattedCounterArrayW(counter, format, &mut size, &mut count, items) != 0 {
                return Vec::new();
            }
            std::slice::from_raw_parts(items, count as usize)
                .iter()
                .filter(|item| item.FmtValue.CStatus == 0)
                .map(|item| {
                    let mut length = 0;
                    while *item.szName.add(length) != 0 {
                        length += 1;
                    }
                    let name = String::from_utf16_lossy(std::slice::from_raw_parts(item.szName, length));
                    let value = if format == PDH_FMT_LARGE {
                        item.FmtValue.Anonymous.largeValue as f64
                    } else {
                        item.FmtValue.Anonymous.doubleValue
                    };
                    (name, value)
                })
                .collect()
        }
    }

    /// The hardware adapter with the most dedicated memory: its name and memory.
    fn adapter() -> Option<(String, u64)> {
        use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, DXGI_ADAPTER_FLAG_SOFTWARE, IDXGIFactory1};
        // SAFETY: COM calls on interfaces windows-rs keeps alive.
        unsafe {
            let factory: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
            let mut best: Option<(String, u64)> = None;
            for index in 0.. {
                let Ok(adapter) = factory.EnumAdapters1(index) else { break };
                let Ok(description) = adapter.GetDesc1() else { continue };
                if description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0 {
                    continue;
                }
                let end = description.Description.iter().position(|c| *c == 0).unwrap_or(description.Description.len());
                let name = String::from_utf16_lossy(&description.Description[..end]);
                let memory = description.DedicatedVideoMemory as u64;
                if best.as_ref().is_none_or(|(_, m)| memory > *m) {
                    best = Some((name, memory));
                }
            }
            best
        }
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod platform {
    use std::collections::HashMap;
    use std::time::Duration;

    use super::{GpuStats, GpuUsage};
    use crate::units::Pid;

    /// The shipped macOS app reads the GPU itself.
    pub struct Probe;

    impl Probe {
        pub fn new() -> Self {
            Self
        }

        pub fn sample(&mut self, _per_process: bool, _elapsed: Duration) -> (Option<GpuStats>, HashMap<Pid, GpuUsage>) {
            (None, HashMap::new())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_drm_client_engine_time() {
        let text = "pos:\t0\nflags:\t02100002\ndrm-driver:\ti915\ndrm-client-id:\t42\ndrm-engine-render:\t123456789 ns\ndrm-engine-video:\t0 ns\ndrm-total-system0:\t2048 KiB\n";
        let (client, engines, memory) = parse_fdinfo(text).unwrap();
        assert_eq!(client, "42");
        assert_eq!(engines["render"], 123_456_789);
        assert_eq!(engines.len(), 2);
        assert_eq!(memory, Some(2 << 20));
        assert!(parse_fdinfo("pos:\t0\n").is_none());
    }

    #[test]
    fn names_cards_from_pci_ids() {
        let ids = "# comment\n1002  Advanced Micro Devices, Inc. [AMD/ATI]\n\t73ff  Navi 23 [Radeon RX 6600/6600 XT/6600M]\n\t1638  Cezanne\n8086  Intel Corporation\n\t46a6  Alder Lake-P GT2 [Iris Xe Graphics]\n";
        assert_eq!(pci_name(ids, "1002", "73ff").as_deref(), Some("AMD Radeon RX 6600/6600 XT/6600M"));
        assert_eq!(pci_name(ids, "1002", "1638").as_deref(), Some("AMD Cezanne"));
        assert_eq!(pci_name(ids, "8086", "46a6").as_deref(), Some("Intel Iris Xe Graphics"));
        assert_eq!(pci_name(ids, "10de", "2204"), None);
    }

    #[test]
    fn reads_windows_engine_instances() {
        let parsed = parse_engine_instance("pid_1234_luid_0x00000000_0x0000D1B5_phys_0_eng_3_engtype_3D").unwrap();
        assert_eq!(parsed, (1234, "luid_0x00000000_0x0000D1B5_phys_0_eng_3".into(), "3D".into()));
        assert!(parse_engine_instance("luid_0x0_phys_0").is_none());
    }
}
