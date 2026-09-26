//! OS-specific probes that go beyond what `sysinfo` offers.

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::*;

#[cfg(not(target_os = "macos"))]
mod fallback;
#[cfg(not(target_os = "macos"))]
pub use fallback::*;

use crate::units::{Bytes, Ratio, ThreadId};

/// Cumulative kernel counters for one task. Differencing two readings gives rates.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TaskCounters {
    pub syscalls: u64,
    pub context_switches: u64,
    pub mach_messages: u64,
    pub page_faults: u64,
    pub idle_wakeups: u64,
    pub threads: u32,
    pub footprint: Option<Bytes>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThreadRunState {
    Running,
    Stopped,
    Waiting,
    Uninterruptible,
    Halted,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct ThreadSample {
    pub id: ThreadId,
    pub name: Option<String>,
    pub state: ThreadRunState,
    /// Share of one core this thread used recently.
    pub cpu: Ratio,
}
