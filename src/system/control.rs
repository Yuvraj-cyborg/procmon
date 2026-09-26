//! Acting on processes: asking them to quit, or killing them.

use std::fmt;
use std::io;

use crate::units::Pid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    /// `SIGTERM`: ask the process to shut down cleanly.
    Terminate,
    /// `SIGKILL`: stop it immediately; unsaved work is lost.
    Kill,
}

#[derive(Debug)]
pub enum SignalError {
    /// PID 0/1 and Procmon itself are never signalled.
    Protected,
    NotPermitted,
    NoSuchProcess,
    Other(io::Error),
}

impl fmt::Display for SignalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SignalError::Protected => write!(f, "this process is protected"),
            SignalError::NotPermitted => {
                write!(
                    f,
                    "permission denied — it belongs to another user or to the system"
                )
            }
            SignalError::NoSuchProcess => write!(f, "the process has already exited"),
            SignalError::Other(err) => err.fmt(f),
        }
    }
}

pub fn send(pid: Pid, signal: Signal) -> Result<(), SignalError> {
    if pid.0 <= 1 || pid.0 == std::process::id() {
        return Err(SignalError::Protected);
    }
    deliver(pid, signal)
}

#[cfg(unix)]
fn deliver(pid: Pid, signal: Signal) -> Result<(), SignalError> {
    let raw = match signal {
        Signal::Terminate => libc::SIGTERM,
        Signal::Kill => libc::SIGKILL,
    };
    let pid = libc::pid_t::try_from(pid.0).map_err(|_| SignalError::NoSuchProcess)?;
    // SAFETY: `kill` has no memory-safety preconditions.
    if unsafe { libc::kill(pid, raw) } == 0 {
        return Ok(());
    }
    let err = io::Error::last_os_error();
    Err(match err.raw_os_error() {
        Some(libc::EPERM) => SignalError::NotPermitted,
        Some(libc::ESRCH) => SignalError::NoSuchProcess,
        _ => SignalError::Other(err),
    })
}

#[cfg(not(unix))]
fn deliver(_pid: Pid, _signal: Signal) -> Result<(), SignalError> {
    Err(SignalError::Other(io::Error::new(
        io::ErrorKind::Unsupported,
        "signals are not supported on this platform",
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_to_signal_init_or_itself() {
        assert!(matches!(
            send(Pid(1), Signal::Terminate),
            Err(SignalError::Protected)
        ));
        assert!(matches!(
            send(Pid(0), Signal::Kill),
            Err(SignalError::Protected)
        ));
        let me = Pid(std::process::id());
        assert!(matches!(
            send(me, Signal::Kill),
            Err(SignalError::Protected)
        ));
    }

    #[test]
    fn terminates_a_child_process() {
        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .unwrap();
        send(Pid(child.id()), Signal::Terminate).unwrap();
        let status = child.wait().unwrap();
        assert!(!status.success());
    }
}
