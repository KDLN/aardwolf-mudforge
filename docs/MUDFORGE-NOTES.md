# Writing MudForge plugins — what the docs don't tell you

> **[docs/MUDFORGE-API-GUIDE.md](MUDFORGE-API-GUIDE.md) is the reference —
> check it before this file and before writing anything.** It comes from
> MudForge's own authors and they keep it current, so it outranks everything
> here on any point the two disagree on. Re-copy it from upstream rather than
> editing it; local edits would be lost and would make it untrustworthy for
> exactly the questions it's the answer to.
>
> What follows is the delta: what this codebase learned the hard way, kept
> because most of it is still not in there — and because several entries were
> measured against a running client rather than inferred, which is the only
> reason they're trustworthy at all.
>
> Confirmed by the official guide, so no longer guesses:
> `onLine(sessionId, rawLine, cleanLine)`; `addSpecialExit(from, command, to)`
> (command in the middle); mapper lists being 0-indexed; `addTimer` returning
> `""` while disconnected; `saveTable`/`savePluginFile` with scope `"global"`
> being shared app-wide **across every plugin**, keyed only by name — prefix
> yours or you will clobber someone.
>
> Corrected by it: trigger callbacks are `(captures, line, wildcards, rawLine)`
> — captures FIRST. Code here that sniffs the arguments predates knowing that.

MudForge parses Lua with `luaparse` and **transpiles it to JavaScript**.
There is no Lua VM. Most of the time that's invisible; these are the places
it isn't. Every one below cost a debugging session, and `luac -p` passes
cleanly on all of them.

Sanitiser notes are equally hard-won: widget HTML goes through DOMPurify with
default config, and several obvious approaches silently do nothing.

---

## The Lua-to-JavaScript boundary

### 1. Varargs don't survive

```lua
local function get(...)
    for _, name in ipairs({...}) do   -- loop runs, every name is undefined
```

The loop executes and the values arrive `undefined`. Symptom was
`getGMCPData(): e.split is not a function`, twelve times per refresh. **Take
an explicit table.**

### 2. Arrays from JavaScript are 0-indexed

GMCP payloads, `getLoadedPlugins()` results, anything originating on the JS
side. Lua expects 1. Read from 0 upward and fall back to `ipairs`:

```lua
local i = 0
while list[i] ~= nil do ... i = i + 1 end
if #out == 0 then for _, v in ipairs(list) do ... end end
```

### 3. Lua arrays sent *out* become objects

Passing a Lua table to `sendGMCP` produced `{"1":"Core 1","2":"Char 1"}` — a
JSON *object*, because Lua arrays are 1-indexed. Aardwolf rejects that
outright and the subscription silently never takes. **Build the JSON text
yourself** and pass a string; `sendGMCP` forwards a string untouched.

### 4. Command arguments are a string *or* a table

`registerCommand` may hand over the raw argument string. Indexing a string
yields characters: `args[1]` off `"sex male"` is `"e"`, which then got
validated as a URL. Handle both shapes.

### 5. `undefined` is truthy

It is neither `nil` nor `false`, so Lua truthiness treats it as a value:

```lua
if cfg.size then                    -- passes when cfg.size is undefined
    resizeWidget(w, cfg.size.width) -- throws
```

**Use `type(x) == "table"` and `x == true`, never bare truthiness**, on
anything from GMCP, `loadTable` or a widget event. Related: `tostring(nil)`
prints `null`, and JS `undefined` reaching a string field arrives as the
literal text `"undefined"` — so `x or ""` never fires and a panel cheerfully
renders `SPRITE UNDEFINED`.

### 5b. A trigger created mid-packet never sees that packet

Register every trigger at `init` and gate it on state. Do NOT create one from
inside another trigger's callback to catch the lines that follow.

The identify box arrives whole — `Keywords`, `Name`, `Type`, all in one
packet. Arming the row trigger from the `Keywords` callback meant `Keywords`
was captured (it IS the opening line) and every row after it was missed, so
every record stored under an undefined name. The same defect silently broke
the `{roomchars}` player capture and Core's tag-block gag, where the whole
block arrives at once and went ungagged.

**The MUSHclient set had this right and the Mudlet port lost it.** MUSHclient
declares every trigger up front with `enabled="n"` and flips the flag;
Mudlet's `tempRegexTrigger` works there because it feeds triggers line by
line. Porting the Mudlet shape to this client reintroduces the bug — when the
two disagree, MUSHclient's is the one that survives a packet-at-a-time
runtime.

```lua
-- wrong: the rest of the box is already in this packet
addTrigger("^\\| Keywords", function()
    rowTrig = addTrigger("^[|+](.*)$", read_row, { type = "regex" })
end, { type = "regex" })

-- right: it exists before the packet does
addTrigger("^[|+](.*)$", function(c, l, w)
    if not inBox then return end
    read_row(c, l, w)
end, { type = "regex" })
```

### 6. Nested tables from `loadTable` aren't safely indexable

Even behind a `type()` guard. `cfg.size = { width, height }` kept throwing on
load. **Store scalars** — `cfg.sizeW`, `cfg.sizeH`.

### 7. Lua patterns run on a JavaScript regex engine

`%x`, `%d`, `%a`, `%s` mean nothing to it. `string.match(hex,
"^#(%x%x%x%x%x%x)$")` never matched, so every colour silently fell back to
white. Use `[0-9a-f]`, `\\d`, `[a-z]`, `\\s` — or plain `string.find(s, c, 1,
true)` and a manual loop.

### 8. `next` is not in the sandbox

`next(t)` fails the whole plugin load with `_G.next is not a function`. Use
`for _ in pairs(t) do return false end`.

### 9. No duplicate `local` in one scope

Lua allows shadowing; the transpiler emits `let` and rejects it with
`Cannot declare a let variable twice`, failing the **entire plugin load**.
Nested closures are fine — same block is not.

### 10. `onLine` takes three arguments, and the first is not the line

```lua
function onLine(sessionId, rawLine, cleanLine)
```

Written as `onLine(line)` every pattern matches against
`session-1785816768709-k8wpur` — 50 lines seen, 0 matches, and no error
anywhere to say why. `cleanLine` arrives with colour already stripped, which
matters for anything anchored at `^`: who output is heavily coloured and an
escape sequence in front of the text defeats the anchor.

Returning `false` discards the line. Returning nothing keeps it.

### 11. `string.find`'s `init` argument does not advance the search

```lua
-- hangs: q keeps returning the same position while from grows
local at, from = nil, 1
while true do
    local q = string.find(body, needle, from, true)
    if not q then break end
    at, from = q, q + 1
end
```

This locked the client hard enough to need a force quit. Every other
`string.find` in this codebase passes `init = 1`, so it was the first use of
the argument and nothing catches it by reading.

Walk by slicing instead — the haystack is strictly shorter each pass, so it
terminates whatever `find` does with its arguments:

```lua
local at, offset = nil, 0
while true do
    local q = string.find(string.sub(body, offset + 1), needle, 1, true)
    if not q then break end
    at = offset + q
    offset = at
end
```

**Put an iteration cap on any `while` driven by string length.** A loop that
stops shrinking its input takes the whole client with it, and there is no
error, no log line and no way to tell it from a slow machine.

### 12. Don't assume the whole stdlib

`table.concat(t, sep, i, j)`'s start-index form and similar corners are worth
avoiding. `io` and `os` exist but are restricted implementations.

### 13. `registerCommand` shadows the MUD's command of the same name

The client matches the first word of the input against registered commands
before it decides whether to send anything, and a match means it never sends.
So a plugin registering `search` eats Aardwolf's own `search all`, and one
registering `chat` eats the chat channel — the player types the command they
have used for years and gets plugin help back.

Nothing warns about this and nothing shows it in a plugin list; it only turns
up when someone uses the MUD command. Prefix anything that collides with a
real MUD command: `awsearch`, `awchat`. Check `help <word>` on the MUD before
picking a name, and remember Aardwolf abbreviates, so a short name can collide
with the start of a longer one.

---

## Widget HTML and the sanitiser

Content set with `setWidgetProperty(id, "content", html)` is run through
DOMPurify with **default config**, inside an iframe.

### What does not work

| approach | result |
|---|---|
| `style="background: rgb(…)"` | colour stripped |
| `style="background-image: url(…)"` | stripped |
| a **second** `<style>` element | ignored entirely — only the first applies |
| `onclick=` and friends | stripped |

Colour and `url()` in an inline `style` attribute are dropped while
*geometry* in the same attribute survives — `left: 40%` positions fine. That
asymmetry is confusing and cost three attempts to pin down.

### What does work

- **One `<style>` element**, containing everything. A dynamic `url()` inside
  it is fine; that's how portraits and frames load.
- **Class names on markup.** Enumerate a palette as static rules and have
  Lua pick a class. This is the only reliable way to vary colour.
- **`data-mud-action` / `data-mud-data`** for clicks, delivered via
  `registerWidgetEvent(id, "action", fn)`.
- **`<form>` submits**, which carry every named field:
  `registerWidgetEvent(id, "submit", fn)` → `data.formData`. This is how to
  get typed text without JavaScript.
- **`<img src="data:image/png;base64,…">`** — DOMPurify's data-URI tag
  allowlist is `audio, video, img, source, image, track`.
- **`data-mud-bind="key"` with `setBoundValue(id, key, value)`** writes into
  a marked element without rebuilding the widget. Use it for anything that
  updates faster than the user interacts — a one-second countdown re-rendering
  the whole panel is sixty rebuilds a minute, and it resets scroll each time.

### `<a href>` renders, and clicking it crashes the client

Not stripped — that was a guess and it was wrong. An anchor survives the
sanitiser intact, keeps its `class`, and styles correctly. What it does on
click is navigate the **widget's own iframe** to the URL, replacing the panel
with the web page, and MudForge goes down with it. `target="_blank"` does not
help: the frame has no permission to open a window, so it navigates in place
instead.

Tested four ways in one panel — bare anchor, classed anchor, anchor with
`target`, and a `data-mud-action` span. All four render and all three anchors
take the client out.

**Never emit `href` in widget HTML.** To reach a browser, use a
`data-mud-action` span and have the handler call `hyperlink(url, url)`, which
prints a terminal link; an `http(s)` action there opens the browser properly.
That is two clicks and it is the only route that exists.

The same applies to the `prompt:` scheme, which was tried in the shop panel and
did nothing at all — the anchor renders and the scheme is inert.

### Prefer CSS backgrounds to `<img>` for anything that might 404

A failed `<img>` draws the browser's broken-image placeholder. A failed
background layer paints nothing, so a fallback underneath shows through:

```css
background-image: url("remote.png"), url("data:image/png;base64,…");
```

---

## Widgets

- **`name` is required** if a plugin creates more than one. The widget id is
  `pluginId + name`, defaulting to `"widget"` — two unnamed widgets resolve
  to the same id and the second silently returns the first.
- **Saved geometry wins.** MudForge restores per-widget position and size, so
  changing a default only affects a fresh profile. A widget can be restored
  underneath another panel and behind it in z-order: visible by every
  measure, and impossible to see.
- **Re-rendering resets scroll.** Rebuilding the whole widget on every click
  throws a long list back to the top. Use form controls the browser toggles
  locally and apply on submit.

---

## Plugin loading

- **MudForge caches plugin source at install.** Updating the file on disk is
  not enough; remove and re-add to load new code. The file watcher only
  hot-reloads plugins it *already* has loaded.
- **Managed copies are named by display name** — `Aardwolf Core.lua`, not
  `aw-core.lua`. Dropping a source-named file alongside loads the plugin
  twice.
- **Version-stamp your output.** Chasing a bug that was already fixed on disk
  costs rounds you cannot get back:
  `local TAG = "$Y[Name v" .. plugin.version .. "]$w "`.

---

## The API surface is much bigger than the docs

`/awcore api` enumerates `_G` and prints every bound function. On 1.2.2011
that's **326 functions**, most of them undocumented. Before concluding a
plugin can't do something, run it — reasoning from the docs, or from the
shape of the IndexedDB stores, gets it wrong.

Two compatibility layers are in there alongside the native API:

| layer | examples |
|---|---|
| MUSHclient | `Send`, `Note`, `ColourNote`, `Execute`, `GetVariable`, `SetVariable`, `EnableTrigger`, `DoAfterSpecial`, `SaveState` |
| Mudlet | `addSpecialExit`, `getExitStubs1`, `setCustomEnvColor`, `tempRegexTrigger`, `tempTrigger`, `getRoomUserData`, `echo`, `cecho` |

**The mapper is fully writable**, which matters because the map's own
IndexedDB `connections` store is only `fromRoom / toRoom / direction / level /
weight` — no command field. Reading that schema suggests custom exits are
impossible. They aren't; they're just held somewhere else:

```
addSpecialExit  removeSpecialExit  clearSpecialExits  getSpecialExits
setDoor  getDoors  lockExit  hasExitLock  setExitStub  connectExitStub
addRoom  deleteRoom  setExit  setMapExit  setRoomName  setRoomArea
setRoomCoordinates  setRoomUserData  setRoomColor  setCustomEnvColor
createMapperWidget  importMapJson  exportMapJson  refreshMap
gotoRoom  getPath  findPath  setWalkDelay  setFastWalk  stopWalk
onMapReady  onMapUpdate  onMapRoomClick  onRoomChange
```

**`addSpecialExit(from, command, to)`** — command in the MIDDLE. Not Mudlet's
`(from, to, direction)`, despite the name coming from that compatibility layer.
The wrong order returns `false` and leaves `getSpecialExits` empty; it does not
throw, so a `pcall` around it reports success and the exits are silently
dropped. Treat a `false` return from any mapper writer as a failure.

So an Aardwolf mapper is a plugin driving the built-in engine, not a
replacement for it. `/awcore map` prints what each reader returns for the
room you're standing in — names alone don't give away argument order or
return shape.

---

## GMCP

### `onGMCPUpdate` gives you the packet. `getGMCPData` gives you the store.

They are not the same thing, and the difference only shows up on packages that
are **event-shaped** rather than **state-shaped**.

`getGMCPData(name)` returns what that package has accumulated — the last
message, with fields from earlier messages still sitting in it where the newer
one didn't overwrite them. For `char.vitals` that's exactly right: every packet
carries the full set, so the store *is* the current state and reading it on
load is how a panel fills itself in.

For `comm.quest` it is a trap. The packets are events and each carries only
what that event needs:

```
{ action = "start", targ = "a chilling silence", area = "...", timer = 30 }
{ action = "comp",  wait = 30 }          -- no targ; the old one survives
```

So an hour after turning the quest in, `getGMCPData("comm.quest")` still hands
back `targ = "a chilling silence"`. Seeding a panel from it resurrects quests
that are long dead, and it looks convincing because the rest of the record is
real.

**Ask instead of reading.** `sendGMCP("request quest")` comes back as a fresh
`status` packet through `onGMCPUpdate`, which is the only version that's true.
Same for anything else event-shaped — `comm.channel` has the same problem.

Time the request: Core defers its supports rebuild ~700ms after a plugin
enables, and the package has to be subscribed before a reply can arrive.
1500ms has been reliable.

### A reply that answers "no" still carries fields

`request quest` between quests answers with `action = "status"`, **no target,
and a zero `timer`**, alongside the `wait` that is the number you actually
want. Branch on the *data* — is there a target? — not on the action. Reading
the timer first rendered `0:00 left` on a panel with 25 real minutes on it.

---

## Aardwolf specifics

### noexp is on the prompt, not in GMCP

`char.status` carries `level` and `tnl` and nothing that says whether
experience is being earned, and `Help/Prompt` documents no code for it. The
MUD marks it on the prompt itself:

```
[368/368hp 219/219mn 717/717mv 54qt 1270tnl] >*[NOEXP]*
```

Read state off the prompt rather than off a toggle message. The prompt says
what is true *now*, so a reload, a reconnect, or a session that started in
noexp all settle on the first one — and the marker being absent is exactly as
meaningful as it being present, which gives both directions from one signal.
A toggle message only tells you about the moment it changed, and only if you
were listening.

- `Core.Supports.Set` **replaces**, never merges. See [CORE.md](CORE.md).
- `char.vitals` carries current values only; the maxima are in
  `char.maxstats`. Percentages need both.
- The group package is literally `group`, not `Group.Members`, and is **off**
  until `group on`.
- `room.info.exits` is an object keyed by direction, not an array.
- `char.base.class` is sometimes absent. Subclass maps to exactly one primary
  class, so derive it.
- `comm.quest.wait` is **minutes** — the stock client multiplies it by 60.
  `comm.quest.timer` is undocumented there (its branch is an empty comment).
  Quests are granted in the 30-60 minute range and cap well under two hours, so
  a value past 180 can't be minutes and has to be seconds.
- `remorts` counts from **1** for an unremorted character, not 0.
- Alignment runs −2500..2500: Good ≥ 875, Evil ≤ −875.
- `gmcpchannels on` means channels go over GMCP **only** — a server-side gag
  on every channel at once.
- `omitFromOutput` hides a line's text but **keeps its row**, leaving a blank
  gap. Returning `false` from `onLine` removes the line properly. Note
  `onLine` never sees blank lines at all — the client filters them before
  line handlers run.
