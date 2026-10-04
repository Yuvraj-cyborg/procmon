#!/usr/bin/env bash
# Builds the smallest release binary we know how to make.
#
# With rustup available it uses a pinned nightly to rebuild the standard
# library for size: panics abort immediately (no formatting machinery),
# panic location strings are dropped, and std's size-optimised code paths
# are enabled. On Linux the unwind tables are left out too. That saves
# ~1.2 MB over the stable size profile, and more on Linux. Without
# rustup (e.g. inside `nix develop`) it falls back to the stable profile.
#
# Environment:
#   TARGET   Rust target triple (default: host)
#   NIGHTLY  toolchain for size builds (default below); set STABLE=1 to skip it
#
# Output: target/<TARGET>/release/procmon (procmon.exe on Windows)
set -euo pipefail
cd "$(dirname "$0")/.."

target="${TARGET:-$(rustc -vV | sed -n 's/^host: //p')}"
nightly="${NIGHTLY:-nightly-2026-09-25}"

if [[ -z "${STABLE:-}" ]] && command -v rustup > /dev/null; then
  rustup toolchain install "$nightly" --profile minimal --component rust-src --target "$target" > /dev/null
  flags=(-Zunstable-options -Cpanic=immediate-abort -Zlocation-detail=none)
  # Panics abort at once, so nothing ever unwinds: leave the unwind tables
  # out. They were 2.1 MB of the 18 MB Linux binary. Linux only: Windows
  # needs its tables, and the macOS app is the Swift one.
  [[ "$target" == *-linux-* ]] && flags+=(-Cforce-unwind-tables=no)
  RUSTFLAGS="${flags[*]} ${RUSTFLAGS:-}" cargo "+$nightly" build --release --locked \
    --target "$target" -Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size
else
  echo "building with the stable size profile (no rustup or STABLE=1)" >&2
  cargo build --release --locked --target "$target"
fi

binary="target/$target/release/procmon"
[[ -f "$binary.exe" ]] && binary="$binary.exe"
echo "built $binary ($(du -h "$binary" | cut -f1))"
