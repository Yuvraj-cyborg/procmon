# Procmon

A small system monitor for your computer.

<p align="center"><img src="docs/image.png" alt="Procmon"></p>

## What it shows

- **Overview:** everything below, on one screen.
- **Memory:** how much RAM is in use, and which apps are using it. Apps that sit idle while holding a lot of memory are marked, with a button to quit them.
- **Activity:** CPU use, and any process that is stuck, spinning, or eating the CPU, with a button to fix it.
- **Process details:** click any process to quit, force quit or pause it, and to see every thread. Blocked threads come first. Read stacks shows what each thread is waiting on.
- **Graphics:** how busy the GPU is, and which apps are using it. A short benchmark measures the GPU in real units, trillions of operations per second and gigabytes per second. Run it for a minute to see whether the GPU slows down as it heats up.
- **Storage:** what is filling your disk, shown as boxes you can click into. Old caches, logs and temporary files can be reviewed and deleted from here.
- **Recovery:** brings back deleted photos, videos, music and documents from memory cards, USB drives and external disks. Files deleted from FAT and exFAT drives come back with their names and folders. Procmon also searches the whole disk for files by their contents, so it finds them even after a card was formatted. You can preview each file before saving it to another disk. Nothing on the disk being recovered is changed.
- **Devices:** connected hardware, and whether its drivers are running.

## Install

Download it from [proc.yuvich.com](https://proc.yuvich.com).

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

## Good to know

- Some processes belong to the system. Run Procmon with `sudo` to see their full details.
- macOS guards folders like Desktop, Documents and Downloads one by one. Procmon asks once for Full Disk Access instead. If you say no, those folders are left out of scans, and macOS never asks again.
- macOS does not let one app stop another app's threads. To free a stuck thread, quit or force quit its process.
- Recovery reads disks block by block, so it needs an administrator's permission. macOS and Linux ask for a password (on Linux through UDisks2, or run Procmon with `sudo`). On Windows, click **Restart as Administrator** on the Recovery page. Procmon only reads the disk; it never writes to it.
- Recover files as soon as you can, and don't save anything new to that disk until then. New files can take the space deleted ones used.
- Files deleted from a Mac's built-in SSD rarely come back: the SSD erases freed space within minutes, and its contents are encrypted. Look in Time Machine or iCloud instead.
- On Linux and Windows, Recovery previews photos (JPEG, PNG, GIF, BMP, TIFF, WebP); other files are recovered without a preview. The GPU benchmark uses Vulkan on Linux and Direct3D 11 on Windows.
- Thread states, memory pressure and the Devices page are macOS only for now.
