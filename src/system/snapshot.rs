//! Immutable, UI-agnostic readings produced by the [`Sampler`](super::Sampler).

use std::time::Duration;

use gpui_kit::SharedString;

use super::network::NetworkRates;
use crate::units::{Bytes, Percent, Pid, Rate, Ratio, ThreadId, Throughput};

/// Everything measured in one sampling pass.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub memory: MemoryStats,
    pub cpu: CpuStats,
    pub processes: Vec<ProcessInfo>,
    pub thread_alerts: Vec<ThreadAlert>,
    pub coverage: ProbeCoverage,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MemoryStats {
    pub total: Bytes,
    pub used: Bytes,
    pub available: Bytes,
    pub swap_total: Bytes,
    pub swap_used: Bytes,
    /// Activity-Monitor style split; only available where the kernel exposes it.
    pub breakdown: Option<MemoryBreakdown>,
    pub pressure: MemoryPressure,
}

/// Where physical memory is going, as reported by the VM subsystem.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MemoryBreakdown {
    /// Anonymous memory owned by apps, minus purgeable pages.
    pub app: Bytes,
    /// Kernel-locked memory that can never be paged out.
    pub wired: Bytes,
    /// Pages held by the memory compressor.
    pub compressed: Bytes,
    /// File-backed and purgeable pages the OS can reclaim instantly.
    pub cached: Bytes,
    pub free: Bytes,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryPressure {
    Normal,
    Warning,
    Critical,
    Unknown,
}

impl MemoryPressure {
    pub fn label(self) -> &'static str {
        match self {
            MemoryPressure::Normal => "Normal",
            MemoryPressure::Warning => "Elevated",
            MemoryPressure::Critical => "Critical",
            MemoryPressure::Unknown => "Unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct CpuStats {
    /// Whole-machine utilisation.
    pub total: Ratio,
    pub cores: Vec<Ratio>,
    pub load: LoadAverage,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LoadAverage {
    pub one: f64,
    pub five: f64,
    pub fifteen: f64,
}

#[derive(Debug, Clone)]
pub struct ProcessInfo {
    pub pid: Pid,
    pub name: SharedString,
    /// Application the process belongs to (its outermost `.app` bundle), or
    /// the process name for plain executables.
    pub app: SharedString,
    /// Physical footprint where available (what Activity Monitor calls "Memory"),
    /// otherwise resident set size.
    pub memory: Bytes,
    /// Relative to a single core: 200% means two cores fully busy.
    pub cpu: Percent,
    pub threads: Option<u32>,
    pub disk_read: Throughput,
    pub disk_write: Throughput,
    pub run_time: Duration,
    /// Kernel counters; `None` when we lack permission to inspect the task.
    pub activity: Option<ActivityRates>,
    /// `None` when the process had no sockets in the last interval.
    pub network: Option<NetworkRates>,
}

impl ProcessInfo {
    /// Packets per second above which a process is flagged as flooding the network.
    const PACKETS: f64 = 5_000.0;

    pub fn noise_reasons(&self) -> Vec<NoiseReason> {
        let mut reasons = self
            .activity
            .as_ref()
            .map(ActivityRates::noise_reasons)
            .unwrap_or_default();
        if self
            .network
            .is_some_and(|n| n.packets.per_sec() >= Self::PACKETS)
        {
            reasons.push(NoiseReason::Packets);
        }
        reasons
    }

    /// Ranks processes by how hard they are hammering the kernel and network.
    pub fn intensity(&self) -> f64 {
        self.activity.map_or(0.0, |a| a.intensity())
            + self
                .network
                .map_or(0.0, |n| n.packets.per_sec() / Self::PACKETS)
    }
}

/// Resource usage of all processes belonging to one application.
#[derive(Debug, Clone, PartialEq)]
pub struct AppUsage {
    pub name: SharedString,
    pub processes: usize,
    pub memory: Bytes,
    pub cpu: Percent,
    pub threads: u32,
}

/// Rolls processes up by [`ProcessInfo::app`], largest memory first.
pub fn group_by_app(processes: &[ProcessInfo]) -> Vec<AppUsage> {
    let mut groups: std::collections::HashMap<&SharedString, AppUsage> =
        std::collections::HashMap::new();
    for process in processes {
        let group = groups.entry(&process.app).or_insert_with(|| AppUsage {
            name: process.app.clone(),
            processes: 0,
            memory: Bytes::ZERO,
            cpu: Percent::ZERO,
            threads: 0,
        });
        group.processes += 1;
        group.memory += process.memory;
        group.cpu = Percent::new(group.cpu.get() + process.cpu.get());
        group.threads += process.threads.unwrap_or(0);
    }
    let mut apps: Vec<AppUsage> = groups.into_values().collect();
    apps.sort_by_key(|app| std::cmp::Reverse(app.memory));
    apps
}

/// How chatty a process is with the kernel, per second.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ActivityRates {
    pub syscalls: Rate,
    pub context_switches: Rate,
    pub mach_messages: Rate,
    pub idle_wakeups: Rate,
    pub page_faults: Rate,
}

/// Why a process was flagged as noisy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoiseReason {
    Syscalls,
    ContextSwitches,
    MachMessages,
    Wakeups,
    PageFaults,
    Packets,
}

impl NoiseReason {
    pub fn label(self) -> &'static str {
        match self {
            NoiseReason::Syscalls => "syscall storm",
            NoiseReason::ContextSwitches => "context-switch thrash",
            NoiseReason::MachMessages => "IPC flood",
            NoiseReason::Wakeups => "frequent wakeups",
            NoiseReason::PageFaults => "page-fault storm",
            NoiseReason::Packets => "packet flood",
        }
    }
}

impl ActivityRates {
    /// Thresholds above which a single process is considered to be hammering
    /// the kernel. Tuned so that a busy-but-healthy browser stays under them.
    const SYSCALLS: f64 = 50_000.0;
    const CONTEXT_SWITCHES: f64 = 20_000.0;
    const MACH_MESSAGES: f64 = 20_000.0;
    const WAKEUPS: f64 = 1_000.0;
    const PAGE_FAULTS: f64 = 100_000.0;

    pub fn noise_reasons(&self) -> Vec<NoiseReason> {
        [
            (self.syscalls, Self::SYSCALLS, NoiseReason::Syscalls),
            (
                self.context_switches,
                Self::CONTEXT_SWITCHES,
                NoiseReason::ContextSwitches,
            ),
            (
                self.mach_messages,
                Self::MACH_MESSAGES,
                NoiseReason::MachMessages,
            ),
            (self.idle_wakeups, Self::WAKEUPS, NoiseReason::Wakeups),
            (self.page_faults, Self::PAGE_FAULTS, NoiseReason::PageFaults),
        ]
        .into_iter()
        .filter(|(rate, limit, _)| rate.per_sec() >= *limit)
        .map(|(_, _, reason)| reason)
        .collect()
    }

    /// A single number to rank processes by kernel chatter.
    pub fn intensity(&self) -> f64 {
        self.syscalls.per_sec() / Self::SYSCALLS
            + self.context_switches.per_sec() / Self::CONTEXT_SWITCHES
            + self.mach_messages.per_sec() / Self::MACH_MESSAGES
            + self.idle_wakeups.per_sec() / Self::WAKEUPS
            + self.page_faults.per_sec() / Self::PAGE_FAULTS
    }
}

/// A thread that has been in a suspicious state across several samples.
#[derive(Debug, Clone)]
pub struct ThreadAlert {
    pub pid: Pid,
    pub process: SharedString,
    pub thread: ThreadId,
    pub thread_name: Option<SharedString>,
    pub kind: ThreadAlertKind,
    pub duration: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ThreadAlertKind {
    /// Stuck in an uninterruptible kernel wait (typically I/O or a lock).
    Blocked,
    /// Suspended, e.g. by a debugger or SIGSTOP.
    Stopped,
    /// Pegging a core without pause.
    Spinning { cpu: Ratio },
}

impl ThreadAlertKind {
    pub fn label(self) -> &'static str {
        match self {
            ThreadAlertKind::Blocked => "Blocked",
            ThreadAlertKind::Stopped => "Stopped",
            ThreadAlertKind::Spinning { .. } => "Spinning",
        }
    }
}

/// How much of the system the thread/task probes could actually see.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ProbeCoverage {
    pub inspected: usize,
    pub denied: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(app: &str, memory: u64) -> ProcessInfo {
        ProcessInfo {
            pid: Pid(1),
            name: app.into(),
            app: app.into(),
            memory: Bytes(memory),
            cpu: Percent::new(1.0),
            threads: Some(2),
            disk_read: Throughput::default(),
            disk_write: Throughput::default(),
            run_time: Duration::ZERO,
            activity: None,
            network: None,
        }
    }

    #[test]
    fn groups_processes_by_app() {
        let apps = group_by_app(&[
            process("Helium", 100),
            process("yes", 500),
            process("Helium", 300),
        ]);
        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].name, "yes");
        assert_eq!(apps[1].memory, Bytes(400));
        assert_eq!(apps[1].processes, 2);
        assert_eq!(apps[1].threads, 4);
    }

    #[test]
    fn quiet_process_has_no_noise() {
        let rates = ActivityRates::default();
        assert!(rates.noise_reasons().is_empty());
        assert_eq!(rates.intensity(), 0.0);
    }

    #[test]
    fn syscall_storm_is_flagged() {
        let rates = ActivityRates {
            syscalls: Rate::between(0, 80_000, Duration::from_secs(1)),
            ..Default::default()
        };
        assert_eq!(rates.noise_reasons(), vec![NoiseReason::Syscalls]);
    }
}
