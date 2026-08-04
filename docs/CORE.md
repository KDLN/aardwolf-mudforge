# Aardwolf Core — what it does and how to build against it

Core is protocol plumbing. It has no panel of its own beyond a settings
window, and everything else in this suite depends on it.

Enable Core first. Without it: no group data, no channel packages, and the
other plugins sit empty waiting for GMCP that was never subscribed to.

---

## What Core owns

**`Core.Supports.Set`, exclusively.**

Aardwolf *replaces* its record of your subscriptions when it receives this —
it does not merge. Two senders means the second one silently unsubscribes
everything absent from its own list, including `room.info`, which is what
MudForge's built-in mapper runs on. There is no error and no symptom beyond
panels quietly going stale, which is the worst kind of bug to inherit.

So: **never send `Core.Supports.Set` from your own plugin.** Declare what you
need and let Core send the union.

Core also sends, once per login:

| what | why |
|---|---|
| `group on` | Aardwolf's group monitor is off by default |
| `gmcpchannels off` | opt-in; see below |
| `request room`, `request quest` | prime state rather than waiting for a change |

`request char` is deliberately **not** in the automatic path. It makes
Aardwolf resend `char.*` including `char.base`, which is the packet Core
bootstraps on — `request char → char.base → bootstrap → request char`, at
whatever rate the server answers. It ran away exactly like that once.
`/awcore` sends it manually, where the latch is already set.

---

## Declaring what you need

In your plugin's `init()`:

```lua
broadcastPlugin("aw-gmcp", "Char,Room")
```

That is the whole contract. Core keeps declarations per plugin, sends the
union, and rebuilds when plugins are enabled, disabled or removed.

**Valid keywords** — Aardwolf rejects anything else with `unsupported
keyword`, and one bad entry taints the whole message:

| keyword | packages |
|---|---|
| `Char` | `char.base`, `char.vitals`, `char.maxstats`, `char.stats`, `char.status`, `char.worth` |
| `Comm` | `comm.channel`, `comm.quest`, `comm.tick`, `comm.repop` |
| `Room` | `room.info` |
| `Group` | `group` |
| `Core` | `core.*` |

`Core` and `Room` are always sent. Core is not optional, and the mapper reads
`room.info` but is not a plugin, so it cannot declare for itself — leaving
`Room` to whichever plugin happens to want it means disabling that plugin
kills the map.

### Why a comma-separated string and not a table

Arrays crossing the plugin boundary in this client have arrived 0-indexed,
as `undefined`, and as JSON objects with numeric keys, at different times. A
string cannot do any of that. See [MUDFORGE-NOTES.md](MUDFORGE-NOTES.md).

### Ordering

Core usually loads before the plugins that need things. Declarations are
persisted so the next login negotiates the full set immediately rather than
starting narrow and widening a second later — a login where half the panels
start empty.

Persistence is a head start, not the truth. On startup Core rebuilds against
`getLoadedPlugins()`, so a plugin removed between sessions doesn't keep its
packages subscribed.

Declaring again with the same value is free — Core ignores it. Declare in
`init()` and don't think about it.

---

## What Core does not do

- **It does not gag anything.** `gmcpchannels on` is off by default and
  opt-in in Core's settings. It sounds like a client-side convenience and is
  not: Aardwolf stops sending channel text to the main window entirely, for
  every channel at once, and no per-channel setting can override it.
- **It does not own panels.** Widgets, layout and rendering are each
  plugin's own problem.
- **It does not proxy GMCP.** Subscribe with `onGMCPUpdate` and read with
  `getGMCPData` yourself; Core only makes sure the data arrives.

---

## Bootstrap timing

Core negotiates when `char.base` arrives, which is Aardwolf's de-facto login
signal and safely *after* the client has finished its own GMCP negotiation.
That ordering matters: our supports list replaces whatever MudForge sent, so
going last is the point.

`onConnect` fires a delayed safety net for characters that somehow never emit
`char.base`. Both paths go through a latch — once per login, re-armed on
disconnect — plus a 5-second floor between negotiations regardless. If
anything ever re-opens a feedback loop, that caps it at one round per
interval instead of letting it run at server speed.

---

## Commands

| command | does |
|---|---|
| `/awcore` | open the settings window |
| `/awcore gmcp` | the live package list, and which plugin asked for what |
| `/awcore go` | re-negotiate now |
| `/awcore debug` | add `debug 1`, so Aardwolf echoes its own GMCP parse errors |
| `/awcore quiet` | silence Core's startup line |

The `GMCP Sent:` lines in your terminal are MudForge's own protocol echo, not
Core's. Those live under **Settings → Debug**.

---

## A minimal plugin against Core

```lua
plugin = {
    id          = "my-thing",
    name        = "My Thing",
    version     = "1.0.0",
    author      = "you",
    description = "Reads char.vitals and shows it.",
}

local widget = nil

local function refresh()
    local v = getGMCPData("char.vitals")
    if type(v) ~= "table" then return end          -- type check, not truthiness

    setWidgetProperty(widget, "content",
        "<style>.b{font-family:monospace;color:#d7c4a4}</style>"
        .. "<div class='b'>HP " .. tostring(v.hp) .. "</div>")
end

function init()
    broadcastPlugin("aw-gmcp", "Char")             -- tell Core what you need

    widget = createWidget({
        type     = "html",
        name     = "mine",                         -- required: id is pluginId+name
        title    = "My Thing",
        position = { x = 200, y = 200 },
        size     = { width = 240, height = 80 },
    })

    onGMCPUpdate("char.vitals", refresh)
    refresh()
end
```

Two things in there are not optional, and both are covered in
[MUDFORGE-NOTES.md](MUDFORGE-NOTES.md): the `name` on `createWidget`, and
`type(v) ~= "table"` instead of `if v then`.
