use super::snapshot::{AppUsage, ProcessInfo};
use crate::units::Pid;

/// What the user typed into a process filter box: a case-insensitive
/// substring of the process or app name, or an exact PID.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProcessQuery {
    needle: String,
    pid: Option<Pid>,
}

impl ProcessQuery {
    pub fn parse(input: &str) -> Self {
        let needle = input.trim().to_lowercase();
        let pid = needle.parse().ok().map(Pid);
        Self { needle, pid }
    }

    pub fn is_empty(&self) -> bool {
        self.needle.is_empty()
    }

    fn matches_name(&self, name: &str) -> bool {
        name.to_lowercase().contains(&self.needle)
    }

    pub fn matches_process(&self, process: &ProcessInfo) -> bool {
        self.is_empty()
            || self.pid == Some(process.pid)
            || self.matches_name(&process.name)
            || self.matches_name(&process.app)
    }

    pub fn matches_app(&self, app: &AppUsage) -> bool {
        self.is_empty() || self.matches_name(&app.name)
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::units::{Bytes, Percent, Throughput};

    fn process(pid: u32, name: &str, app: &str) -> ProcessInfo {
        ProcessInfo {
            pid: Pid(pid),
            name: name.to_string().into(),
            app: app.to_string().into(),
            memory: Bytes::ZERO,
            cpu: Percent::ZERO,
            threads: None,
            disk_read: Throughput::default(),
            disk_write: Throughput::default(),
            run_time: Duration::ZERO,
            activity: None,
            network: None,
        }
    }

    #[test]
    fn matches_name_app_or_exact_pid() {
        let helper = process(4242, "Helium Helper (Renderer)", "Helium");
        assert!(ProcessQuery::parse("").matches_process(&helper));
        assert!(ProcessQuery::parse("  renderer ").matches_process(&helper));
        assert!(ProcessQuery::parse("HELIUM").matches_process(&helper));
        assert!(ProcessQuery::parse("4242").matches_process(&helper));
        assert!(!ProcessQuery::parse("424").matches_process(&process(4242, "a", "a")));
        assert!(!ProcessQuery::parse("cursor").matches_process(&helper));
    }
}
