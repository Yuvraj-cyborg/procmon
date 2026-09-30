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

#[cfg(windows)]
fn deliver(pid: Pid, _signal: Signal) -> Result<(), SignalError> {
    use windows_sys::Win32::Foundation::{
        CloseHandle, ERROR_ACCESS_DENIED, ERROR_INVALID_PARAMETER, GetLastError,
    };
    use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_TERMINATE, TerminateProcess};

    fn last_error() -> SignalError {
        // SAFETY: `GetLastError` only reads the calling thread's error slot.
        match unsafe { GetLastError() } {
            ERROR_ACCESS_DENIED => SignalError::NotPermitted,
            ERROR_INVALID_PARAMETER => SignalError::NoSuchProcess,
            code => SignalError::Other(io::Error::from_raw_os_error(code as i32)),
        }
    }

    // Windows has no polite equivalent of SIGTERM for an arbitrary process,
    // so both signals end it.
    // SAFETY: plain Win32 calls; the handle is closed before returning.
    unsafe {
        let handle = OpenProcess(PROCESS_TERMINATE, 0, pid.0);
        if handle.is_null() {
            return Err(last_error());
        }
        let result = if TerminateProcess(handle, 1) == 0 {
            Err(last_error())
        } else {
            Ok(())
        };
        CloseHandle(handle);
        result
    }
}

#[cfg(not(any(unix, windows)))]
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
        let mut child = if cfg!(windows) {
            std::process::Command::new("ping")
                .args(["-n", "30", "127.0.0.1"])
                .stdout(std::process::Stdio::null())
                .spawn()
        } else {
            std::process::Command::new("sleep").arg("30").spawn()
        }
        .unwrap();
        send(Pid(child.id()), Signal::Terminate).unwrap();
        let status = child.wait().unwrap();
        assert!(!status.success());
    }
}
