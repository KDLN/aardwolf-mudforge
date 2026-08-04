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
| **Blood Moon** | Dark theme in Aardwolf's own brick red, parchment and steel. Optional. |

Each panel keeps its settings behind the gear icon in its own titlebar. The
text commands (`/awcore`, `/awchar`, `/chat`, `/snd`, `/awvitals`, `/awgroup`)
do the same things for anyone who'd rather type.

---

## Bringing your MUSHclient map across

If you've mapped Aardwolf in MUSHclient, that map can come with you — rooms,
areas, terrain, doors and portals.

Double-click the launcher for your platform in `tools/`:

| | |
|---|---|
| macOS | `Import Aardwolf Map.command` |
| Windows | `Import Aardwolf Map.bat` |
| Linux | `import-aardwolf-map.sh` |

It looks for your `Aardwolf.db` in the usual places and offers it; otherwise it
opens a file picker. Your MUSHclient files are opened read-only and never
modified.

It writes `aardwolf-map.json` to your Desktop. In MudForge, open the map
panel's `⋯` menu, choose **Import Map Data**, pick that file, and restart — the
map view is built at startup and won't show the new rooms until it is.

Existing map settings are kept: the tool reads the most recent export MudForge
has written and carries your zoom, node mode and terrain colours across. The
one thing it overrides is `maxRooms`, which ships at 10,000 and would truncate
a 22,946 room map.

Needs Python 3, which ships with macOS developer tools and most Linux
distributions; on Windows get it from python.org and tick *Add Python to PATH*.
The Linux file dialog additionally wants `python3-tk` — without it you're asked
to paste the path, which works just as well.

**Why isn't this a button in the panel?** Because it can't be. A MudForge
plugin cannot read a file it didn't write — `loadPluginFile` returns nil for
any path outside its own storage, and `readFile`/`loadFile` don't exist — and
the storage it *can* read lives in IndexedDB inside the app, where nothing
outside can put anything. So the conversion happens out here and MudForge's own
importer does the rest, which is also why the whole thing is one file and one
click rather than a plugin writing 22,946 rooms an API call at a time.

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
