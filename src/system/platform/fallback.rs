use super::{TaskCounters, ThreadSample};
use crate::system::snapshot::{MemoryBreakdown, MemoryPressure};
use crate::units::Pid;

pub fn task_counters(_pid: Pid) -> Option<TaskCounters> {
    None
}

pub fn threads(_pid: Pid, _hint: u32) -> Option<Vec<ThreadSample>> {
    None
}

pub fn memory_breakdown() -> Option<MemoryBreakdown> {
    None
}

pub fn memory_pressure() -> MemoryPressure {
    MemoryPressure::Unknown
}
