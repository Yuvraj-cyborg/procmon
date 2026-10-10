//! The GPU: how busy it is, which processes use it, and a short benchmark.

mod bench;
mod probe;

pub use bench::{BenchError, BenchRecord, BenchTest, Benchmark};
pub use probe::{GpuProbe, GpuStats, GpuUsage};
