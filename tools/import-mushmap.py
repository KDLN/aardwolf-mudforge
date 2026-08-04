#!/usr/bin/env python3
#
# import-mushmap.py — Sean Stoves (Solao), 2026-08-04
#
# Converts the MUSHclient Aardwolf mapper database into Lua chunks the Core
# importer can feed to MudForge's mapper a piece at a time.
#
# The conversion happens HERE, not in the client. A plugin can't open a SQLite
# file — there's no binding for it in the sandbox and no JSON parser either —
# so the only thing that crosses over is Lua source, which require() handles.
#
# Chunked because the whole map is 23k rooms and 76k exits. One module holding
# that would be an enormous literal, and the transpiler has choked on far
# smaller ones. Small files also give the importer somewhere natural to yield.
#
#   ./tools/import-mushmap.py [path/to/Aardwolf.db]
#
# Output lands in libs/ and is gitignored — it's a personal map, not source.

import os
import re
import sqlite3
import sys

DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/CrossOver/Bottles/Mushclient/drive_c/"
    "users/crossover/Desktop/MUSHclient/Aardwolf.db")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#
# Second argument wins. Writing into <root>/libs by default put 5.5MB of one
# person's map inside a git checkout, and 'build.sh release' runs 'git add -A' —
# so it went straight to a public repo. The caller passes somewhere temporary.
#
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "libs")

ROOMS_PER_CHUNK = 750
EXITS_PER_CHUNK = 2000

# what Aardwolf calls a direction, in every spelling the mapper stored
DIRS = {
    "n": "north", "no": "north", "north": "north",
    "s": "south", "so": "south", "south": "south",
    "e": "east",  "ea": "east",  "east": "east",
    "w": "west",  "we": "west",  "west": "west",
    "u": "up",    "up": "up",
    "d": "down",  "dn": "down",  "down": "down",
}

# 'open east;east' — a door, not a special exit. The mapper writes the whole
# sequence into the dir column because MUSHclient splits on ';' when it sends.
DOOR = re.compile(r"^open\s+(\w+)\s*;\s*(\w+)$", re.I)


def lua_str(v):
    s = "" if v is None else str(v)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    s = s.replace("\n", "\\n").replace("\r", "").replace("\t", " ")
    return '"' + s + '"'


def lua_num(v):
    try:
        return str(int(v))
    except (TypeError, ValueError):
        return "nil"


def classify(direction):
    """(kind, direction, command) — 'exit', 'door' or 'special'."""
    d = (direction or "").strip()
    low = d.lower()

    if low in DIRS:
        return "exit", DIRS[low], None

    m = DOOR.match(d)
    if m:
        # the second half is the actual movement; the first is the door name,
        # which on Aardwolf is nearly always the direction again
        target = m.group(2).lower()
        if target in DIRS:
            return "door", DIRS[target], d

    return "special", None, d


# grid deltas. North is up, so it DECREASES y — the mapper draws with y
# growing downward and getting this backwards mirrors every area.
STEP = {
    "north": (0, -1, 0), "south": (0, 1, 0),
    "east":  (1, 0, 0),  "west":  (-1, 0, 0),
    "up":    (0, 0, 1),  "down":  (0, 0, -1),
}


def lay_out(rooms, links):
    """Give every room an (x, y, z).

    MUSHclient stores coordinates for only 8,806 of 22,951 rooms — its mapper
    works the layout out from the exits each time it draws, and never writes
    most of it down. Aylor has 285 rooms and exactly one coordinate pair
    between them, which is why the imported map had nothing to place.

    So walk each area breadth-first and step a grid position per exit. Rooms
    that already had coordinates seed their area, so hand-tuned areas keep
    roughly the shape their owner gave them.

    Overlaps are not resolved. In a MUD an area folds back on itself constantly
    — three norths and a west can land where you started — and every 2D mapper
    ever written either overlaps or lies about the geometry. Overlapping is the
    honest one.
    """
    pos = {}
    by_area = {}
    for uid, r in rooms.items():
        by_area.setdefault(r["area"], []).append(uid)

    overlaps = 0

    for area, uids in by_area.items():
        placed = set()

        # a room that already has coordinates makes the best anchor; failing
        # that, the lowest vnum, which on Aardwolf is usually an entrance
        seeds = sorted(uids, key=lambda u: (rooms[u]["x"] is None, u))

        for seed in seeds:
            if seed in pos:
                continue

            r = rooms[seed]
            start = (r["x"], r["y"], r["z"]) if r["x"] is not None else (0, 0, 0)
            pos[seed] = start
            placed.add(start)

            queue = [seed]
            while queue:
                cur = queue.pop(0)
                cx, cy, cz = pos[cur]

                for direction, dest in links.get(cur, ()):
                    if dest in pos or dest not in rooms:
                        continue
                    if rooms[dest]["area"] != area:
                        continue

                    d = STEP.get(direction)
                    if not d:
                        continue

                    spot = (cx + d[0], cy + d[1], cz + d[2])
                    if spot in placed:
                        overlaps += 1

                    pos[dest] = spot
                    placed.add(spot)
                    queue.append(dest)

    return pos, overlaps


def write_chunk(path, header, rows):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("-- generated by tools/import-mushmap.py — do not edit\n")
        fh.write(header + "\n")
        fh.write("local M = {}\n")
        # one row per line: greppable, and the transpiler handles a long
        # sequence of small statements better than one giant literal
        for r in rows:
            fh.write("M[#M+1] = " + r + "\n")
        fh.write("return M\n")


def main():
    db = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DB

    if not os.path.exists(db):
        print(f"no mapper database at {db}", file=sys.stderr)
        return 1

    os.makedirs(OUT, exist_ok=True)

    # read-only, and on a copy of the URI so a live MUSHclient can't be
    # disturbed by us holding a handle on its map
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row

    for old in os.listdir(OUT):
        if old.startswith("awmap-"):
            os.remove(os.path.join(OUT, old))

    ###
    # rooms
    ###
    rooms = con.execute(
        "SELECT uid, name, area, building, terrain, info, notes, x, y, z, "
        "       norecall, noportal FROM rooms ORDER BY CAST(uid AS INTEGER)"
    ).fetchall()

    ###
    # exits first: the layout below walks them, and rooms can't be written
    # until every room knows where it sits
    ###
    plain, doors, special = [], [], []
    links = {}

    for e in con.execute("SELECT dir, fromuid, touid FROM exits"):
        kind, direction, command = classify(e["dir"])
        frm, to = lua_num(e["fromuid"]), lua_num(e["touid"])

        if frm == "nil" or to == "nil":
            continue

        if kind == "exit":
            plain.append("{f=%s,t=%s,d=%s}" % (frm, to, lua_str(direction)))
        elif kind == "door":
            doors.append("{f=%s,t=%s,d=%s,c=%s}" % (
                frm, to, lua_str(direction), lua_str(command)))
        else:
            special.append("{f=%s,t=%s,c=%s}" % (frm, to, lua_str(command)))

        # doors are ordinary movement for layout purposes; specials are not,
        # since a portal's other end has no spatial relationship to this one
        if direction:
            links.setdefault(int(frm), []).append((direction, int(to)))

    keep = {}
    for r in rooms:
        if lua_num(r["uid"]) == "nil":
            continue
        keep[int(r["uid"])] = {
            "area": r["area"] or "",
            "x": r["x"], "y": r["y"], "z": r["z"],
        }

    pos, overlaps = lay_out(keep, links)

    roomChunks, buf, n, skipped = 0, [], 0, 0
    for r in rooms:
        #[[ 'nomap_<name>_<area>' rows are rooms Aardwolf never gave a vnum.
        #   Nothing links to them — zero exits reference one — so they'd land
        #   as orphans with no way in or out. ]]
        if lua_num(r["uid"]) == "nil":
            skipped += 1
            continue

        xyz = pos.get(int(r["uid"]), (0, 0, 0))

        buf.append(
            "{uid=%s,name=%s,area=%s,terrain=%s,info=%s,notes=%s,"
            "x=%d,y=%d,z=%d,building=%s}" % (
                lua_num(r["uid"]), lua_str(r["name"]), lua_str(r["area"]),
                lua_str(r["terrain"]), lua_str(r["info"]), lua_str(r["notes"]),
                xyz[0], xyz[1], xyz[2],
                lua_str(r["building"])))

        if len(buf) >= ROOMS_PER_CHUNK:
            roomChunks += 1
            write_chunk(os.path.join(OUT, f"awmap-r{roomChunks:03d}.lua"),
                        f"-- rooms {n + 1}..{n + len(buf)}", buf)
            n += len(buf)
            buf = []

    if buf:
        roomChunks += 1
        write_chunk(os.path.join(OUT, f"awmap-r{roomChunks:03d}.lua"),
                    f"-- rooms {n + 1}..{n + len(buf)}", buf)

    # a counter per kind, so the files read x001.., o001.., s001.. instead of
    # one sequence running across all three
    exitChunks = 0
    for tag, rows in (("x", plain), ("o", doors), ("s", special)):
        buf, seq = [], 0
        for row in rows:
            buf.append(row)
            if len(buf) >= EXITS_PER_CHUNK:
                seq += 1
                exitChunks += 1
                write_chunk(os.path.join(OUT, f"awmap-{tag}{seq:03d}.lua"),
                            f"-- {tag} exits", buf)
                buf = []
        if buf:
            seq += 1
            exitChunks += 1
            write_chunk(os.path.join(OUT, f"awmap-{tag}{seq:03d}.lua"),
                        f"-- {tag} exits", buf)

    ###
    # areas and environment colours, small enough for one file each
    ###
    areas = ["{uid=%s,name=%s,color=%s,flags=%s}" % (
        lua_str(a["uid"]), lua_str(a["name"]), lua_str(a["color"]),
        lua_str(a["flags"])) for a in con.execute("SELECT * FROM areas")]

    envs = ["{uid=%s,name=%s,color=%s}" % (
        lua_num(v["uid"]), lua_str(v["name"]), lua_num(v["color"]))
        for v in con.execute("SELECT * FROM environments")]

    write_chunk(os.path.join(OUT, "awmap-areas.lua"), "-- areas", areas)
    write_chunk(os.path.join(OUT, "awmap-envs.lua"), "-- environments", envs)

    ###
    # the index the importer reads first, so it knows the shape of the job
    # before it starts and can show a real progress bar rather than a spinner
    ###
    def chunk_names(prefix):
        return sorted(f[:-4] for f in os.listdir(OUT)
                      if f.startswith(f"awmap-{prefix}") and f.endswith(".lua"))

    with open(os.path.join(OUT, "awmap-index.lua"), "w", encoding="utf-8") as fh:
        fh.write("-- generated by tools/import-mushmap.py — do not edit\n")
        fh.write("local M = { rooms = %d, plain = %d, doors = %d, special = %d,\n"
                 "            areas = %d, envs = %d,\n"
                 "            roomFiles = {}, exitFiles = {}, doorFiles = {}, specialFiles = {} }\n"
                 % (len(rooms) - skipped, len(plain), len(doors), len(special),
                    len(areas), len(envs)))

        for field, prefix in (("roomFiles", "r"), ("exitFiles", "x"),
                              ("doorFiles", "o"), ("specialFiles", "s")):
            for name in chunk_names(prefix):
                fh.write('M.%s[#M.%s+1] = "%s"\n' % (field, field, name))

        fh.write("return M\n")

    total = sum(os.path.getsize(os.path.join(OUT, f))
                for f in os.listdir(OUT) if f.startswith("awmap-"))

    print(f"rooms     {len(rooms) - skipped}  in {roomChunks} chunk(s)"
          + (f"   ({skipped} nomap room(s) skipped)" if skipped else ""))
    print(f"exits     {len(plain)} plain, {len(doors)} door, {len(special)} special")
    print(f"laid out  {len(pos)} room(s), {overlaps} overlapping cell(s)")
    print(f"areas     {len(areas)}")
    print(f"envs      {len(envs)}")
    print(f"wrote     {OUT} ({total // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
