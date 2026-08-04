#!/usr/bin/env bash
# Linux launcher. Most desktops will run this on double-click if it's marked
# executable; otherwise run it from a terminal.
#
# The file dialog needs tkinter, which most distributions package separately:
#   Debian/Ubuntu   sudo apt install python3-tk
#   Fedora          sudo dnf install python3-tkinter
#   Arch            sudo pacman -S tk
# Without it you get asked to paste the path instead, which works fine.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

command -v python3 >/dev/null 2>&1 || {
    echo "python3 isn't installed."
    exit 1
}

exec python3 import-map.py
