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

/// Extra room in thread-list buffers for threads spawned between asking how
/// many threads a task has and listing them.
pub const THREAD_SLACK: u32 = 16;

#[cfg_attr(
    not(target_os = "macos"),
    allow(
        dead_code,
        reason = "only the macOS probe reports thread states so far"
    )
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ThreadRunState {
    Uninterruptible,
    Stopped,
    Running,
    Waiting,
    Halted,
    Unknown,
}

impl ThreadRunState {
    pub fn label(self) -> &'static str {
        match self {
            ThreadRunState::Running => "Running",
            ThreadRunState::Waiting => "Waiting",
            ThreadRunState::Uninterruptible => "Blocked",
            ThreadRunState::Stopped => "Stopped",
            ThreadRunState::Halted => "Halted",
            ThreadRunState::Unknown => "Unknown",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ThreadSample {
    pub id: ThreadId,
    pub name: Option<String>,
    pub state: ThreadRunState,
    /// Share of one core this thread used recently.
    pub cpu: Ratio,
}
