//! Per-process network traffic.
//!
//! macOS only exposes per-process socket statistics through the private
//! NetworkStatistics framework, whose supported front-end is `nettop`. We run
//! it in one-shot CSV mode and difference the cumulative totals.

use std::collections::HashMap;
use std::time::Instant;

use crate::units::{Bytes, Pid, Rate, Throughput};

/// Network activity of one process, per second.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct NetworkRates {
    pub received: Throughput,
    pub sent: Throughput,
    pub packets: Rate,
}

/// Cumulative counters for one process, as reported by `nettop`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NetworkTotals {
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub packets_in: u64,
    pub packets_out: u64,
}

#[derive(Default)]
pub struct NetworkProbe {
    previous: HashMap<Pid, NetworkTotals>,
    previous_at: Option<Instant>,
}

impl NetworkProbe {
    /// Returns rates since the last call; empty on the first call or when
    /// `nettop` is unavailable.
    pub fn sample(&mut self, now: Instant) -> HashMap<Pid, NetworkRates> {
        let Some(totals) = read_totals() else {
            return HashMap::new();
        };
        let rates = match self.previous_at {
            Some(before) => {
                let elapsed = now.duration_since(before);
                totals
                    .iter()
                    .filter_map(|(pid, now)| {
                        let prev = self.previous.get(pid)?;
                        let bytes = |p: u64, c: u64| {
                            Throughput(Bytes(Rate::between(p, c, elapsed).per_sec() as u64))
                        };
                        Some((
                            *pid,
                            NetworkRates {
                                received: bytes(prev.bytes_in, now.bytes_in),
                                sent: bytes(prev.bytes_out, now.bytes_out),
                                packets: Rate::between(
                                    prev.packets_in + prev.packets_out,
                                    now.packets_in + now.packets_out,
                                    elapsed,
                                ),
                            },
                        ))
                    })
                    .collect()
            }
            None => HashMap::new(),
        };
        self.previous = totals;
        self.previous_at = Some(now);
        rates
    }
}

#[cfg(target_os = "macos")]
fn read_totals() -> Option<HashMap<Pid, NetworkTotals>> {
    let output = std::process::Command::new("/usr/bin/nettop")
        .args(["-P", "-L", "1", "-x", "-n"])
        .args(["-J", "bytes_in,bytes_out,packets_in,packets_out"])
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| parse_nettop_csv(&String::from_utf8_lossy(&output.stdout)))
}

#[cfg(not(target_os = "macos"))]
fn read_totals() -> Option<HashMap<Pid, NetworkTotals>> {
    None
}

/// Parses `nettop -P -L 1 -x` CSV. Columns are located by header name because
/// `nettop` documents that their order may change.
fn parse_nettop_csv(csv: &str) -> HashMap<Pid, NetworkTotals> {
    let mut lines = csv.lines();
    let Some(header) = lines.next() else {
        return HashMap::new();
    };
    let columns: Vec<&str> = header.split(',').collect();
    let index = |name: &str| columns.iter().position(|c| *c == name);
    let (Some(bytes_in), Some(bytes_out)) = (index("bytes_in"), index("bytes_out")) else {
        return HashMap::new();
    };
    let (packets_in, packets_out) = (index("packets_in"), index("packets_out"));
    let width = columns.len();

    let mut totals = HashMap::new();
    for line in lines {
        // The process label (`name.pid`) may itself contain commas, so split
        // the fixed numeric columns off the right-hand side.
        let fields: Vec<&str> = line.rsplitn(width, ',').collect::<Vec<_>>();
        if fields.len() != width {
            continue;
        }
        let field = |ix: usize| fields[width - 1 - ix];
        let Some(pid) = field(0)
            .rsplit_once('.')
            .and_then(|(_, pid)| pid.parse().ok())
            .map(Pid)
        else {
            continue;
        };
        let number =
            |ix: Option<usize>| ix.and_then(|ix| field(ix).parse::<u64>().ok()).unwrap_or(0);
        let entry: &mut NetworkTotals = totals.entry(pid).or_default();
        entry.bytes_in += number(Some(bytes_in));
        entry.bytes_out += number(Some(bytes_out));
        entry.packets_in += number(packets_in);
        entry.packets_out += number(packets_out);
    }
    totals
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = ",packets_in,bytes_in,packets_out,bytes_out,\n\
        launchd.1,0,0,0,0,\n\
        apsd.578,312,170253,291,163396,\n\
        Weird, Name.v2.4242,1,10,2,20,\n";

    #[test]
    fn parses_by_header_and_handles_commas_in_names() {
        let totals = parse_nettop_csv(SAMPLE);
        assert_eq!(
            totals[&Pid(578)],
            NetworkTotals {
                bytes_in: 170_253,
                bytes_out: 163_396,
                packets_in: 312,
                packets_out: 291,
            }
        );
        assert_eq!(totals[&Pid(4242)].bytes_out, 20);
        assert_eq!(totals.len(), 3);
    }

    #[test]
    fn missing_byte_columns_yield_nothing() {
        assert!(parse_nettop_csv(",state,\nfoo.1,up,\n").is_empty());
        assert!(parse_nettop_csv("").is_empty());
    }
}
