# Procmon

A small, native system monitor for macOS, built in Rust with [GPUI](https://github.com/zed-industries/zed) (Zed's GPU UI framework) and [GPUI Kit](https://gpui-kit.com) components.

It answers four questions quickly:

- **Memory:** where is my RAM going, and which apps are holding it?
- **Activity:** is anything stuck, spinning, or hammering the kernel or network?
- **Storage:** what is taking up space on disk? (Disk Drill-style boxes you can click into.)
- **Devices:** what hardware is connected, and are its drivers actually running?

<p align="center"><img src="docs/memory.png" width="420" alt="Memory page"> <img src="docs/activity.png" width="420" alt="Activity page"></p>
<p align="center"><img src="docs/storage.png" width="420" alt="Storage page"> <img src="docs/process-detail.png" width="420" alt="Process detail sheet"></p>

## Features

### Memory
- Activity Monitor–style breakdown of physical memory: app, wired, compressed and cached files, plus swap and the kernel's memory-pressure level.
- Usage history for the last two minutes.
- "Who is using memory": per-app totals (helper processes roll up into the `.app` that owns them) or per-process rows, sortable and searchable.

### Activity
- Total and per-core CPU load, load averages and history.
- **Needs attention** flags, without false alarms from a single unlucky sample:
  - **Blocked** threads stuck in an uninterruptible kernel wait for 3 s or more.
  - **Stopped** threads (suspended by a debugger or `SIGSTOP`).
  - **Spinning** threads pegging a core for 10 s or more.
  - Processes **flooding the kernel or network**: syscall storms, context-switch thrash, IPC floods, frequent wakeups, page-fault storms, packet floods.
- Per-process syscalls/s, context switches/s, wakeups/s, disk and network throughput.
- Double-click a process (or right-click → Inspect) for a detail sheet with every thread's live run state, the executable path, and **Quit** / **Force Quit** (with confirmation).

### Storage
- Volumes with usage meters.
- Fast parallel scan of any folder, drawn as a **squarified treemap**. Big folders show their contents as nested boxes, so you can see what is inside before clicking in. Colours follow file type.
- Breadcrumbs, up, rescan, and hover for size and file count.
- **Largest files** view across the whole scan.
- Reveal in Finder and **Move to Trash** (via Finder's Trash, so items can be put back).

### Devices
- USB, Thunderbolt/USB4, Bluetooth (connected and paired), displays and GPU, audio, cameras, network interfaces and physical drives with SMART status.
- Loaded kernel extensions, system extensions and DriverKit drivers with their state. Drivers waiting for approval in System Settings, faulty devices and failing drives are surfaced under **Needs attention**.

### App
- Light and dark themes (warm, Notion-like neutrals with a soft indigo accent) that follow the system or can be picked from the sidebar.
- Scales with the window: layouts wrap, and the sidebar collapses to icons below 900 px.
- Settings (theme, group-by-app) persist in `~/Library/Application Support/Procmon/settings.json`.

## Build and run

Requirements: macOS with the Xcode command-line tools, and a recent stable Rust toolchain (edition 2024).

```sh
cargo run --release
```

### Command-line options

```text
procmon [OPTIONS]
  --page <name>    Open on a page: memory, activity, storage or devices
  --scan <path>    Open Storage and start scanning <path>
  --inspect <pid>  Open the detail sheet for a process
  -h, --help       Print help
```

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘1 – ⌘4 | Memory, Activity, Storage, Devices |
| ⌘F | Focus the process filter |
| ⌘R | Rescan storage / refresh devices |
| ⌘\\ | Toggle the sidebar |
| ⌘W / ⌘Q | Close / quit |

## Permissions

- **Root-owned processes** can't be inspected by a normal user. Their thread states and kernel counters are hidden, and the Activity page shows how many were skipped. Run with `sudo` to include them.
- **Protected folders** (Mail, Messages, parts of `~/Library`, …) are skipped during scans unless Procmon (or the terminal that launched it) has **Full Disk Access**. The Storage page reports how many folders were skipped.
- Quit/Force Quit only work on processes you own (or anything, under `sudo`). Procmon refuses to signal PID 0/1 or itself.

## How it works

| What | Source |
| --- | --- |
| Memory breakdown | `host_statistics64` (`vm_statistics64`): app = internal − purgeable pages |
| Memory pressure | `kern.memorystatus_vm_pressure_level` |
| Per-process memory | `proc_pid_rusage` physical footprint (what Activity Monitor shows), falling back to RSS |
| Thread states | `proc_pidinfo(PROC_PIDTHREADINFO)` run state and CPU usage |
| Kernel activity | Deltas of `proc_pidinfo(PROC_PIDTASKALLINFO)` syscall, context-switch, Mach message and fault counters, plus idle wakeups from rusage |
| Network per process | `nettop` one-shot CSV, parsed by column name |
| CPU, processes, disks | [`sysinfo`](https://crates.io/crates/sysinfo) |
| Devices | `system_profiler -json`, `kmutil showloaded`, `systemextensionsctl list` |
| Disk usage | Parallel scan ([`rayon`](https://crates.io/crates/rayon)) of allocated blocks; stays on one filesystem, skips symlinks, counts hard links once |

Sampling runs off the UI thread once per second; thread states are probed every 2 s and network every 3 s to keep Procmon's own overhead around 2% CPU.

### Layout

```text
src/
  main.rs, app.rs      window, sidebar shell, page routing
  actions.rs, cli.rs   menu bar, shortcuts, command-line options
  settings.rs, theme.rs
  units.rs             strongly-typed Bytes, Ratio, Percent, Rate, Pid, …
  system/              sampler, macOS probes, snapshots, process control
  storage/             scanner, file tree arena, squarified treemap, trash
  devices/             device and driver inventory
  ui/                  pages, tables, detail sheet, widgets
```

## Platform support

Procmon is built for macOS. The code is split so other platforms compile against a fallback, where memory, CPU, process and disk-scan features work through `sysinfo`. Thread states, kernel counters, per-process network, devices and Trash are macOS-only for now, and non-macOS builds are untested.

## Tests

```sh
cargo test
```

Live checks that read the real system are marked `#[ignore]` and can be run explicitly, for example:

```sh
cargo test --release sampler_live -- --ignored --nocapture
SCAN_ROOT=$HOME cargo test --release scan_live -- --ignored --nocapture
```
