#!/usr/bin/env python3
#
# import-map.py — Sean Stoves (Solao), 2026-08-04
#
# The whole user-facing side of the map import: pick your MUSHclient
# Aardwolf.db, convert it, stage it where MudForge can reach it, and clear it
# out again afterwards. macOS, Windows and Linux.
#
# This has to live outside the client, and not for want of trying. A MudForge
# plugin cannot read a file it didn't write — loadPluginFile returns nil for any
# path outside its own storage, readFile and loadFile don't exist — and the
# storage it CAN read is IndexedDB inside the app, which nothing outside can
# write to. There is no arrangement where the panel opens your database itself.
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


def app_dirs():
    """Where MudForge keeps its libs, per platform.

    Tauri puts app data under the bundle identifier: Application Support on
    macOS, Roaming on Windows, and either .config or .local/share on Linux
    depending on how the app was built. Both Linux spellings are checked
    rather than guessed at.
    """
    home = os.path.expanduser("~")
    ident = "com.mudforge.app"
    system = platform.system()

    if system == "Darwin":
        return [os.path.join(home, "Library", "Application Support", ident)]

    if system == "Windows":
        roaming = os.environ.get("APPDATA") or os.path.join(home, "AppData", "Roaming")
        local = os.environ.get("LOCALAPPDATA") or os.path.join(home, "AppData", "Local")
        return [os.path.join(roaming, ident), os.path.join(local, ident)]

    return [os.path.join(home, ".config", ident),
            os.path.join(home, ".local", "share", ident)]


def find_lib_dir():
    for base in app_dirs():
        lib = os.path.join(base, "libs")
        if os.path.isdir(lib):
            return lib

    # the app exists but has never created libs/, which is normal on a fresh
    # install — make it rather than telling someone to
    for base in app_dirs():
        if os.path.isdir(base):
            lib = os.path.join(base, "libs")
            os.makedirs(lib, exist_ok=True)
            return lib

    return None


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

    lib = find_lib_dir()
    if not lib:
        print("  MudForge doesn't appear to be installed — none of these exist:")
        for base in app_dirs():
            print("    " + base)
        return 1

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

    rc = subprocess.call([sys.executable,
                          os.path.join(HERE, "import-mushmap.py"), db, work])
    if rc != 0:
        print("\n  Conversion failed.")
        return rc

    ###
    # Staged, not installed. 74 files and 5.5MB of Lua left in a folder the
    # client parses at startup is what wedged MudForge at 0% CPU with plugins
    # never finishing loading — so they go in for the import and come straight
    # back out.
    ###
    import glob
    import shutil

    chunks = sorted(glob.glob(os.path.join(work, "awmap-*.lua")))
    if not chunks:
        print("\n  Converted, but produced no output. Nothing staged.")
        return 1

    for c in chunks:
        shutil.copy2(c, lib)

    print(f"\n  Staged {len(chunks)} file(s) into {lib}")
    print("""
  ------------------------------------------------------------------
  Now, in MudForge:

    1. Quit and reopen MudForge, so it picks up the staged files
    2. Type  /awcore  to open Aardwolf Core
    3. Under MAP IMPORT, press IMPORT MAP
    4. Watch the bars — a few seconds, and you can keep playing

  Come back here when it says complete, and press return.
  ------------------------------------------------------------------
""")

    try:
        input()
    except EOFError:
        pass

    for c in glob.glob(os.path.join(lib, "awmap-*.lua")):
        os.remove(c)

    shutil.rmtree(work, ignore_errors=True)

    print("  Cleaned up. Restart MudForge once more and your map is in.\n")
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
