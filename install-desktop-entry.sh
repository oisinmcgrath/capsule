#!/bin/bash
# @tagdex: ancillary, script, start, config
# ============================================================================
# install-desktop-entry.sh — put "Capsule" in the app menu.
#
# Idempotent + path-independent: it derives the wizard's location from its own
# path and writes a .desktop entry whose Exec runs wizard-launch.sh IN PLACE.
# So the menu item always runs the CURRENT scripts — edit the repo or git pull
# and the next launch reflects it, with no reinstall. If you MOVE the repo,
# just run this script again and the path is regenerated.
#
# User-level install (no sudo). Run:  bash install-desktop-entry.sh
#   --uninstall   remove the menu entry
# ============================================================================
set -euo pipefail

WIZ_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DEST="$APPS/capsule.desktop"

refresh() {
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" >/dev/null 2>&1 || true
  command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$DEST"; refresh
  echo "Removed menu entry: $DEST"
  exit 0
fi

mkdir -p "$APPS"
chmod +x "$WIZ_DIR/wizard-launch.sh" "$WIZ_DIR/wizard.sh"

cat > "$DEST" <<EOF
[Desktop Entry]
Type=Application
Name=Capsule
GenericName=Sandboxed repo installer
Comment=Scaffold a DevPod + Podman + VSCodium sandbox pre-wired for autonomous agent work
Exec=$WIZ_DIR/wizard-launch.sh
Path=$WIZ_DIR
Icon=applications-development
Terminal=true
Categories=Development;
Keywords=devpod;podman;vscodium;container;sandbox;wizard;agent;
StartupNotify=false
EOF

command -v desktop-file-validate >/dev/null 2>&1 && desktop-file-validate "$DEST"
refresh
echo "Installed menu entry -> $DEST"
echo "  Exec: $WIZ_DIR/wizard-launch.sh  (runs the live wizard.sh; updates need no reinstall)"
