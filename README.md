# Procmon

A small system monitor for macOS, written in Rust with [GPUI](https://github.com/zed-industries/zed). The download is about 3 MB.

<p align="center"><img src="docs/image.png" alt="Procmon"></p>

## What it shows

- **Memory:** how much RAM is in use, and which apps are using it.
- **Activity:** CPU use, and any process that is stuck, spinning, or sending too many requests.
- **Storage:** what is filling your disk, shown as boxes you can click into.
- **Devices:** connected hardware, and whether its drivers are running.

## Install

Get the latest version from [Releases](https://github.com/Yuvraj-cyborg/procmon/releases).

- **macOS:** open the `.dmg` and drag Procmon into Applications.
- **Linux:** unpack the `.tar.gz` and run `./install.sh`, or install the `.deb`.

## Build

You need Rust. If you use [Nix](https://nixos.org), run `nix develop` first to get the exact tools.

```sh
make run       # start a debug build
make install   # build Procmon.app and copy it to /Applications
make dmg       # build a .dmg in dist/
```

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌘1 – ⌘4 | Switch page |
| ⌘F | Search processes |
| ⌘R | Rescan or refresh |
| ⌘\\ | Show or hide the sidebar |

## Good to know

- Some processes belong to the system. Run Procmon with `sudo` to see their full details.
- Folders like Mail and Messages are skipped during a scan unless Procmon has Full Disk Access.
- On Linux, memory, CPU, processes and disk scans work. The rest is macOS only for now.
