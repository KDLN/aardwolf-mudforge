# Aardwolf for MudForge

GMCP-driven panels for [Aardwolf](https://www.aardwolf.com/) in the MudForge
client. Character sheet with race/class portraits, live vitals, group roster,
a channel window with per-channel routing, and Search & Destroy for quest,
campaign and global quest targets.

Everything here reads GMCP. Nothing screen-scrapes state the MUD already
sends, so the panels stay right through a reconnect.

---

## Install

### As a plugin repository

**Settings → Plugins → Add Repository**, and give it:

```
https://raw.githubusercontent.com/SeanStoves/aardwolf-mudforge/main/github.com/plugins.json
```

If that URL looks wrong, it is — and it's deliberate. MudForge's "Add
Repository" button validates the URL by checking whether the *string* contains
`github.com`, without making a request. `raw.githubusercontent.com` doesn't
contain that substring and gets rejected, and the `github.com/<repo>/raw/`
form that does contain it redirects in a way that fails CORS. So this repo
also serves the catalog from a directory literally named `github.com`, which
satisfies the check while still being fetched from a URL that sends
`access-control-allow-origin: *`.

The straight URL works anywhere the validator isn't in the way:

```
https://raw.githubusercontent.com/SeanStoves/aardwolf-mudforge/main/plugins.json
```

### By hand

Download the `script` field out of any `dist/<id>.json` and save it as a
`.lua` file in MudForge's plugin folder:

```
~/Library/Application Support/com.mudforge.app/plugins/     (macOS)
```

Name the file after the plugin's **display name** — `Aardwolf Core.lua`, not
`aw-core.lua`. MudForge names its own managed copies that way, and dropping
both loads the plugin twice.

### Install Core first

`Aardwolf Core` negotiates the GMCP subscriptions everything else reads. The
other panels sit empty without it — no group data, no channels, no quest
status. It has no window of its own beyond a settings pane.

---

## What's in here

| plugin | what it does |
|---|---|
| **Aardwolf Core** | GMCP negotiation and session bootstrap. Required. |
| **Aardwolf Character Info** | Portrait, level, stat grid, vitals, worth, alignment, XP to level. |
| **Aardwolf Live Vitals** | Wide HP/mana/moves gauges and a target focus readout. |
| **Aardwolf Comms** | Channel window with tabs, per-channel gag and mute, custom regex captures. |
| **Aardwolf Group** | Group roster with per-member health, mana, moves and level. |
| **Aardwolf Search and Destroy** | Quest, campaign and gquest targets. Learned mob database, hunt, hunt trick, click-to-walk. |
| **Aardwolf ASCII Map** | The MUD's own ASCII map, scaled to fit its panel, colours intact. Derived from MudForge's ASCII Map Widget example. |
| **Aardwolf Loot Tracker** | Records what drops from what, shop stock and room resources, and parses every identify box that scrolls past. Shares into a pooled database. |
| **Aardwolf Shop** | `list` in a shop as clickable rows. Click a name to appraise it, a number to buy that many. |
| **Blood Moon** | Dark theme in Aardwolf's own brick red, parchment and steel. Optional. |

Each panel keeps its settings behind the gear icon in its own titlebar. The
text commands (`/awcore`, `/awchar`, `/chat`, `/snd`, `/awvitals`, `/awgroup`,
`/shop`, `/who`, `/loot`, `/awmap`)
do the same things for anyone who'd rather type.

---

## Bringing your MUSHclient map across

If you've mapped Aardwolf in MUSHclient, that map can come with you — every
room, its area, terrain, doors and portals. A fully mapped Aardwolf is around
34,000 rooms and imports in one go.

**1. Export your current map first.** In MudForge, open the map panel's `⋯`
menu and choose **Export Map Data**. This is optional but worth doing: the tool
reads the most recent export it can find and carries your settings across, so
zoom, node mode and any terrain colours you've set survive the import.

**2. Run the tool.** Double-click the launcher for your platform in `tools/`:

| | |
|---|---|
| macOS | `Import Aardwolf Map.command` |
| Windows | `Import Aardwolf Map.bat` |
| Linux | `import-aardwolf-map.sh` |

It looks for `Aardwolf.db` in the usual places and offers what it finds;
otherwise it opens a file picker. Your MUSHclient files are opened read-only
and are never modified. Conversion takes a few seconds and writes
`aardwolf-map.json` to your Desktop.

**3. Import it.** Back in MudForge, map panel `⋯` menu → **Import Map Data** →
pick that file.

**4. Restart MudForge.** The map view is built when the client starts, so it
won't show the new rooms until it is. This step is not optional and a skipped
restart looks exactly like a failed import.

### What comes across

Rooms keep their Aardwolf vnum as the room id, so anything you have already
mapped in MudForge is the same room rather than a duplicate. Along with the
name, area and terrain, each room carries its exits, its `details` flags —
shop, bank, healer, trainer, questor, safe, pk, maze, guild — and any portal or
door as a custom exit.

Terrain colours come from MUSHclient's own palette, converted from the ANSI
indices it stores. Colours you have set yourself are never overwritten: after
one import your export already holds MUSHclient's colours, so anything
different is a deliberate choice and is left alone.

Room coordinates are worked out here. MUSHclient stores them for only a
fraction of rooms — its mapper recomputes the layout from exits every time it
draws and never writes most of it down — so each area is walked breadth-first
and given a grid position per exit. Areas that *did* have coordinates keep
roughly the shape you gave them.

`maxRooms` is raised out of the way. It ships at 10,000, which would silently
truncate any real map — but it isn't sized to your import either, since a cap
that just fits today's rooms becomes the thing that stops you mapping more. If
you have already set it higher, that stands.

Nothing else is added. No symbols, no markers — the file says what MUSHclient
says, so importing resets the map rather than merging in history.

### What you need to run it

Python 3: bundled with macOS developer tools and most Linux distributions; on
Windows get it from [python.org](https://www.python.org/downloads/) and tick
*Add Python to PATH*. On Linux the file dialog also wants `python3-tk`
(`apt install python3-tk`, `dnf install python3-tkinter`) — without it you're
asked to paste the path instead, which works just as well.

### This has nothing to do with the plugins

The tool reads a SQLite file and writes JSON; MudForge imports it natively. Use
it without installing anything else here, and the panels work fine without ever
running it. It lives in this repo because it was written alongside them.

An earlier version *did* import from a plugin, writing every room through the
mapper API — which meant reverse-engineering each call, and each wrong guess
failed silently: `addSpecialExit` wants the command in the middle,
`updateMapRoom` replaces the record rather than merging, `pcall` doesn't catch
a `false` return, and rooms without `lastVisited` are never drawn. The export
format gets all of that right by construction, so that code is gone.

---

## Portraits

Character Info picks an avatar from your GMCP `char.base` — race, primary
class and sex — out of 19 races × 7 primary classes, in male, female and
neutral. Subclasses map to their primary, so a Blacksmith gets the Warrior
art.

To use your own instead:

```
/avatar https://example.com/me.png
/avatar data:image/png;base64,...
/avatar clear
```

or paste the URL into the settings pane. It's stored per profile.

The frame around the portrait is your remort tier and changes as you go.

---

## Writing your own plugin against Core

**[docs/CORE.md](docs/CORE.md)** — what Core owns, how to declare the GMCP
packages your plugin needs, and a minimal working plugin.

The short version: never send `Core.Supports.Set` yourself. Aardwolf
*replaces* its record of your subscriptions when it receives one, so a second
sender silently unsubscribes everything missing from its own list — including
`room.info`, which is what the built-in mapper runs on. Declare instead, and
Core sends the union:

```lua
function init()
    broadcastPlugin("aw-gmcp", "Char,Room")
end
```

Core rebuilds that union when plugins are enabled, disabled or removed, so
your packages go away with your plugin.

**[docs/MUDFORGE-NOTES.md](docs/MUDFORGE-NOTES.md)** — the parts of MudForge
plugin authoring that aren't in the official docs. MudForge transpiles Lua to
JavaScript rather than running a Lua VM, and the seams show: varargs arrive
`undefined`, arrays cross the boundary 0-indexed, `undefined` is truthy, Lua
patterns run on a JS regex engine, `next` isn't in the sandbox. Widget HTML
goes through DOMPurify, so inline colour, `<script>` and `onclick` are all
stripped. Every entry cost a debugging session.

---

## Requirements

- MudForge 1.2 or later
- An Aardwolf character (`aardwolf.com`, port 4000)
- GMCP enabled client-side, which MudForge does by default

Blood Moon is a theme and works on its own. Everything else wants Core.
