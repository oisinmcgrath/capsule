#!/bin/bash
# @tagdex: ancillary, script, start
# Double-click launcher target. Opens via the .desktop file (Terminal=true),
# runs the wizard, then pauses so the terminal doesn't close on you.
cd "$(dirname "$(readlink -f "$0")")" || { echo "wizard repo not found"; read -r; exit 1; }
bash wizard.sh
echo
read -rp "Wizard finished. Press Enter to close this window."
