# Procmon

A small system monitor. On macOS it is a native Swift app of under 2 MB. On Linux and Windows it is written in Rust with [GPUI](https://github.com/zed-industries/zed).

<p align="center"><img src="docs/image.png" alt="Procmon"></p>

## What it shows

- **Overview:** everything below, on one screen.
- **Memory:** how much RAM is in use, and which apps are using it. Apps that sit idle while holding a lot of memory are marked, with a button to quit them.
- **Activity:** CPU use, and any process that is stuck, spinning, or eating the CPU, with a button to fix it.
- **Process details:** click any process to quit, force quit or pause it, and to see every thread. Blocked threads come first. Read stacks shows what each thread is waiting on.
- **Storage:** what is filling your disk, shown as boxes you can click into. Old caches, logs and temporary files can be reviewed and deleted from here.
- **Devices:** connected hardware, and whether its drivers are running.

Simple rules, not AI, decide what is safe to clean, and Procmon always asks first.

## Install

Get the latest version from [Releases](https://github.com/Yuvraj-cyborg/procmon/releases).

- **macOS 15 or later:** open the `.dmg` and drag Procmon into Applications.
- **Linux:** unpack the `.tar.xz` and run `./install.sh`, or install the `.deb`.
- **Windows:** unzip it and run `procmon.exe`.

## Build

The macOS app is in `macos/` and needs Xcode 26. The Linux and Windows app is the Rust code in the main folder. If you use [Nix](https://nixos.org), run `nix develop` first to get the exact Rust tools.

```sh
make run       # start a debug build
make test      # run the tests
make install   # macOS: build Procmon.app and copy it to /Applications
make dmg       # macOS: build a .dmg in dist/
make linux     # Linux: build a .tar.xz in dist/
```

## Shortcuts on macOS

| Keys | Action |
| --- | --- |
| ⌘1 – ⌘5 | Switch page |
| ⌘F | Search processes |
| ⌘R | Rescan or refresh |

## Good to know

- Some processes belong to the system. Run Procmon with `sudo` to see their full details.
- macOS guards folders like Desktop, Documents and Downloads one by one. Procmon asks once for Full Disk Access instead. If you say no, those folders are left out of scans, and macOS never asks again.
- macOS does not let one app stop another app's threads. To free a stuck thread, quit or force quit its process.
- On Linux and Windows, memory, CPU, processes and disk scans work. The rest is macOS only for now.
