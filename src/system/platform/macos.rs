use std::ffi::CStr;
use std::mem;

use libproc::libproc::pid_rusage::{RUsageInfoV2, pidrusage};
use libproc::libproc::task_info::TaskAllInfo;
use libproc::libproc::thread_info::ThreadInfo;
use libproc::proc_pid::{ListThreads, listpidinfo, pidinfo, pidpath};

use super::{TaskCounters, ThreadRunState, ThreadSample};
use crate::system::snapshot::{MemoryBreakdown, MemoryPressure};
use crate::units::{Bytes, Pid, Ratio, ThreadId};

/// `TH_USAGE_SCALE` from `<mach/thread_info.h>`: `pth_cpu_usage` of 1000 is one full core.
const TH_USAGE_SCALE: f64 = 1000.0;

/// The kernel's 32-bit counters wrap; widening keeps rates correct until the next wrap,
/// where [`Rate::between`](crate::units::Rate::between) reports zero instead of garbage.
fn counter(value: i32) -> u64 {
    value as u32 as u64
}

pub fn task_counters(pid: Pid) -> Option<TaskCounters> {
    let pid = pid.0 as i32;
    let task = pidinfo::<TaskAllInfo>(pid, 0).ok()?.ptinfo;
    let usage = pidrusage::<RUsageInfoV2>(pid).ok();
    Some(TaskCounters {
        syscalls: counter(task.pti_syscalls_unix) + counter(task.pti_syscalls_mach),
        context_switches: counter(task.pti_csw),
        mach_messages: counter(task.pti_messages_sent) + counter(task.pti_messages_received),
        page_faults: counter(task.pti_faults),
        idle_wakeups: usage.as_ref().map_or(0, |u| u.ri_pkg_idle_wkups),
        threads: task.pti_threadnum.max(0) as u32,
        footprint: usage.as_ref().map(|u| Bytes(u.ri_phys_footprint)),
    })
}

pub fn threads(pid: Pid, hint: u32) -> Option<Vec<ThreadSample>> {
    let pid = pid.0 as i32;
    let handles = listpidinfo::<ListThreads>(pid, hint.max(1) as usize).ok()?;
    let samples = handles
        .into_iter()
        .filter_map(|handle| {
            let info = pidinfo::<ThreadInfo>(pid, handle).ok()?;
            Some(ThreadSample {
                id: ThreadId(handle),
                name: thread_name(&info),
                state: run_state(info.pth_run_state),
                cpu: Ratio::new(f64::from(info.pth_cpu_usage) / TH_USAGE_SCALE),
            })
        })
        .collect();
    Some(samples)
}

pub fn executable_path(pid: Pid) -> Option<std::path::PathBuf> {
    pidpath(pid.0 as i32).ok().map(Into::into)
}

fn thread_name(info: &ThreadInfo) -> Option<String> {
    // SAFETY: the kernel NUL-terminates `pth_name` within its 64-byte buffer.
    let name = unsafe { CStr::from_ptr(info.pth_name.as_ptr()) };
    let name = name.to_string_lossy();
    (!name.is_empty()).then(|| name.into_owned())
}

fn run_state(raw: i32) -> ThreadRunState {
    match raw {
        1 => ThreadRunState::Running,
        2 => ThreadRunState::Stopped,
        3 => ThreadRunState::Waiting,
        4 => ThreadRunState::Uninterruptible,
        5 => ThreadRunState::Halted,
        _ => ThreadRunState::Unknown,
    }
}

pub fn memory_breakdown() -> Option<MemoryBreakdown> {
    let mut stats: libc::vm_statistics64 = unsafe { mem::zeroed() };
    let mut count = libc::HOST_VM_INFO64_COUNT;
    // SAFETY: `stats` is a correctly sized, writable `vm_statistics64` and `count`
    // tells the kernel how many `integer_t`s it may write.
    let status = unsafe {
        libc::host_statistics64(
            mach2::mach_init::mach_host_self(),
            libc::HOST_VM_INFO64,
            (&raw mut stats).cast(),
            &mut count,
        )
    };
    if status != libc::KERN_SUCCESS {
        return None;
    }
    let page_size = page_size()?;
    let pages = |n: u64| Bytes(n.saturating_mul(page_size));
    let internal = u64::from(stats.internal_page_count);
    let purgeable = u64::from(stats.purgeable_count);
    Some(MemoryBreakdown {
        app: pages(internal.saturating_sub(purgeable)),
        wired: pages(u64::from(stats.wire_count)),
        compressed: pages(u64::from(stats.compressor_page_count)),
        cached: pages(u64::from(stats.external_page_count) + purgeable),
        free: pages(u64::from(stats.free_count)),
    })
}

fn page_size() -> Option<u64> {
    sysctl_i32(c"hw.pagesize").and_then(|size| u64::try_from(size).ok())
}

pub fn memory_pressure() -> MemoryPressure {
    match sysctl_i32(c"kern.memorystatus_vm_pressure_level") {
        Some(1) => MemoryPressure::Normal,
        Some(2) => MemoryPressure::Warning,
        Some(4) => MemoryPressure::Critical,
        _ => MemoryPressure::Unknown,
    }
}

fn sysctl_i32(name: &CStr) -> Option<i32> {
    let mut value: i32 = 0;
    let mut len = mem::size_of::<i32>();
    // SAFETY: `value` is a writable i32 and `len` matches its size.
    let status = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            (&raw mut value).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (status == 0).then_some(value)
}
