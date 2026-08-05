--[[
    aw-who.lua
    Sean Stoves (Solao) — 2026-08-05

    Player tracker. Reads 'who' output, keeps a record of everyone it has ever
    seen, and can sweep on a timer with the output gagged.

    Parsing happens in onLine rather than in triggers, and that is not a style
    choice: a line discarded from onLine fires no triggers at all, so a gagged
    sweep would be an invisible one. Both jobs have to happen in the same pass.

    Nothing here needs GMCP. Aardwolf has no who package — the list only exists
    as text, which is why this is a parser and not a subscription.
]]

plugin = {
    id          = "aw-who",
    name        = "Aardwolf Players",
    version     = "1.1.0",
    author      = "Solao",
    description = "Who list with per-player tell, whois and finger, a searchable history and timed sweeps.",
    settings    = { saveState = true },
}

-- @category widgets

local TAG  = "$Y[Who v" .. plugin.version .. "]$w "
local TAGR = "$R[Who v" .. plugin.version .. "]$w "

local DB_FILE = "aw-who.json"
local VAR     = "aw_who_db"

local MAX_ROWS = 80          -- rendered at once; search is how you reach the rest

local widget = nil
local view   = "list"        -- "list" | "settings"

--[[
    Everyone ever seen, keyed by lowercased name. The sweep list is separate
    and holds only the most recent one: "online" means "in the last sweep",
    which is a claim we can actually support.
]]
local players = {}
local sweep   = { names = {}, at = 0, found = 0, max = 0, conns = 0 }

local inSweep = false        -- between the header and the footer
local tail    = false        -- past the footer, still inside the block
local auto    = false        -- this sweep is ours, so gag it
local dirty   = false

local cfg = {
    poll  = false,           -- sweep on a timer
    mins  = 15,              -- minutes between sweeps
    gag   = true,            -- hide the output of our own sweeps
    query = "",              -- current search
}

------------------------------------------------------------------------------
-- helpers. every one of these exists because of something the Lua-to-JS
-- boundary does differently; see docs/MUDFORGE-NOTES.md
------------------------------------------------------------------------------

local function str(v)
    if type(v) ~= "string" then return nil end
    if v == "" or v == "undefined" or v == "null" then return nil end
    return v
end

local function num(v)
    local n = tonumber(v)
    if type(n) ~= "number" then return nil end
    if n ~= n then return nil end
    return n
end

local function trim(s)
    if type(s) ~= "string" then return "" end

    local a = 1
    while a <= string.len(s) and string.sub(s, a, a) == " " do a = a + 1 end

    local b = string.len(s)
    while b >= a and string.sub(s, b, b) == " " do b = b - 1 end

    return string.sub(s, a, b)
end

-- split on whitespace by hand: Lua character classes don't survive the JS
-- regex engine, and this runs on every line of a hundred-player sweep
local function words(s)
    local out, cur = {}, ""

    for i = 1, string.len(s) do
        local c = string.sub(s, i, i)
        if c == " " or c == "\t" then
            if cur ~= "" then table.insert(out, cur); cur = "" end
        else
            cur = cur .. c
        end
    end

    if cur ~= "" then table.insert(out, cur) end
    return out
end

local function esc(s)
    if type(s) ~= "string" then return "" end
    s = string.gsub(s, "&", "&amp;")
    s = string.gsub(s, "<", "&lt;")
    s = string.gsub(s, ">", "&gt;")
    s = string.gsub(s, '"', "&quot;")
    return s
end

local function commas(n)
    if type(n) ~= "number" then return "0" end

    local s, out, c = tostring(math.floor(n)), "", 0
    for i = string.len(s), 1, -1 do
        out = string.sub(s, i, i) .. out
        c = c + 1
        if c % 3 == 0 and i > 1 then out = "," .. out end
    end
    return out
end

local function key_of(name)
    return string.lower(trim(name or ""))
end

------------------------------------------------------------------------------
-- storage
------------------------------------------------------------------------------

--[[
    Hand-built JSON, read back with json.decode. Same reasoning as the SnD
    database: an encoder's behaviour on nested arrays across the transpiler is
    the sort of thing that has bitten repeatedly here.

    Mirrored into a world variable because saveTable and savePluginFile are
    both scoped to the plugin, and a remove-and-re-add — how every update is
    installed — takes them with it.
]]
local function save_db()
    if not dirty then return end

    local rows = {}
    for _, p in pairs(players) do
        table.insert(rows, '{"n":"' .. string.gsub(p.name, '"', "")
            .. '","l":' .. tostring(p.level or 0)
            .. ',"r":"' .. string.gsub(p.race or "", '"', "")
            .. '","c":"' .. string.gsub(p.class or "", '"', "")
            .. '","t":"' .. string.gsub(p.title or "", '"', "")
            .. '","g":"' .. string.gsub(p.flags or "", '"', "")
            .. '","s":' .. tostring(p.seen or 1)
            .. ',"a":' .. tostring(p.at or 0) .. "}")
    end

    local blob = "[" .. table.concat(rows, ",") .. "]"

    if savePluginFile(DB_FILE, blob, "global") then dirty = false end
    pcall(function() setVariable(VAR, blob) end)
end

local function load_db()
    local raw = loadPluginFile(DB_FILE, "global")

    -- the plugin's own file is gone after a reinstall; the variable isn't
    if type(raw) ~= "string" or raw == "" then
        local ok, back = pcall(function() return getVariable(VAR) end)
        if ok and type(back) == "string" then raw = back end
    end

    if type(raw) ~= "string" or raw == "" then return 0 end

    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return 0 end

    local n = 0
    for _, r in pairs(data) do
        if type(r) == "table" and str(r.n) then
            players[key_of(r.n)] = {
                name  = r.n,
                level = num(r.l) or 0,
                race  = r.r or "",
                class = r.c or "",
                title = r.t or "",
                flags = r.g or "",
                badge = r.b or "",
                seen  = num(r.s) or 1,
                at    = num(r.a) or 0,
            }
            n = n + 1
        end
    end

    return n
end

local function save_cfg()
    saveTable("aw_who", cfg)
    pcall(function()
        setVariable("aw_who_cfg", '{"poll":' .. (cfg.poll and "true" or "false")
            .. ',"mins":' .. tostring(cfg.mins)
            .. ',"gag":' .. (cfg.gag and "true" or "false") .. "}")
    end)
end

------------------------------------------------------------------------------
-- parsing
------------------------------------------------------------------------------

--[[
    One who line, as Aardwolf actually prints them:

        [ 36  Cent   Ran] BlastFomer holds nothing sacred x|| BOOT ||x[C]
        [***ROADHOUSE***] Fertain not a barbarian .:::|Loqui|:::.[C]
        [    Fabled     ] Elmaster the Bandit ~-/Pyre\-~
        [  1  Human  T+7] (OPK) Haladin
        [ 12  Human  Thi] (Linkdead) TheBlackRose the Bandit

    The bracket is level/race/class most of the time and a badge the rest —
    ROADHOUSE, Fabled, SUPERHEROINE — so a numeric first token is what decides,
    not the width. Then any number of (Flag) groups, then the name, then
    whatever the player set as a title.
]]
local function parse_line(line)
    local inside = string.match(line, "^\\[(.+?)\\] ")
    if type(inside) ~= "string" then return nil end

    local rest = string.sub(line, string.len(inside) + 4)
    if trim(rest) == "" then return nil end

    local level, race, class = 0, "", ""
    local badge = trim(inside)
    local bits = words(badge)

    if #bits >= 3 and num(bits[1]) then
        level = num(bits[1]) or 0
        race  = bits[2]
        class = bits[3]
        badge = ""
    end

    -- (OPK), (Linkdead) and friends, however many there are
    local flags = {}
    while true do
        local f = string.match(rest, "^\\(([^)]+)\\) ")
        if type(f) ~= "string" then break end

        table.insert(flags, f)
        rest = trim(string.sub(rest, string.len(f) + 4))
    end

    local parts = words(rest)
    if #parts == 0 then return nil end

    local name = parts[1]
    local title = trim(string.sub(rest, string.len(name) + 1))

    return {
        name  = name,
        level = level,
        race  = race,
        class = class,
        badge = badge,
        title = title,
        flags = table.concat(flags, " "),
    }
end

local function remember(p)
    local k = key_of(p.name)
    if k == "" then return end

    local was = players[k]

    players[k] = {
        name  = p.name,
        -- a badge line carries no level, so don't overwrite a real one with 0
        level = (p.level > 0) and p.level or ((was and was.level) or 0),
        race  = (p.race ~= "") and p.race or ((was and was.race) or ""),
        class = (p.class ~= "") and p.class or ((was and was.class) or ""),
        title = p.title,
        flags = p.flags,
        -- ROADHOUSE, Fabled, SUPERHEROINE: the bracket carries a badge instead
        -- of a level for these, and it's the only place that says so
        badge = (p.badge ~= "") and p.badge or ((was and was.badge) or ""),
        seen  = ((was and was.seen) or 0) + 1,
        at    = getCurrentTime(),
    }

    dirty = true
end

------------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------------

local CSS = [[
<style>
    .arc-w {
        font-family: "JetBrains Mono", ui-monospace, monospace;
        color: hsl(var(--foreground, 35 34% 78%));
        height: 100%; box-sizing: border-box;
        display: flex; flex-direction: column;
        background:
            radial-gradient(120% 110% at 15% -10%, rgba(147,25,24,0.13), transparent 60%),
            hsl(var(--card, 0 12% 8%));
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: var(--glass-radius, 4px);
    }
    .arc-w .bar {
        display: flex; align-items: center; gap: 5px; flex-wrap: wrap;
        padding: 7px 9px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-w .stat {
        font-size: 9px; letter-spacing: 0.06em;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        font-variant-numeric: tabular-nums;
    }
    .arc-w .stat b {
        color: hsl(var(--foreground, 35 34% 78%));
        font-weight: normal; font-size: 11px;
    }
    .arc-w .sp { flex: 1; }

    .arc-w .body { flex: 1; min-height: 0; overflow-y: auto; padding: 6px 9px 9px; }

    .arc-w form { display: flex; gap: 5px; margin: 0 0 6px; }
    .arc-w input[type=text] {
        flex: 1; min-width: 0;
        font-family: inherit; font-size: 10px;
        padding: 4px 6px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        background: rgba(0,0,0,0.35);
        color: hsl(var(--foreground, 35 34% 78%));
    }
    .arc-w button {
        font-family: inherit; font-size: 8px;
        letter-spacing: 0.1em; text-transform: uppercase;
        padding: 3px 9px; border-radius: 2px; cursor: pointer;
        border: 1px solid hsl(var(--primary, 0 72% 42%));
        background: transparent; color: hsl(var(--primary, 0 72% 42%));
    }

    .arc-w .p {
        display: flex; flex-direction: column; gap: 3px;
        padding: 4px 5px; margin-bottom: 4px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-left: 2px solid hsl(var(--border, 0 22% 17%));
        border-radius: 3px;
        background: rgba(0,0,0,0.22);
    }
    .arc-w .p.on { border-left-color: #86c48f; }
    .arc-w .p1 { display: flex; align-items: baseline; gap: 7px; }
    .arc-w .lvl {
        font-size: 9px; min-width: 74px; flex-shrink: 0;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        font-variant-numeric: tabular-nums;
    }
    .arc-w .nm { font-size: 11px; flex-shrink: 0; }
    .arc-w .ti {
        font-size: 9px; flex: 1; min-width: 0;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .arc-w .fl { font-size: 8px; color: hsl(var(--primary, 0 72% 42%)); }

    .arc-w .p2 {
        display: flex; gap: 4px; padding: 3px 0 0 21px;
        border-top: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-w .go {
        font-size: 7px; letter-spacing: 0.1em; text-transform: uppercase;
        padding: 1px 6px; border-radius: 2px; line-height: 1.4;
        border: 1px solid hsl(var(--primary, 0 72% 42%));
        color: hsl(var(--primary, 0 72% 42%));
        cursor: pointer; user-select: none; white-space: nowrap;
    }
    .arc-w .go:hover { background: rgba(147,25,24,0.25); }

    .arc-w .tb {
        font-size: 8px; letter-spacing: 0.1em; text-transform: uppercase;
        padding: 3px 7px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer; user-select: none; white-space: nowrap;
    }
    .arc-w .tb.on {
        color: hsl(var(--primary, 0 72% 42%));
        border-color: hsl(var(--primary, 0 72% 42%));
        background: rgba(147,25,24,0.14);
    }
    .arc-w .empty {
        font-size: 10px; text-align: center; padding: 16px 0;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-w .note {
        font-size: 9px; line-height: 1.55; margin-top: 7px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-w .sec {
        font-size: 8px; letter-spacing: 0.18em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        margin: 10px 0 5px; padding-bottom: 4px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-w .sec:first-child { margin-top: 0; }
</style>
]]

local function online_set()
    local on = {}
    for _, n in ipairs(sweep.names) do on[key_of(n)] = true end
    return on
end

--[[
    Who to show: the last sweep by default, everything ever seen when there's a
    search. Searching only the online list would make the history unreachable,
    which is most of what a tracker is for.
]]
local function rows_for()
    local q = string.lower(trim(cfg.query or ""))
    local out = {}

    if q == "" then
        for _, n in ipairs(sweep.names) do
            local p = players[key_of(n)]
            if p then table.insert(out, p) end
        end
        return out, false
    end

    for _, p in pairs(players) do
        local hay = string.lower(p.name .. " " .. (p.title or "") .. " "
            .. (p.race or "") .. " " .. (p.class or ""))
        if string.find(hay, q, 1, true) then table.insert(out, p) end
    end

    return out, true
end

local function render()
    if not widget then return end

    local on = online_set()
    local list, searching = rows_for()

    local bar = '<div class="stat">ONLINE <b>' .. commas(#sweep.names) .. '</b></div>'
        .. '<div class="stat">TRACKED <b>' .. commas(sweep.tracked or 0) .. '</b></div>'

    if sweep.max > 0 then
        bar = bar .. '<div class="stat">PEAK <b>' .. commas(sweep.max) .. '</b></div>'
    end
    if sweep.conns > 0 then
        bar = bar .. '<div class="stat">CONNS <b>' .. commas(sweep.conns) .. '</b></div>'
    end

    bar = bar .. '<div class="sp"></div>'
        .. '<div class="tb" data-mud-action="sweep">who</div>'
        .. '<div class="tb' .. (view == "settings" and " on" or "")
        .. '" data-mud-action="view">&#9881;</div>'

    if view == "settings" then
        local body = '<div class="sec">Sweeps</div>'
            .. '<div class="bar" style="padding:0;border:0">'
            .. '<div class="tb' .. (cfg.poll and " on" or "") .. '" data-mud-action="poll">'
            .. (cfg.poll and ("every " .. cfg.mins .. " min") or "off") .. '</div>'
            .. '<div class="tb" data-mud-action="less">&minus;</div>'
            .. '<div class="tb" data-mud-action="more">+</div>'
            .. '<div class="tb' .. (cfg.gag and " on" or "") .. '" data-mud-action="gag">'
            .. 'hide output</div>'
            .. '</div>'
            .. '<div class="note">Sends <code>who</code> on a timer and reads the reply. '
            .. '<b>Hide output</b> keeps those sweeps out of the terminal — a who you '
            .. 'type yourself is never hidden.</div>'
            .. '<div class="sec">Records</div>'
            .. '<div class="note">' .. commas(sweep.tracked or 0)
            .. ' player(s) remembered. Search matches name, title, race and class '
            .. 'across all of them, not just whoever is online.</div>'
            .. '<div class="bar" style="padding:0;border:0">'
            .. '<div class="tb" data-mud-action="forget">forget all</div></div>'

        setWidgetProperty(widget, "content", CSS
            .. '<div class="arc-w"><div class="bar">' .. bar .. '</div>'
            .. '<div class="body">' .. body .. '</div></div>')
        return
    end

    local body = '<form data-mud-action="find">'
        .. '<input type="text" name="q" placeholder="search name, title, class..." value="'
        .. esc(cfg.query or "") .. '">'
        .. '<button type="submit">find</button></form>'

    if #list == 0 then
        body = body .. '<div class="empty">'
            .. (searching and "Nobody matches that" or "No sweep yet &mdash; press WHO")
            .. '</div>'
    end

    local shown = 0
    for _, p in ipairs(list) do
        if shown >= MAX_ROWS then break end
        shown = shown + 1

        local who = (p.level > 0)
            and (p.level .. " " .. (p.race or "") .. " " .. (p.class or ""))
            or (str(p.badge) or "&mdash;")

        body = body .. '<div class="p' .. (on[key_of(p.name)] and " on" or "") .. '">'
            .. '<div class="p1">'
            .. '<span class="lvl">' .. esc(who) .. '</span>'
            .. '<span class="nm">' .. esc(p.name) .. '</span>'

        if str(p.flags) then
            body = body .. '<span class="fl">' .. esc(p.flags) .. '</span>'
        end

        body = body .. '<span class="ti">' .. esc(p.title or "") .. '</span>'
            .. '</div><div class="p2">'
            .. '<span class="go" data-mud-action="tell" data-mud-data="' .. esc(p.name) .. '">tell</span>'
            .. '<span class="go" data-mud-action="whois" data-mud-data="' .. esc(p.name) .. '">whois</span>'
            .. '<span class="go" data-mud-action="finger" data-mud-data="' .. esc(p.name) .. '">finger</span>'
            .. '</div></div>'
    end

    if #list > shown then
        body = body .. '<div class="note">' .. commas(#list - shown)
            .. ' more &mdash; narrow the search to see them.</div>'
    end

    setWidgetProperty(widget, "content", CSS
        .. '<div class="arc-w"><div class="bar">' .. bar .. '</div>'
        .. '<div class="body">' .. body .. '</div></div>')
end

------------------------------------------------------------------------------
-- the sweep
------------------------------------------------------------------------------

local function count_tracked()
    local n = 0
    for _ in pairs(players) do n = n + 1 end
    sweep.tracked = n
end

local function do_sweep()
    auto = true
    send("who")

    --[[
        Safety net. If the reply never comes — disconnected, or the MUD too
        busy — auto would stay set and silently eat the next 'who' you typed
        yourself. Ten seconds is far longer than a sweep takes.
    ]]
    setTimeout(function()
        if auto and not inSweep and not tail then auto = false end
    end, 10000)
end

--[[
    Everything happens here, gagging included.

    A line dropped from onLine fires no triggers, so parsing in a trigger and
    gagging here would mean a hidden sweep is also an unread one. Both jobs,
    one pass.

    Only OUR sweeps are hidden: a 'who' you typed is something you asked to
    see, and silently eating it would be the plugin overruling you.
]]
function onLine(line)
    if type(line) ~= "string" then return end

    local hide = auto and cfg.gag

    if string.find(line, "Aardwolf Players Online", 1, true) then
        inSweep = true
        tail = false
        sweep.names = {}
        return not hide
    end

    --[[
        The block does not end at 'Players found:'. Aardwolf follows it with

            Players found: [88], Max this reboot: [232], Connections...
            Players invis: [116], Max on ever: [853]

        and the second line escaped the gag entirely, so an automatic sweep
        still put a stray line on screen. Anything starting 'Players ' is part
        of the tail; the first line that isn't ends the block.
    ]]
    if tail then
        if string.sub(line, 1, 8) == "Players " then
            return not hide
        end

        tail = false
        auto = false
        return
    end

    if not inSweep then return end

    local found = string.match(line, "^Players found: *\\[?(\\d+)")
    if type(found) == "string" then
        sweep.found = num(found) or 0
        sweep.at = getCurrentTime()

        local mx = string.match(line, "Max this reboot: *\\[?(\\d+)")
        local cn = string.match(line, "Connections this reboot: *\\[?(\\d+)")
        if type(mx) == "string" then sweep.max = num(mx) or sweep.max end
        if type(cn) == "string" then sweep.conns = num(cn) or sweep.conns end

        inSweep = false
        tail = true

        count_tracked()
        save_db()
        render()

        return not hide
    end

    local p = parse_line(line)
    if p then
        remember(p)
        table.insert(sweep.names, p.name)
        return not hide
    end

    --[[
        Everything else between the header and the footer: the 'Use swho'
        hint, the rules, anything Aardwolf adds later. An automatic sweep hides
        the whole block, not the parts we happen to recognise — a line we
        didn't anticipate appearing on its own is exactly what "gag the output"
        is meant to prevent.
    ]]
    if hide then return false end
end

------------------------------------------------------------------------------
-- lifecycle
------------------------------------------------------------------------------

local pollTimer = nil

local function arm_poll()
    if pollTimer then
        removeTimer(pollTimer)
        pollTimer = nil
    end

    if not cfg.poll then return end

    -- milliseconds: addTimer(1, ...) measured 21ms between ticks, so it is not
    -- the seconds the name suggests
    pollTimer = addTimer(cfg.mins * 60000, do_sweep, true)
end

function init()
    widget = createWidget({
        type     = "html",
        name     = "who",
        title    = "Players",
        position = { x = 640, y = 60 },
        size     = { width = 460, height = 420 },
    })

    local saved = loadTable("aw_who")

    if type(saved) ~= "table" then
        local ok, raw = pcall(function() return getVariable("aw_who_cfg") end)
        if ok and type(raw) == "string" and raw ~= "" then
            local dok, data = pcall(json.decode, raw)
            if dok and type(data) == "table" then saved = data end
        end
    end

    if type(saved) == "table" then
        if saved.poll == true then cfg.poll = true end
        if saved.gag == false then cfg.gag = false end
        if num(saved.mins) and num(saved.mins) >= 1 then cfg.mins = num(saved.mins) end
    end

    -- the backup is only written on save, so a fresh install has none until
    -- something changes. Write one now.
    save_cfg()

    local n = load_db()
    count_tracked()

    if n > 0 then
        utilprint(TAG .. "remembering " .. commas(n) .. " player(s).")
    end

    registerWidgetEvent(widget, "action", function(data)
        if type(data) ~= "table" then return end

        local act = tostring(data.action or "")
        local arg = tostring(data.data or "")

        if act == "tell" then
            --[[
                Prefilled, not sent. A tell is something you're about to write,
                and firing 'tell <name>' on its own would just draw an error
                from the MUD.
            ]]
            if type(insertText) == "function" then
                insertText("tell " .. arg .. " ")
            else
                utilprint(TAG .. "tell " .. arg .. " ...")
            end
            return

        elseif act == "whois" then
            send("whois " .. arg)
            return

        elseif act == "finger" then
            send("finger " .. arg)
            return

        elseif act == "sweep" then
            do_sweep()
            return

        elseif act == "view" then
            view = (view == "settings") and "list" or "settings"

        elseif act == "poll" then
            cfg.poll = not cfg.poll
            save_cfg()
            arm_poll()

        elseif act == "gag" then
            cfg.gag = not cfg.gag
            save_cfg()

        elseif act == "more" then
            cfg.mins = cfg.mins + 5
            save_cfg()
            arm_poll()

        elseif act == "less" then
            cfg.mins = (cfg.mins > 5) and (cfg.mins - 5) or 1
            save_cfg()
            arm_poll()

        elseif act == "forget" then
            players = {}
            sweep.names = {}
            dirty = true
            count_tracked()
            save_db()

        else
            return
        end

        render()
    end)

    --[[
        Form submits carry every named field, which is how a search box works
        without any JavaScript in the widget.
    ]]
    registerWidgetEvent(widget, "submit", function(data)
        if type(data) ~= "table" then return end

        local f = data.formData
        if type(f) ~= "table" then return end

        cfg.query = trim(tostring(f.q or ""))
        render()
    end)

    arm_poll()
    render()
end

function cleanup()
    dirty = true
    save_db()
end

------------------------------------------------------------------------------
-- commands
------------------------------------------------------------------------------

registerCommand("players", function(args)
    local a = trim(tostring(args or ""))
    local sub = string.lower(a)

    if sub == "" then
        do_sweep()
        return
    end

    if sub == "off" then
        cfg.poll = false
        save_cfg()
        arm_poll()
        utilprint(TAG .. "sweeps off.")
        return
    end

    local mins = num(sub)
    if mins and mins >= 1 then
        cfg.mins = math.floor(mins)
        cfg.poll = true
        save_cfg()
        arm_poll()
        utilprint(TAG .. "sweeping every " .. cfg.mins .. " minute(s).")
        return
    end

    -- anything else is a search
    cfg.query = a
    view = "list"
    render()
    utilprint(TAG .. "searching for '" .. a .. "'.")
end, "Who list and player history. '/players' sweeps now, '/players 15' every 15 minutes, '/players off', '/players <text>' searches")
