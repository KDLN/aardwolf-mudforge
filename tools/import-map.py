#!/usr/bin/env python3
#
# import-map.py — Sean Stoves (Solao), 2026-08-04
#
# Pick your MUSHclient Aardwolf.db and get a file MudForge's own map importer
# takes. macOS, Windows and Linux.
#
# It writes MudForge's export format, worked out from a real export rather than
# guessed: rooms carry their exits inline, special exits sit in the same object
# keyed by the command, and every room needs lastVisited and timesVisited or the
# renderer won't draw it. maxRooms ships at 10,000 against a 22,946 room map, so
# it gets raised to fit.
#
#   python3 tools/import-map.py [path/to/Aardwolf.db]
#
# or double-click one of the launchers beside it.

import os
import platform
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def likely_databases():
    """Where an Aardwolf.db tends to be, per platform."""
    home = os.path.expanduser("~")
    out = []

    if platform.system() == "Darwin":
        out.append(os.path.join(
            home, "Library/Application Support/CrossOver/Bottles/Mushclient/"
            "drive_c/users/crossover/Desktop/MUSHclient/Aardwolf.db"))

    if platform.system() == "Windows":
        for base in ("C:\\MUSHclient", os.path.join(home, "MUSHclient"),
                     os.path.join(home, "Documents", "MUSHclient"),
                     "C:\\Program Files (x86)\\MUSHclient",
                     "C:\\Program Files\\MUSHclient"):
            out.append(os.path.join(base, "Aardwolf.db"))

    # WINE, and the plain case of it sitting next to this script
    out.append(os.path.join(home, ".wine/drive_c/MUSHclient/Aardwolf.db"))
    out.append(os.path.join(home, "MUSHclient", "Aardwolf.db"))
    out.append(os.path.join(home, "Aardwolf.db"))

    return [p for p in out if os.path.isfile(p)]


def pick_file(start):
    """A native picker where there is one, typing where there isn't.

    tkinter ships with Python on Windows and macOS but is a separate package on
    most Linux distributions, so its absence is normal and not an error worth
    stopping for.
    """
    try:
        import tkinter
        from tkinter import filedialog

        root = tkinter.Tk()
        root.withdraw()
        root.update()

        path = filedialog.askopenfilename(
            title="Select your MUSHclient Aardwolf.db",
            initialdir=start or os.path.expanduser("~"),
            filetypes=[("MUSHclient mapper database", "*.db"), ("All files", "*.*")])

        root.destroy()
        return path or None

    except Exception:
        print("\n  No file dialog available on this system.")
        print("  Paste the full path to your Aardwolf.db and press return.\n")
        try:
            typed = input("  > ").strip().strip('"').strip("'")
        except EOFError:
            return None
        return typed or None


def newest_export():
    """The most recent map export MudForge has written, if there is one.

    Its settings get carried into the generated file, so zoom, node mode and
    terrain colours survive the import rather than reverting to defaults. The
    client names them map-data-<date>.json and they land wherever the browser
    puts downloads.
    """
    home = os.path.expanduser("~")
    found = []

    for folder in ("Downloads", "Desktop", "Documents", ""):
        base = os.path.join(home, folder) if folder else home
        if not os.path.isdir(base):
            continue
        try:
            for name in os.listdir(base):
                if name.startswith("map-data") and name.endswith(".json"):
                    full = os.path.join(base, name)
                    found.append((os.path.getmtime(full), full))
        except OSError:
            continue

    if not found:
        return None

    found.sort()
    return found[-1][1]


def is_sqlite(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(15) == b"SQLite format 3"[:15]
    except OSError:
        return False


def main():
    print()
    print("  Aardwolf map import")
    print("  Converts a MUSHclient mapper database into something MudForge can read.")
    print("  Your MUSHclient files are opened read-only and never modified.")
    print()

    db = sys.argv[1] if len(sys.argv) > 1 else None

    if not db:
        found = likely_databases()
        start = os.path.dirname(found[0]) if found else None

        if found:
            print("  Found a database at:")
            print("    " + found[0])
            try:
                answer = input("\n  Use this one? [Y/n] ").strip().lower()
            except EOFError:
                answer = "y"
            if answer in ("", "y", "yes"):
                db = found[0]

        if not db:
            db = pick_file(start)

    if not db:
        print("\n  Nothing selected.")
        return 1

    db = os.path.expanduser(db)

    if not os.path.isfile(db):
        print(f"\n  Can't read {db}")
        return 1

    # a wrong pick is much easier to explain here than as a traceback later
    if not is_sqlite(db):
        print(f"\n  {os.path.basename(db)} isn't a SQLite database.")
        return 1

    size = os.path.getsize(db) // 1024
    print(f"\n  Reading {os.path.basename(db)} ({size} KB)")
    print("  Converting, this takes a few seconds...\n")

    # somewhere temporary, never inside a checkout: see the note in
    # import-mushmap.py about 5.5MB of personal map reaching a public repo
    import tempfile
    work = tempfile.mkdtemp(prefix="awmap-")

    cmd = [sys.executable, os.path.join(HERE, "import-mushmap.py"), db, work]

    export = newest_export()
    if export:
        print(f"  Keeping your map settings from {os.path.basename(export)}")
        cmd.append(export)

    rc = subprocess.call(cmd)
    if rc != 0:
        print("\n  Conversion failed.")
        return rc

    ###
    # One file, and MudForge's own importer takes it.
    #
    # The earlier route staged 74 Lua chunks into the client's libs folder and
    # had a plugin write all 22,946 rooms one API call at a time. That meant
    # reverse-engineering each writer — addSpecialExit wants the command in the
    # MIDDLE, updateMapRoom replaces the record instead of merging, rooms need
    # lastVisited and timesVisited or the renderer won't draw them — and 5.5MB
    # of Lua in a folder the client parses at startup wedged it more than once.
    #
    # Its export format does all of that correctly by construction.
    ###
    import glob
    import shutil

    src = os.path.join(work, "aardwolf-map.json")
    if not os.path.isfile(src):
        print("\n  Converted, but produced no map file.")
        return 1

    desktop = os.path.join(os.path.expanduser("~"), "Desktop")
    dest_dir = desktop if os.path.isdir(desktop) else os.path.expanduser("~")
    dest = os.path.join(dest_dir, "aardwolf-map.json")

    shutil.copy2(src, dest)
    shutil.rmtree(work, ignore_errors=True)

    size = os.path.getsize(dest) // 1024
    print(f"\n  Wrote {dest}  ({size} KB)")
    print("""
  ------------------------------------------------------------------
  Now, in MudForge:

    1. Open the map panel and its  ...  menu
    2. Choose  Import Map Data
    3. Pick  aardwolf-map.json  from your Desktop
    4. Restart MudForge

  The map view is built when the client starts, so it won't show the
  new rooms until that last step.
  ------------------------------------------------------------------
""")
    return 0
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except KeyboardInterrupt:
        code = 1

    # double-clicked windows close the instant the script ends, taking every
    # message with them
    if sys.stdout.isatty():
        try:
            input("  Press return to close.")
        except EOFError:
            pass

    sys.exit(code)
