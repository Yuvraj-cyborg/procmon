//! Live system telemetry: sampling, platform probes and the shared [`Monitor`] model.

mod monitor;
pub mod network;
mod platform;
pub mod query;
mod sampler;
pub mod snapshot;

pub use monitor::Monitor;
