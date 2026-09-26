//! Strongly-typed quantities used throughout the app.
//!
//! Raw `u64`/`f32` values from the OS are converted into these at the edge
//! (in the samplers) so the UI can never confuse bytes with pages, or a
//! percentage with a 0..1 ratio.

use std::fmt;
use std::ops::{Add, AddAssign, Sub};
use std::time::Duration;

/// A number of bytes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Bytes(pub u64);

impl Bytes {
    pub const ZERO: Self = Self(0);

    pub const fn get(self) -> u64 {
        self.0
    }

    pub fn saturating_sub(self, rhs: Self) -> Self {
        Self(self.0.saturating_sub(rhs.0))
    }

    /// Fraction of `total` this value represents, clamped to `0..=1`.
    pub fn ratio_of(self, total: Bytes) -> Ratio {
        if total.0 == 0 {
            Ratio::ZERO
        } else {
            Ratio::new(self.0 as f64 / total.0 as f64)
        }
    }

    /// Formats with 1024-based steps (how RAM is conventionally reported).
    pub fn binary(self) -> ByteDisplay {
        ByteDisplay {
            bytes: self,
            base: ByteBase::Binary,
        }
    }

    /// Formats with 1000-based steps (how disk vendors and Finder report storage).
    pub fn decimal(self) -> ByteDisplay {
        ByteDisplay {
            bytes: self,
            base: ByteBase::Decimal,
        }
    }
}

impl Add for Bytes {
    type Output = Self;
    fn add(self, rhs: Self) -> Self {
        Self(self.0.saturating_add(rhs.0))
    }
}

impl AddAssign for Bytes {
    fn add_assign(&mut self, rhs: Self) {
        self.0 = self.0.saturating_add(rhs.0);
    }
}

impl Sub for Bytes {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self {
        self.saturating_sub(rhs)
    }
}

impl std::iter::Sum for Bytes {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Self::ZERO, Add::add)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ByteBase {
    Binary,
    Decimal,
}

/// Display adapter returned by [`Bytes::binary`] and [`Bytes::decimal`].
#[derive(Debug, Clone, Copy)]
pub struct ByteDisplay {
    bytes: Bytes,
    base: ByteBase,
}

impl fmt::Display for ByteDisplay {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        const UNITS: [&str; 6] = ["B", "KB", "MB", "GB", "TB", "PB"];
        let step = match self.base {
            ByteBase::Binary => 1024.0,
            ByteBase::Decimal => 1000.0,
        };
        let mut value = self.bytes.0 as f64;
        let mut unit = 0;
        while value >= step && unit < UNITS.len() - 1 {
            value /= step;
            unit += 1;
        }
        match unit {
            0 => write!(f, "{} {}", self.bytes.0, UNITS[0]),
            _ if value >= 100.0 => write!(f, "{value:.0} {}", UNITS[unit]),
            _ if value >= 10.0 => write!(f, "{value:.1} {}", UNITS[unit]),
            _ => write!(f, "{value:.2} {}", UNITS[unit]),
        }
    }
}

/// A fraction in `0.0..=1.0`.
#[derive(Debug, Clone, Copy, Default, PartialEq, PartialOrd)]
pub struct Ratio(f64);

impl Ratio {
    pub const ZERO: Self = Self(0.0);
    pub const ONE: Self = Self(1.0);

    pub fn new(value: f64) -> Self {
        if value.is_nan() {
            Self::ZERO
        } else {
            Self(value.clamp(0.0, 1.0))
        }
    }

    pub const fn get(self) -> f64 {
        self.0
    }

    pub fn as_f32(self) -> f32 {
        self.0 as f32
    }

    pub fn percent(self) -> Percent {
        Percent::new(self.0 * 100.0)
    }
}

/// A percentage. Unlike [`Ratio`] this may exceed 100 — per-process CPU usage
/// is reported relative to one core, so a process using four cores is 400%.
#[derive(Debug, Clone, Copy, Default, PartialEq, PartialOrd)]
pub struct Percent(f64);

impl Percent {
    pub const ZERO: Self = Self(0.0);

    pub fn new(value: f64) -> Self {
        if value.is_nan() || value < 0.0 {
            Self::ZERO
        } else {
            Self(value)
        }
    }

    pub const fn get(self) -> f64 {
        self.0
    }

    /// Converts to a ratio relative to `full_scale` percent (e.g. `100 * cores`).
    pub fn ratio_of(self, full_scale: f64) -> Ratio {
        if full_scale <= 0.0 {
            Ratio::ZERO
        } else {
            Ratio::new(self.0 / full_scale)
        }
    }
}

impl fmt::Display for Percent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0 >= 10.0 {
            write!(f, "{:.0}%", self.0)
        } else {
            write!(f, "{:.1}%", self.0)
        }
    }
}

/// An event count per second, derived from two cumulative counter samples.
#[derive(Debug, Clone, Copy, Default, PartialEq, PartialOrd)]
pub struct Rate(f64);

impl Rate {
    pub const ZERO: Self = Self(0.0);

    /// Rate between two readings of a monotonically increasing counter.
    /// Counter resets (e.g. PID reuse) yield zero rather than a bogus spike.
    pub fn between(previous: u64, current: u64, elapsed: Duration) -> Self {
        let secs = elapsed.as_secs_f64();
        if secs <= 0.0 || current < previous {
            return Self::ZERO;
        }
        Self((current - previous) as f64 / secs)
    }

    pub const fn per_sec(self) -> f64 {
        self.0
    }
}

impl Add for Rate {
    type Output = Self;
    fn add(self, rhs: Self) -> Self {
        Self(self.0 + rhs.0)
    }
}

impl fmt::Display for Rate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let v = self.0;
        if v >= 1_000_000.0 {
            write!(f, "{:.1}M/s", v / 1_000_000.0)
        } else if v >= 1_000.0 {
            write!(f, "{:.1}k/s", v / 1_000.0)
        } else {
            write!(f, "{v:.0}/s")
        }
    }
}

/// Bytes transferred per second.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct Throughput(pub Bytes);

impl fmt::Display for Throughput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}/s", self.0.binary())
    }
}

/// Process identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Pid(pub u32);

impl fmt::Display for Pid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// Kernel thread identifier (system-wide unique on macOS).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ThreadId(pub u64);

impl fmt::Display for ThreadId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:#x}", self.0)
    }
}

/// Formats a duration compactly, e.g. `3d 4h`, `12m 5s`.
pub fn compact_duration(d: Duration) -> String {
    let s = d.as_secs();
    let (days, hours, mins, secs) = (s / 86_400, (s / 3600) % 24, (s / 60) % 60, s % 60);
    match (days, hours, mins) {
        (0, 0, 0) => format!("{secs}s"),
        (0, 0, _) => format!("{mins}m {secs}s"),
        (0, _, _) => format!("{hours}h {mins}m"),
        _ => format!("{days}d {hours}h"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_format_binary_and_decimal() {
        assert_eq!(Bytes(512).binary().to_string(), "512 B");
        assert_eq!(Bytes(1536).binary().to_string(), "1.50 KB");
        assert_eq!(Bytes(16 * 1024 * 1024 * 1024).binary().to_string(), "16.0 GB");
        assert_eq!(Bytes(500_000_000_000).decimal().to_string(), "500 GB");
    }

    #[test]
    fn ratio_is_clamped() {
        assert_eq!(Ratio::new(1.5).get(), 1.0);
        assert_eq!(Ratio::new(-1.0).get(), 0.0);
        assert_eq!(Ratio::new(f64::NAN).get(), 0.0);
        assert_eq!(Bytes(5).ratio_of(Bytes::ZERO), Ratio::ZERO);
    }

    #[test]
    fn rate_ignores_counter_reset() {
        let one_sec = Duration::from_secs(1);
        assert_eq!(Rate::between(10, 5, one_sec), Rate::ZERO);
        assert_eq!(Rate::between(10, 110, one_sec).per_sec(), 100.0);
        assert_eq!(Rate::between(0, 1, Duration::ZERO), Rate::ZERO);
    }

    #[test]
    fn durations_are_compact() {
        assert_eq!(compact_duration(Duration::from_secs(42)), "42s");
        assert_eq!(compact_duration(Duration::from_secs(3 * 3600 + 120)), "3h 2m");
        assert_eq!(compact_duration(Duration::from_secs(90_000)), "1d 1h");
    }
}
