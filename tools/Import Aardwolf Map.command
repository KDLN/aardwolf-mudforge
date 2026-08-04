#!/usr/bin/env bash
# macOS launcher — double-click in Finder. The work is in import-map.py, which
# is the same on every platform; this only finds a python3 and keeps the
# Terminal window open long enough to read.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

if command -v python3 >/dev/null 2>&1; then
    exec python3 import-map.py
fi

echo
echo "  python3 isn't installed."
echo "  Run:  xcode-select --install"
echo
read -r -p "  Press return to close."
