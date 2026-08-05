--[[
    aw-vitals.lua
    Sean Stoves (Solao) — 2026-08-04

    The bottom strip: big HP/mana/move gauges, and a target readout beside it.

    Character Info already shows these numbers in its stat grid — this is the
    at-a-glance version you actually watch mid-fight, which is why it's a
    separate wide panel rather than more rows in the portrait.

    Target comes from char.status: Aardwolf sends 'enemy' (the mob's short
    name) and 'enemypct' (its remaining health as a percentage). There is no
    absolute hp for a target, only the percentage.
]]

plugin = {
    id          = "aw-vitals",
    name        = "Aardwolf Live Vitals",
    version     = "1.3.1",
    author      = "Solao",
    description = "Wide HP, mana and move gauges with a target focus readout.",
    settings    = { saveState = true },
}

-- @category widgets

--[[
    Every diagnostic line carries the running version. Chasing a bug that
    was already fixed on disk cost several rounds — the output has to say
    which build is actually answering.
]]
local TAG  = "$Y[Vitals v" .. plugin.version .. "]$w "
local TAGR = "$R[Vitals v" .. plugin.version .. "]$w "

local vitals, target = nil, nil
local view = "panel"     -- "panel" | "settings"
local ch = {}

local cfg = {
    showTarget = true,
    autoTarget = false,   -- only while actually engaged
    pulse      = true,    -- flash the HP bar under 25%
    showPct    = false,   -- append a percentage to each gauge
}

--[[
    Settings that survive a reinstall.

    saveTable is scoped to the plugin, and removing a plugin takes its rows
    with it — which is exactly how every update to these plugins is installed.
    A world variable isn't tied to the plugin, so it comes through.

    saveTable stays as the fast path; this is the copy that actually persists,
    and load falls back to it. Flat scalars only, which is all any of these
    configs hold — nested tables crossing the transpiler are their own problem.
]]
local function keep(name, t)
    local out = {}

    for k, v in pairs(t) do
        local kind = type(v)
        if kind == "string" then
            table.insert(out, '"' .. tostring(k) .. '":"'
                .. string.gsub(string.gsub(v, "\\", ""), '"', "") .. '"')
        elseif kind == "number" or kind == "boolean" then
            table.insert(out, '"' .. tostring(k) .. '":' .. tostring(v))
        end
    end

    pcall(function() setVariable(name, "{" .. table.concat(out, ",") .. "}") end)
end

local function recall(name)
    local ok, raw = pcall(function() return getVariable(name) end)
    if not ok or type(raw) ~= "string" or raw == "" then return nil end

    local dok, data = pcall(json.decode, raw)
    if dok and type(data) == "table" then return data end
    return nil
end

local function save_cfg()
    saveTable("aw_vitals", cfg)
    keep("aw_vitals", cfg)
end

local icons = nil
do
    local ok, lib = pcall(require, "arcanum-icons")
    if ok and type(lib) == "table" then icons = lib end
end

-- Takes a table, never varargs — see the note in aw-portrait.lua.
local function gmcp_get(names)
    for _, name in ipairs(names) do
        local data = getGMCPData(name)
        -- type check, not truthiness: JS undefined is truthy under Lua rules
        -- and every caller indexes what this returns
        if type(data) == "table" then return data end
    end
    return nil
end

local function on_package(names, handler)
    for _, name in ipairs(names) do
        onGMCPUpdate(name, handler)
    end
end

-- JS undefined arrives as the literal string, so `or` guards never fire.
local function str(v)
    if type(v) ~= "string" then return nil end
    if v == "" or v == "undefined" or v == "null" then return nil end
    return v
end

local function commas(n)
    if type(n) ~= "number" then return "--" end

    local s, out, count = tostring(math.floor(n)), "", 0
    local neg = false

    if string.sub(s, 1, 1) == "-" then
        neg = true
        s = string.sub(s, 2)
    end

    for i = string.len(s), 1, -1 do
        out = string.sub(s, i, i) .. out
        count = count + 1
        if count % 3 == 0 and i > 1 then out = "," .. out end
    end

    if neg then out = "-" .. out end
    return out
end

local function pct(cur, max)
    if type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then return 0 end
    local p = (cur / max) * 100
    if p < 0 then return 0 end
    if p > 100 then return 100 end
    return p
end

local function esc(s)
    if type(s) ~= "string" then return "" end
    s = string.gsub(s, "&", "&amp;")
    s = string.gsub(s, "<", "&lt;")
    s = string.gsub(s, ">", "&gt;")
    s = string.gsub(s, '"', "&quot;")
    return s
end

local CSS = [[
<style>
    .arc-v {
        position: relative;
        font-family: "JetBrains Mono", ui-monospace, monospace;
        color: hsl(var(--foreground, 35 34% 78%));
        padding: 9px 11px;
        height: 100%;
        box-sizing: border-box;
        overflow: hidden;
        background:
            radial-gradient(120% 160% at 12% -30%, rgba(147,25,24,0.14), transparent 62%),
            hsl(var(--card, 0 12% 8%));
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: var(--glass-radius, 4px);
    }
    .arc-v .hd {
        font-size: 9px; letter-spacing: 0.2em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        margin-bottom: 8px;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }

    .arc-v .g { margin-bottom: 5px; }
    .arc-v .g:last-child { margin-bottom: 0; }
    .arc-v .track {
        position: relative; height: 13px;
        border-radius: 7px;
        background: rgba(0,0,0,0.62);
        border: 1px solid hsl(var(--border, 0 22% 17%));
        overflow: hidden;
    }
    .arc-v .fill {
        position: absolute; inset: 0 auto 0 0;
        border-radius: 7px 0 0 7px;
        transition: width .18s ease-out;
    }
    .arc-v .fill.hp    { background: linear-gradient(90deg, #7d2429 0%, #c0484e 62%, #e2777c 100%); }
    .arc-v .fill.mana  { background: linear-gradient(90deg, #33507d 0%, #6d8ec4 62%, #9db4e0 100%); }
    .arc-v .fill.moves { background: linear-gradient(90deg, #4c3579 0%, #8a6bc0 62%, #b49ade 100%); }
    .arc-v .fill.foe   { background: linear-gradient(90deg, #6d1f24 0%, #b03a40 62%, #d4595f 100%); }
    .arc-v .fill.low   { animation: arcpulse 1.05s ease-in-out infinite; }
    @keyframes arcpulse {
        0%, 100% { filter: brightness(1); }
        50%      { filter: brightness(1.6); }
    }
    .arc-v .val {
        position: relative; height: 100%;
        display: flex; align-items: center; justify-content: center;
        font-size: 9px; letter-spacing: 0.09em;
        text-shadow: 0 1px 2px rgba(0,0,0,0.95);
        white-space: nowrap;
        font-variant-numeric: tabular-nums;
    }

    /* target side */
    .arc-v .tgt { display: flex; gap: 11px; align-items: center; height: 100%; }
    .arc-v .foeimg {
        flex: none;
        width: 52px; height: 52px;
        border-radius: 50%;
        border: 2px solid hsl(var(--border, 0 22% 17%));
        background-color: rgba(0,0,0,0.55);
        background-repeat: no-repeat;
        background-position: center;
        background-size: 62%;
        opacity: 0.55;
        transition: opacity .2s, border-color .2s, box-shadow .2s;
    }
    .arc-v .foeimg.active {
        opacity: 1;
        border-color: hsl(var(--destructive, 0 72% 45%));
        box-shadow: 0 0 14px rgba(192,72,78,0.45);
    }
    .arc-v .tgtbody { flex: 1; min-width: 0; }
    .arc-v .tgtname {
        font-size: 15px;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .arc-v .tgtname.idle { color: hsl(var(--muted-foreground, 35 14% 52%)); }
    .arc-v .tgtcap {
        display: flex; justify-content: space-between; align-items: baseline;
        font-size: 8px; letter-spacing: 0.16em; text-transform: uppercase;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        margin-bottom: 4px;
    }
    .arc-v .pill {
        font-size: 7px; letter-spacing: 0.14em;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: 2px;
        padding: 1px 4px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-v .gear {
        position: absolute; top: 7px; right: 9px;
        font-size: 9px; padding: 2px 6px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer; user-select: none;
    }
    .arc-v .gear:hover { color: hsl(var(--primary, 0 72% 42%)); }
    .arc-v .sec {
        font-size: 8px; letter-spacing: 0.18em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        margin: 10px 0 5px; padding-bottom: 4px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-v .sec:first-child { margin-top: 0; }
    .arc-v .chips { display: flex; flex-wrap: wrap; gap: 4px; }
    .arc-v .chip {
        font-size: 8px; letter-spacing: 0.1em; text-transform: uppercase;
        padding: 3px 7px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer; white-space: nowrap; user-select: none;
    }
    .arc-v .chip:hover { color: hsl(var(--foreground, 35 34% 78%)); }
    .arc-v .chip.on {
        color: hsl(var(--primary, 0 72% 42%));
        border-color: hsl(var(--primary, 0 72% 42%));
        background: rgba(147,25,24,0.14);
    }
    .arc-v .note {
        font-size: 9px; line-height: 1.5; margin-top: 8px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-v .pill.hot {
        color: hsl(var(--destructive, 0 72% 45%));
        border-color: hsl(var(--destructive, 0 72% 45%));
    }
</style>
]]

--[[
    Command args arrive from JavaScript, where arrays start at 0 while Lua
    expects 1 — so args[1] is the SECOND word. Normalise before reading.
]]
local function argv(args)
    local out = {}

    --[[
        The runtime may hand over the raw argument string instead of a table.
        Indexing that yields characters, not words — args[1] off "sex male"
        is "e", which is how '/avatar sex male' ended up validating "e" as a
        URL and '/awgroup autohide' fell through to the debug dump.

        Split by hand: the string library runs on JS regex, so Lua character
        classes can't be trusted here.
    ]]
    if type(args) == "string" then
        local out, cur = {}, ""
        for i = 1, string.len(args) do
            local c = string.sub(args, i, i)
            if c == " " or c == "\t" then
                if cur ~= "" then table.insert(out, cur); cur = "" end
            else
                cur = cur .. c
            end
        end
        if cur ~= "" then table.insert(out, cur) end
        return out
    end

    if type(args) ~= "table" then return out end

    local i = 0
    while args[i] ~= nil do
        table.insert(out, tostring(args[i]))
        i = i + 1
    end

    if #out == 0 then
        for _, v in ipairs(args) do table.insert(out, tostring(v)) end
    end

    return out
end

local function gauge(label, cur, max, class)
    local filled = pct(cur, max)
    local low = (cfg.pulse and class == "hp" and filled > 0 and filled < 25) and " low" or ""

    local text = label .. ' ' .. commas(cur) .. ' / ' .. commas(max)
    if cfg.showPct and type(cur) == "number" and type(max) == "number" then
        text = text .. '  &middot; ' .. string.format("%.0f", filled) .. '%'
    end

    return '<div class="g"><div class="track">'
        .. '<div class="fill ' .. class .. low .. '" style="width:' .. string.format("%.2f", filled) .. '%"></div>'
        .. '<div class="val">' .. text .. '</div>'
        .. '</div></div>'
end

local function chip(action, data, label, on)
    return '<div class="chip' .. (on and ' on' or '') .. '"'
        .. ' data-mud-action="' .. action .. '" data-mud-data="' .. esc(data) .. '">'
        .. esc(label) .. '</div>'
end

local function render_settings()
    return '<div class="sec">Gauges</div><div class="chips">'
        .. chip("pulse", "1", "pulse under 25%", cfg.pulse and true or false)
        .. chip("pct",   "1", "show percent",    cfg.showPct and true or false)
        .. '</div>'
        .. '<div class="sec">Target panel</div><div class="chips">'
        .. chip("target", "1", cfg.showTarget and "visible" or "hidden", cfg.showTarget and true or false)
        .. chip("autotarget", "1", "only in combat", cfg.autoTarget and true or false)
        .. '</div>'
        .. '<div class="note">Target reads char.status enemy and enemypct. '
        .. 'Aardwolf leaves the name set after a fight, so the panel dims to '
        .. 'Last rather than pretending you are still engaged.</div>'
        .. '<div class="sec">Layout</div><div class="chips">'
        .. chip("reset", "1", "reset positions", false)
        .. '</div>'
        .. '<div class="note">Drags both widgets back on screen and raises them, '
        .. 'for when saved geometry has buried them under another panel.</div>'
end

local function render_vitals()
    if not vitals then return end

    local gear = '<div class="gear" data-mud-action="view" data-mud-data="'
        .. (view == "settings" and "panel" or "settings") .. '">'
        .. (view == "settings" and "&#9664;" or "&#9881;") .. '</div>'

    if view == "settings" then
        setWidgetProperty(vitals, "content", CSS
            .. '<div class="arc-v">' .. gear
            .. '<div style="overflow-y:auto">' .. render_settings() .. '</div>'
            .. '</div>')
        return
    end

    local who = str(ch.name) and (string.upper(esc(str(ch.name))) .. " &mdash; ") or ""

    setWidgetProperty(vitals, "content", CSS
        .. '<div class="arc-v">' .. gear
        .. '<div class="hd">' .. who .. 'Live Vitals</div>'
        .. gauge("HP",   ch.hp,    ch.maxhp,    "hp")
        .. gauge("MANA", ch.mana,  ch.maxmana,  "mana")
        .. gauge("MOVE", ch.moves, ch.maxmoves, "moves")
        .. '</div>')
end

--[[
    state 8 is Aardwolf's in-combat flag. enemy stays populated after a fight
    ends, so a name alone doesn't mean you're engaged.
]]
local function engaged()
    return ch.state == 8
end

--[[
    Auto-hide is opt-in per panel. A widget that vanishes on its own is
    disorienting if you didn't ask for it, so the default is to leave it up
    and let the panel say "no target" instead.
]]
local function apply_visibility()
    if not target then return end

    if not cfg.showTarget then
        hideWidget(target)
        return
    end

    if cfg.autoTarget and not engaged() then
        hideWidget(target)
    else
        showWidget(target)
    end
end

--[[
    Aardwolf leaves char.status.enemy set after a fight ends, so the presence
    of a name isn't proof of combat. state 8 is the authoritative "in combat"
    flag; without it the panel dims to an idle readout instead of implying
    you're still swinging at a corpse.
]]
local function render_target()
    if not target then return end

    local foe    = str(ch.enemy)
    local hp     = tonumber(ch.enemypct)
    local fighting = engaged()

    local art = icons and icons["icons/affects/generic"] or nil
    local img = '<div class="foeimg' .. (fighting and ' active' or '') .. '"'
        .. (art and (' style="background-image:url(\'' .. art .. '\')"') or '')
        .. '></div>'

    local name, bar, pill

    if foe then
        name = '<div class="tgtname">' .. esc(foe) .. '</div>'
        pill = fighting and '<span class="pill hot">Engaged</span>'
            or '<span class="pill">Last</span>'

        local shown = (type(hp) == "number") and hp or 100
        local low   = (shown > 0 and shown < 25) and " low" or ""

        bar = '<div class="g"><div class="track">'
            .. '<div class="fill foe' .. low .. '" style="width:' .. string.format("%.2f", shown) .. '%"></div>'
            .. '<div class="val">' .. string.format("%.0f", shown) .. '%</div>'
            .. '</div></div>'
    else
        name = '<div class="tgtname idle">No target</div>'
        pill = '<span class="pill">Idle</span>'
        bar  = '<div class="g"><div class="track"><div class="val">waiting for combat</div></div></div>'
    end

    setWidgetProperty(target, "content", CSS
        .. '<div class="arc-v"><div class="tgt">'
        .. img
        .. '<div class="tgtbody">'
        .. '<div class="tgtcap"><span>Target Focus</span>' .. pill .. '</div>'
        .. name
        .. bar
        .. '</div></div></div>')
end

local function pull()
    local b = gmcp_get({ "char.base", "Char.Base" })
    if type(b) == "table" then ch.name = b.name end

    local v = gmcp_get({ "char.vitals", "Char.Vitals" })
    if type(v) == "table" then
        ch.hp    = tonumber(v.hp)
        ch.mana  = tonumber(v.mana)
        ch.moves = tonumber(v.moves)
    end

    local m = gmcp_get({ "char.maxstats", "Char.Maxstats", "Char.MaxStats" })
    if type(m) == "table" then
        ch.maxhp    = tonumber(m.maxhp)
        ch.maxmana  = tonumber(m.maxmana)
        ch.maxmoves = tonumber(m.maxmoves)
    end

    local s = gmcp_get({ "char.status", "Char.Status" })
    if type(s) == "table" then
        ch.enemy    = s.enemy
        ch.enemypct = tonumber(s.enemypct)
        ch.state    = tonumber(s.state)
    end
end

local function refresh()
    pull()
    -- the backup is only written on save, so a fresh install has none until
    -- you happen to change something. Write it once, now.
    save_cfg()

    apply_visibility()
    render_vitals()
    render_target()
end

function init()
    --[[
        Declare the GMCP we need. Core owns Core.Supports.Set — it replaces
        the server's record rather than merging, so only one plugin may send
        it — and builds the union from these. Needs: char.base, vitals, maxstats, status.
    ]]
    broadcastPlugin("aw-gmcp", "Char")

    --[[
        Kept well inside a small window on purpose. The first cut sat these at
        y=900 to match the reference screenshot and they landed below the fold
        on a shorter window — a widget that exists but is off-screen looks
        exactly like a plugin that never loaded. Drag them where you want;
        MudForge remembers the position from then on.
    ]]
    vitals = createWidget({
        type     = "html",
        name     = "vitals",
        title    = "Live Vitals",
        position = { x = 420, y = 470 },
        size     = { width = 520, height = 108 },
    })

    target = createWidget({
        type     = "html",
        name     = "target",
        title    = "Target Focus",
        position = { x = 420, y = 590 },
        size     = { width = 400, height = 108 },
    })

    local saved = loadTable("aw_vitals")
    if type(saved) ~= "table" then saved = recall("aw_vitals") end
    if type(saved) == "table" then
        if saved.showTarget ~= nil then cfg.showTarget = saved.showTarget and true or false end
        if saved.pulse      ~= nil then cfg.pulse      = saved.pulse and true or false end
        if saved.showPct    ~= nil then cfg.showPct    = saved.showPct and true or false end
        if saved.autoTarget ~= nil then cfg.autoTarget = saved.autoTarget and true or false end
    end

    apply_visibility()

    registerWidgetEvent(vitals, "action", function(data)
        if type(data) ~= "table" then return end
        local act = tostring(data.action or "")

        if act == "view" then
            view = (tostring(data.data or "") == "settings") and "settings" or "panel"

        elseif act == "pulse" then
            cfg.pulse = not cfg.pulse

        elseif act == "pct" then
            cfg.showPct = not cfg.showPct

        elseif act == "target" then
            cfg.showTarget = not cfg.showTarget

        elseif act == "autotarget" then
            cfg.autoTarget = not cfg.autoTarget

        elseif act == "reset" then
            --[[
                Saved geometry can leave these under another panel — visible
                by every measure and impossible to see. Move, resize and raise.
            ]]
            for i, w in ipairs({ vitals, target }) do
                showWidget(w)
                moveWidget(w, 470, i == 1 and 120 or 250)
                resizeWidget(w, i == 1 and 520 or 470, i == 1 and 108 or 96)
                setWidgetZOrder(w, 2600 + i)
            end
            apply_visibility()

        else
            return
        end

        save_cfg()
        refresh()
    end)

    on_package({ "char.base",     "Char.Base" },                      refresh)
    on_package({ "char.vitals",   "Char.Vitals" },                    refresh)
    on_package({ "char.maxstats", "Char.Maxstats", "Char.MaxStats" }, refresh)
    on_package({ "char.status",   "Char.Status" },                    refresh)

    refresh()
end

--[[
    Rescue command. An off-screen widget is indistinguishable from a plugin
    that never loaded, so this reports where they actually are and drags them
    back to a known-visible spot.
]]
registerCommand("awvitals", function(args)
    local a   = argv(args)
    local arg = a[1] and string.lower(a[1]) or ""

    for _, w in ipairs({ { "vitals", vitals }, { "target", target } }) do
        local label, id = w[1], w[2]

        if not id then
            utilprint(TAGR .. "" .. label .. ": widget was never created")
        else
            --[[
                MudForge restores saved geometry per widget id, so these came
                back at 300x200 sitting at 200,150 — underneath the Character
                Info panel and behind it in z-order. Visible, reported as
                visible, and completely unseeable. Reset has to move, resize
                AND raise, not just move.
            ]]
            if arg == "reset" then
                local isVitals = (label == "vitals")

                showWidget(id)
                moveWidget(id, 470, isVitals and 120 or 250)
                resizeWidget(id, isVitals and 520 or 470, isVitals and 108 or 96)
                setWidgetZOrder(id, isVitals and 2600 or 2601)
            end

            utilprint(TAG .. "" .. label
                .. "  visible=" .. tostring(widgetInfo(id, 7))
                .. "  x=" .. tostring(widgetInfo(id, 15))
                .. "  y=" .. tostring(widgetInfo(id, 16))
                .. "  " .. tostring(widgetInfo(id, 3)) .. "x" .. tostring(widgetInfo(id, 4)))
        end
    end

    if arg ~= "reset" then
        utilprint("$w  /awvitals reset  to drag them back on screen")
    end
end, "Show where the vitals widgets are; '/awvitals reset' recentres them")

registerCommand("awtarget", function()
    utilprint(TAG .. "enemy=" .. tostring(str(ch.enemy))
        .. "  pct=" .. tostring(ch.enemypct)
        .. "  state=" .. tostring(ch.state) .. " (8 = fighting)")
end, "Show what the target panel is reading")
