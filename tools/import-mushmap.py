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

import json
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


#
# MudForge's own settings block, read out of a real export. Reproduced whole
# because the importer replaces settings rather than merging, and handing it a
# partial one would leave the map with no terrain colours.
#
# maxRooms is the reason this is here at all: it ships at 10,000 and a
# MUSHclient Aardwolf map is 22,946.
#
SETTINGS = {
    "showVnums": False, "showBannerVnum": True, "zoomLevel": 1,
    "terrainStyles": [
        {"name": "default", "color": "#3498db"},
        {"name": "inside",  "color": "#2c3e50"},
        {"name": "field",   "color": "#27ae60"},
        {"name": "forest",  "color": "#16a085"},
        {"name": "water",   "color": "#2980b9"},
        {"name": "city",    "color": "#8e44ad"},
        {"name": "road",    "color": "#95a5a6"},
    ],
    "autoSave": True, "maxRooms": 100000, "fastWalk": False,
    "customExitTimeout": 5, "walkStepDelayMs": 0, "nodeMode": False,
    "nodeLinkLength": 20, "nodeLineColor": "#ffffff",
    "recentRoomsCount": 100, "recentRoomsColor": "#ffaf00",
}

#
# MUSHclient stores an environment's colour as an ANSI index, which is what the
# mapper drew with. The values confirm it: ocean is 4 (blue), field 2 (green),
# forest 10 (bright green), mountain 3 (brown), air 14 (cyan), sun 11 (yellow).
#
# These are the xterm values for the 16 ANSI slots. Bright red at index 9 rather
# than pure #ff0000 because a wall of saturated primaries is unreadable at map
# zoom, which is presumably why MUSHclient's own palette is muted too.
#
ANSI_HEX = {
    0:  "#2c3e50", 1:  "#c0392b", 2:  "#27ae60", 3:  "#b9770e",
    4:  "#2980b9", 5:  "#8e44ad", 6:  "#16a085", 7:  "#95a5a6",
    8:  "#5d6d7e", 9:  "#e74c3c", 10: "#2ecc71", 11: "#f1c40f",
    12: "#3498db", 13: "#af7ac5", 14: "#48c9b0", 15: "#ecf0f1",
}


def terrain_styles(con, existing):
    """MUSHclient's terrain colours, in MudForge's terrainStyles shape.

    Rooms carry their terrain by NAME and terrainStyles is keyed by name, so the
    two line up without a translation table. 134 environments come over, not
    just the forty-odd currently in use — a room in an area you map later
    already has its colour waiting.

    The client's own colours WIN. That's the opposite of the first version, and
    the reason is that after one import the client's export already carries
    MUSHclient's colours — so any difference from them is something you changed
    on purpose. Overriding would have quietly reverted shop to green on the next
    run, an hour after it was set to orange.

    MUSHclient therefore fills gaps rather than overwriting: terrains the client
    has never heard of get a colour, everything else is left alone.
    """
    styles = []
    seen = set()

    for st in (existing or []):
        if isinstance(st, dict) and st.get("name"):
            styles.append({"name": st["name"], "color": st.get("color", "#3498db")})
            seen.add(st["name"])

    added = 0
    for e in con.execute("SELECT name, color FROM environments ORDER BY name"):
        name = (e["name"] or "").strip()
        if not name:
            continue

        hexcode = ANSI_HEX.get(int(e["color"] or 7), "#95a5a6")

        if name not in seen:
            styles.append({"name": name, "color": hexcode})
            seen.add(name)
            added += 1

    return styles, added


# the export writes n/e/s/w/u/d, not the long names
SHORT = {"north": "n", "south": "s", "east": "e", "west": "w",
         "up": "u", "down": "d"}


def load_settings(path):
    """Lift settings and env colours out of an export MudForge wrote.

    Better than shipping defaults: whatever you've set in the map panel —
    zoom, node mode, terrain colours — survives the import instead of being
    reset to whatever was current the day this was written.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None, None

    if not isinstance(d, dict):
        return None, None

    st = d.get("settings") if isinstance(d.get("settings"), dict) else None
    ex = d.get("extras") if isinstance(d.get("extras"), dict) else {}
    return st, (ex.get("envColors") if isinstance(ex.get("envColors"), dict) else None)


def write_json(path, rooms, links, specials, pos, areas, titles, stamp,
               settings=None, env_colors=None, styles=None):
    """MudForge's own map format, straight from an export of a live map.

    Rooms carry their exits inline as {direction: vnum} — there's no separate
    connections list — and lastVisited/timesVisited are on every single one.
    That last part isn't cosmetic: the renderer draws the rooms you've visited
    and puts a stub where a neighbour exists but isn't drawn, which is why an
    import that skipped those fields showed two rooms and four arrows in an
    area holding two hundred and eighty-five.

    Special exits go in the same exits object, keyed by the command rather than
    a direction. A live export had none to copy, so this is the one part
    modelled on addSpecialExit(from, COMMAND, to) rather than observed — a
    wrong guess costs the portals and nothing else.
    """
    out = []

    for uid, r in rooms.items():
        x, y, z = pos.get(uid, (0, 0, 0))

        exits = {}
        for direction, dest in links.get(uid, ()):
            exits[SHORT.get(direction, direction)] = dest
        for command, dest in specials.get(uid, ()):
            exits[command] = dest

        room = {
            "num": uid,
            "name": r["name"],
            "zone": r["area"],
            "terrain": r["terrain"],
            "x": x, "y": y, "z": z,
            "exits": exits,
            "lastVisited": stamp,
            "timesVisited": 1,
        }

        data = {}
        if titles.get(r["area"]):
            data["aard.area"] = titles[r["area"]]
        if r.get("notes"):
            data["aard.notes"] = r["notes"]
        if data:
            room["userData"] = data

        if r.get("info"):
            room["details"] = r["info"]

        out.append(room)

    #
    # Your settings where we have them, ours where we don't — except maxRooms,
    # which ships at 10,000 and would quietly truncate a 22,946 room map. It
    # only ever gets raised, never lowered.
    #
    conf = dict(SETTINGS)
    if isinstance(settings, dict):
        conf.update(settings)

    need = int(len(out) * 1.5) + 1000
    if int(conf.get("maxRooms") or 0) < need:
        conf["maxRooms"] = need

    if styles:
        conf["terrainStyles"] = styles

    doc = {
        "rooms": out,
        "settings": conf,
        "state": {"levels": {}, "currentLevel": 0, "currentRoom": None},
        "labels": [],
        "extras": {"envColors": env_colors or {}, "knownAreas": sorted(areas)},
    }

    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, separators=(",", ":"))

    return len(out)


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
    links, specials = {}, {}

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
        else:
            specials.setdefault(int(frm), []).append((command, int(to)))

    keep = {}
    for r in rooms:
        if lua_num(r["uid"]) == "nil":
            continue
        keep[int(r["uid"])] = {
            "area": r["area"] or "",
            "name": r["name"] or "",
            "terrain": r["terrain"] or "",
            "info": r["info"] or "",
            "notes": r["notes"] or "",
            "x": r["x"], "y": r["y"], "z": r["z"],
        }

    pos, overlaps = lay_out(keep, links)

    skipped = sum(1 for r in rooms if lua_num(r["uid"]) == "nil")

    ###
    # MudForge's own format. This is the one that matters now: its map importer
    # takes it directly, so none of the per-room API calls — and none of their
    # argument-order surprises — are involved.
    ###
    titles = {}
    keys = set()
    for a in con.execute("SELECT uid, name FROM areas"):
        if a["uid"]:
            keys.add(a["uid"])
            if a["name"]:
                titles[a["uid"]] = a["name"]

    stamp = int(os.path.getmtime(db) * 1000)

    # third argument: an export MudForge wrote, to inherit map settings from
    conf, env_colors = (None, None)
    if len(sys.argv) > 3 and os.path.isfile(sys.argv[3]):
        conf, env_colors = load_settings(sys.argv[3])

    styles, added = terrain_styles(con, (conf or {}).get("terrainStyles"))

    json_path = os.path.join(OUT, "aardwolf-map.json")
    n_json = write_json(json_path, keep, links, specials, pos, keys, titles,
                        stamp, conf, env_colors, styles)

    print(f"rooms     {len(rooms) - skipped}"
          + (f"   ({skipped} nomap room(s) skipped)" if skipped else ""))
    print(f"exits     {len(plain)} plain, {len(doors)} door, {len(special)} special")
    print(f"areas     {len(keys)}")
    print(f"terrain   {len(styles)} colour(s), {added} from MUSHclient")
    print(f"laid out  {len(pos)} room(s), {overlaps} overlapping cell(s)")
    print(f"wrote     {json_path} ({os.path.getsize(json_path) // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
