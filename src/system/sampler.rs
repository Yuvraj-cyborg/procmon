use std::collections::HashMap;
use std::time::{Duration, Instant};

use gpui_kit::SharedString;
use sysinfo::{
    CpuRefreshKind, MemoryRefreshKind, ProcessRefreshKind, ProcessesToUpdate, RefreshKind, System,
};

use super::platform::{self, TaskCounters, ThreadRunState, ThreadSample};
use super::snapshot::{
    ActivityRates, CpuStats, LoadAverage, MemoryStats, ProbeCoverage, ProcessInfo, Snapshot,
    ThreadAlert, ThreadAlertKind,
};
use crate::units::{Bytes, Percent, Pid, Rate, ThreadId, Throughput};

/// Collects [`Snapshot`]s. Holds the previous readings needed to turn
/// cumulative kernel counters into per-second rates.
pub struct Sampler {
    system: System,
    last_sample: Instant,
    counters: HashMap<Pid, TaskCounters>,
    threads: ThreadTracker,
}

impl Sampler {
    pub fn new() -> Self {
        let system = System::new_with_specifics(
            RefreshKind::nothing()
                .with_memory(MemoryRefreshKind::everything())
                .with_cpu(CpuRefreshKind::nothing().with_cpu_usage())
                .with_processes(Self::process_refresh_kind()),
        );
        Self {
            system,
            last_sample: Instant::now(),
            counters: HashMap::new(),
            threads: ThreadTracker::default(),
        }
    }

    fn process_refresh_kind() -> ProcessRefreshKind {
        ProcessRefreshKind::nothing()
            .with_cpu()
            .with_memory()
            .with_disk_usage()
    }

    pub fn sample(&mut self) -> Snapshot {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_sample);
        self.last_sample = now;

        self.system.refresh_memory();
        self.system.refresh_cpu_usage();
        self.system.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            Self::process_refresh_kind(),
        );

        let mut coverage = ProbeCoverage::default();
        let mut thread_alerts = Vec::new();
        let mut next_counters = HashMap::with_capacity(self.system.processes().len());
        let processes = self
            .system
            .processes()
            .values()
            .map(|process| {
                let pid = Pid(process.pid().as_u32());
                let name: SharedString = process.name().to_string_lossy().into_owned().into();
                let counters = platform::task_counters(pid);
                match counters {
                    Some(_) => coverage.inspected += 1,
                    None => coverage.denied += 1,
                }
                let activity = counters.zip(self.counters.get(&pid)).map(|(now, before)| {
                    activity_between(before, &now, elapsed)
                });
                if let Some(counters) = counters {
                    next_counters.insert(pid, counters);
                    if let Some(samples) = platform::threads(pid, counters.threads) {
                        self.threads
                            .observe(pid, &name, &samples, now, &mut thread_alerts);
                    }
                }
                let disk = process.disk_usage();
                ProcessInfo {
                    pid,
                    parent: process.parent().map(|p| Pid(p.as_u32())),
                    memory: counters
                        .and_then(|c| c.footprint)
                        .unwrap_or(Bytes(process.memory())),
                    cpu: Percent::new(f64::from(process.cpu_usage())),
                    threads: counters.map(|c| c.threads),
                    disk_read: throughput(disk.read_bytes, elapsed),
                    disk_write: throughput(disk.written_bytes, elapsed),
                    run_time: Duration::from_secs(process.run_time()),
                    activity,
                    name,
                }
            })
            .collect();
        self.counters = next_counters;
        self.threads.finish_pass(now);
        thread_alerts.sort_by(|a, b| b.duration.cmp(&a.duration));

        Snapshot {
            taken_at: now,
            memory: self.memory_stats(),
            cpu: self.cpu_stats(),
            processes,
            thread_alerts,
            coverage,
        }
    }

    fn memory_stats(&self) -> MemoryStats {
        let total = Bytes(self.system.total_memory());
        let breakdown = platform::memory_breakdown();
        // Activity Monitor defines "used" as app + wired + compressed; prefer
        // that where we have it so the headline matches what users expect.
        let used = breakdown
            .map(|b| b.app + b.wired + b.compressed)
            .unwrap_or(Bytes(self.system.used_memory()));
        MemoryStats {
            total,
            used,
            available: Bytes(self.system.available_memory()),
            swap_total: Bytes(self.system.total_swap()),
            swap_used: Bytes(self.system.used_swap()),
            breakdown,
            pressure: platform::memory_pressure(),
        }
    }

    fn cpu_stats(&self) -> CpuStats {
        let load = System::load_average();
        CpuStats {
            total: Percent::new(f64::from(self.system.global_cpu_usage())).ratio_of(100.0),
            cores: self
                .system
                .cpus()
                .iter()
                .map(|cpu| Percent::new(f64::from(cpu.cpu_usage())).ratio_of(100.0))
                .collect(),
            load: LoadAverage {
                one: load.one,
                five: load.five,
                fifteen: load.fifteen,
            },
        }
    }
}

fn throughput(bytes: u64, elapsed: Duration) -> Throughput {
    let secs = elapsed.as_secs_f64();
    if secs <= 0.0 {
        return Throughput::default();
    }
    Throughput(Bytes((bytes as f64 / secs) as u64))
}

fn activity_between(before: &TaskCounters, now: &TaskCounters, elapsed: Duration) -> ActivityRates {
    ActivityRates {
        syscalls: Rate::between(before.syscalls, now.syscalls, elapsed),
        context_switches: Rate::between(before.context_switches, now.context_switches, elapsed),
        mach_messages: Rate::between(before.mach_messages, now.mach_messages, elapsed),
        idle_wakeups: Rate::between(before.idle_wakeups, now.idle_wakeups, elapsed),
        page_faults: Rate::between(before.page_faults, now.page_faults, elapsed),
    }
}

/// Remembers how long each thread has been in its current state, so a single
/// unlucky sample never raises an alert.
#[derive(Default)]
struct ThreadTracker {
    tracks: HashMap<(Pid, ThreadId), Track>,
}

struct Track {
    state: ThreadRunState,
    state_since: Instant,
    hot_since: Option<Instant>,
    seen_at: Instant,
}

impl ThreadTracker {
    const BLOCKED_AFTER: Duration = Duration::from_secs(3);
    const STOPPED_AFTER: Duration = Duration::from_secs(3);
    const SPINNING_AFTER: Duration = Duration::from_secs(10);
    const SPINNING_CPU: f64 = 0.9;

    fn observe(
        &mut self,
        pid: Pid,
        process: &SharedString,
        samples: &[ThreadSample],
        now: Instant,
        alerts: &mut Vec<ThreadAlert>,
    ) {
        for sample in samples {
            let track = self
                .tracks
                .entry((pid, sample.id))
                .or_insert_with(|| Track {
                    state: sample.state,
                    state_since: now,
                    hot_since: None,
                    seen_at: now,
                });
            track.seen_at = now;
            if track.state != sample.state {
                track.state = sample.state;
                track.state_since = now;
            }
            let hot = sample.cpu.get() >= Self::SPINNING_CPU;
            track.hot_since = match (hot, track.hot_since) {
                (true, None) => Some(now),
                (true, since) => since,
                (false, _) => None,
            };

            let in_state = now.duration_since(track.state_since);
            let kind = match track.state {
                ThreadRunState::Uninterruptible if in_state >= Self::BLOCKED_AFTER => {
                    Some((ThreadAlertKind::Blocked, in_state))
                }
                ThreadRunState::Stopped if in_state >= Self::STOPPED_AFTER => {
                    Some((ThreadAlertKind::Stopped, in_state))
                }
                _ => track
                    .hot_since
                    .map(|since| now.duration_since(since))
                    .filter(|hot_for| *hot_for >= Self::SPINNING_AFTER)
                    .map(|hot_for| (ThreadAlertKind::Spinning { cpu: sample.cpu }, hot_for)),
            };
            if let Some((kind, duration)) = kind {
                alerts.push(ThreadAlert {
                    pid,
                    process: process.clone(),
                    thread: sample.id,
                    thread_name: sample.name.clone().map(Into::into),
                    kind,
                    duration,
                });
            }
        }
    }

    /// Drops threads that were not seen in the pass that just finished.
    fn finish_pass(&mut self, now: Instant) {
        self.tracks.retain(|_, track| track.seen_at == now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::units::Ratio;

    fn sample(state: ThreadRunState, cpu: f64) -> ThreadSample {
        ThreadSample {
            id: ThreadId(1),
            name: None,
            state,
            cpu: Ratio::new(cpu),
        }
    }

    #[test]
    fn blocked_thread_alerts_only_after_threshold() {
        let mut tracker = ThreadTracker::default();
        let name: SharedString = "disk-hog".into();
        let start = Instant::now();
        let blocked = [sample(ThreadRunState::Uninterruptible, 0.0)];

        let mut alerts = Vec::new();
        tracker.observe(Pid(7), &name, &blocked, start, &mut alerts);
        tracker.finish_pass(start);
        assert!(alerts.is_empty());

        let later = start + Duration::from_secs(4);
        tracker.observe(Pid(7), &name, &blocked, later, &mut alerts);
        tracker.finish_pass(later);
        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].kind, ThreadAlertKind::Blocked);
    }

    #[test]
    fn spinning_resets_when_thread_cools_down() {
        let mut tracker = ThreadTracker::default();
        let name: SharedString = "spinner".into();
        let t0 = Instant::now();
        let mut alerts = Vec::new();
        for (secs, cpu) in [(0, 1.0), (6, 1.0), (7, 0.1), (12, 1.0), (16, 1.0)] {
            let now = t0 + Duration::from_secs(secs);
            tracker.observe(Pid(1), &name, &[sample(ThreadRunState::Running, cpu)], now, &mut alerts);
            tracker.finish_pass(now);
        }
        assert!(alerts.is_empty(), "cool-down at 7s must reset the spin timer");
    }

    /// Live smoke test: `cargo test sampler_live -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn sampler_live() {
        let mut sampler = Sampler::new();
        std::thread::sleep(Duration::from_millis(500));
        let started = Instant::now();
        let snapshot = sampler.sample();
        println!(
            "sample took {:?}: {} processes, coverage {:?}, {} alerts, used {} / {}",
            started.elapsed(),
            snapshot.processes.len(),
            snapshot.coverage,
            snapshot.thread_alerts.len(),
            snapshot.memory.used.binary(),
            snapshot.memory.total.binary(),
        );
        assert!(!snapshot.processes.is_empty());
    }

    #[test]
    fn vanished_threads_are_forgotten() {
        let mut tracker = ThreadTracker::default();
        let name: SharedString = "p".into();
        let t0 = Instant::now();
        tracker.observe(Pid(1), &name, &[sample(ThreadRunState::Waiting, 0.0)], t0, &mut Vec::new());
        tracker.finish_pass(t0);
        tracker.finish_pass(t0 + Duration::from_secs(1));
        assert!(tracker.tracks.is_empty());
    }
}
