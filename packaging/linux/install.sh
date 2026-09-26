#!/usr/bin/env sh
# Installs Procmon from an extracted release tarball.
# Usage: ./install.sh            (installs into ~/.local)
#        PREFIX=/usr/local sudo -E ./install.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix="${PREFIX:-$HOME/.local}"

install -Dm755 "$here/bin/procmon" "$prefix/bin/procmon"
install -Dm644 "$here/share/applications/procmon.desktop" "$prefix/share/applications/procmon.desktop"
install -Dm644 "$here/share/icons/hicolor/512x512/apps/procmon.png" \
  "$prefix/share/icons/hicolor/512x512/apps/procmon.png"

command -v update-desktop-database > /dev/null && update-desktop-database "$prefix/share/applications" || true

echo "Procmon installed to $prefix/bin/procmon"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "Note: $prefix/bin is not on your PATH" ;;
esac
