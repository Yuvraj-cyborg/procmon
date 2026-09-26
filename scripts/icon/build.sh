#!/usr/bin/env bash
# Regenerates the app icon: SVG (from the JS generator) -> optimised PNGs -> .icns.
# Needs node, resvg, pngquant and oxipng (all provided by `nix develop`).
set -euo pipefail

cd "$(dirname "$0")/../.."
out=assets/icon
mkdir -p "$out"

node scripts/icon/generate.mjs > "$out/procmon.svg"

pngs=$(mktemp -d)
trap 'rm -rf "$pngs"' EXIT

# Palette quantisation cuts the PNGs by ~70% with no visible difference.
for size in 16 32 64 128 256 512 1024; do
  png="$pngs/$size.png"
  resvg --width "$size" --height "$size" "$out/procmon.svg" "$png"
  pngquant --quality 75-95 --speed 1 --strip --force --output "$png" "$png"
  oxipng --quiet --opt max "$png"
done

cp "$pngs/512.png" "$out/procmon-512.png"
node scripts/icon/icns.mjs "$pngs" "$out/Procmon.icns"

echo "icon written to $out"
