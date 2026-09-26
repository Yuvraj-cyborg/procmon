//! Live system telemetry: sampling, platform probes and the shared [`Monitor`] model.

pub mod control;
mod monitor;
pub mod network;
mod platform;
pub mod query;
mod sampler;
pub mod snapshot;

pub use monitor::Monitor;
pub use platform::{ThreadRunState, ThreadSample, executable_path};

use crate::units::Pid;

/// Current threads of one process, or `None` if it cannot be inspected.
pub fn inspect_threads(pid: Pid) -> Option<Vec<ThreadSample>> {
    let hint = platform::task_counters(pid).map_or(64, |c| c.threads);
    platform::threads(pid, hint + platform::THREAD_SLACK)
}
