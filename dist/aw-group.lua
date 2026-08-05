--[[
    aw-group.lua
    Sean Stoves (Solao) — 2026-08-04

    Group roster. Replaces MudForge's built-in group widget.

    Ungrouped, it shows you — an empty panel that says "not grouped" wastes
    the space it occupies, and your own bars are worth watching either way.

    Aardwolf's package is literally 'group' — not 'Group.Members' as the
    generic MudForge docs suggest — and it is OFF until something sends
    'group on' or puts "Group 1" in Core.Supports.Set. aw-core does both, so
    this panel needs Core enabled or it will sit empty forever.

    Member fields are abbreviated and differ from char.vitals:
      hp/mhp   mn/mmn   mv/mmv   align   tnl   lvl   here   qt/qs
    'here' is 1 when that member is in your room. qs is quest state:
      0 idle, 1 questing (qt = time left), 2 waiting (qt = cooldown), 3 mob.
]]

plugin = {
    id          = "aw-group",
    name        = "Aardwolf Group",
    version     = "1.2.1",
    author      = "Solao",
    description = "Group roster with per-member health, mana, moves and level. Shows you when ungrouped.",
    settings    = { saveState = true },
}

-- @category widgets

--[[
    Every diagnostic line carries the running version. Chasing a bug that
    was already fixed on disk cost several rounds — the output has to say
    which build is actually answering.
]]
local TAG  = "$Y[Group v" .. plugin.version .. "]$w "
local TAGR = "$R[Group v" .. plugin.version .. "]$w "

local widget = nil
local grp = {}

local cfg = { autoHide = false }   -- hide the panel entirely when ungrouped

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
    saveTable("aw_group", cfg)
    keep("aw_group", cfg)
end

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

--[[
    Command arguments, normalised to a 1-based list.

    Two shapes have to be handled. The runtime may hand over a table, and
    when it does the array is 0-indexed because it came from JavaScript — so
    args[1] is the SECOND word. It may also hand over the raw argument
    string, in which case indexing it yields characters, not words: reading
    args[1] off "sex male" gives "e", which is how '/avatar sex male' ended
    up trying to validate "e" as a URL.

    Split on whitespace by hand rather than with a pattern, since the string
    library runs on JS regex and Lua character classes don't survive it.
]]
local function argv(args)
    local out = {}

    if type(args) == "string" then
        local cur = ""
        for i = 1, string.len(args) do
            local c = string.sub(args, i, i)
            if c == " " or c == "	" then
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

local function str(v)
    if type(v) ~= "string" then return nil end
    if v == "" or v == "undefined" or v == "null" then return nil end
    return v
end

--[[
    GMCP arrays arrive from JavaScript, where they're 0-indexed, while Lua
    expects 1. Which one survives the transpiler isn't documented and we
    already got burned the other direction (a Lua array went out as
    {"1":...,"2":...} instead of a JSON array). So read from 0 upward, and
    fall back to ipairs if that finds nothing.
]]
local function each(list)
    local out = {}
    if type(list) ~= "table" then return out end

    local i = 0
    while list[i] ~= nil do
        table.insert(out, list[i])
        i = i + 1
    end

    if #out == 0 then
        for _, v in ipairs(list) do table.insert(out, v) end
    end

    return out
end

local function pct(cur, max)
    if type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then return 0 end
    local p = (cur / max) * 100
    if p < 0 then return 0 end
    if p > 100 then return 100 end
    return p
end

local function commas(n)
    if type(n) ~= "number" then return "--" end

    local s, out, count = tostring(math.floor(n)), "", 0
    for i = string.len(s), 1, -1 do
        out = string.sub(s, i, i) .. out
        count = count + 1
        if count % 3 == 0 and i > 1 then out = "," .. out end
    end
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

local CSS = [[
<style>
    .arc-gr {
        font-family: "JetBrains Mono", ui-monospace, monospace;
        color: hsl(var(--foreground, 35 34% 78%));
        padding: 10px;
        height: 100%;
        box-sizing: border-box;
        overflow-y: auto;
        background:
            radial-gradient(130% 120% at 20% -10%, rgba(147,25,24,0.14), transparent 62%),
            hsl(var(--card, 0 12% 8%));
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: var(--glass-radius, 4px);
    }
    .arc-gr .hd {
        display: flex; justify-content: space-between; align-items: baseline;
        font-size: 9px; letter-spacing: 0.2em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
        padding-bottom: 6px; margin-bottom: 9px;
    }
    .arc-gr .hd b {
        font-weight: normal; letter-spacing: 0.06em;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }

    .arc-gr .m {
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: 3px;
        padding: 6px 7px;
        margin-bottom: 6px;
        background: rgba(0,0,0,0.22);
    }
    .arc-gr .m:last-child { margin-bottom: 0; }
    .arc-gr .m.away { opacity: 0.5; }

    .arc-gr .mtop {
        display: flex; justify-content: space-between; align-items: baseline;
        margin-bottom: 5px;
    }
    .arc-gr .mn {
        font-size: 12px;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .arc-gr .mn .lead { color: hsl(var(--primary, 0 72% 42%)); }
    .arc-gr .mmeta {
        font-size: 8px; letter-spacing: 0.1em; text-transform: uppercase;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        white-space: nowrap; padding-left: 6px;
    }

    .arc-gr .b { position: relative; height: 6px; border-radius: 3px;
        background: rgba(0,0,0,0.6);
        border: 1px solid hsl(var(--border, 0 22% 17%));
        overflow: hidden; margin-bottom: 3px; }
    .arc-gr .b:last-child { margin-bottom: 0; }
    .arc-gr .b i { position: absolute; inset: 0 auto 0 0; border-radius: 3px 0 0 3px; display: block; }
    .arc-gr .b i.hp    { background: linear-gradient(90deg, #7d2429, #c0484e); }
    .arc-gr .b i.mana  { background: linear-gradient(90deg, #33507d, #6d8ec4); }
    .arc-gr .b i.moves { background: linear-gradient(90deg, #4c3579, #8a6bc0); }

    .arc-gr .empty {
        font-size: 10px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        text-align: center;
        padding: 14px 0;
    }
</style>
]]

local function bar(cur, max, class)
    return '<div class="b"><i class="' .. class .. '" style="width:'
        .. string.format("%.2f", pct(cur, max)) .. '%"></i></div>'
end

local function member(m, leader)
    local name = str(m.name) or "?"
    local i    = m.info or {}

    local lvl  = tonumber(i.lvl)
    local here = tonumber(i.here) == 1
    local qs   = tonumber(i.qs)

    local meta = {}
    if lvl then table.insert(meta, "L" .. lvl) end
    if type(tonumber(i.tnl)) == "number" then table.insert(meta, commas(tonumber(i.tnl)) .. " tnl") end
    if qs == 1 then table.insert(meta, "questing") end
    if not here then table.insert(meta, "away") end

    local tag = (name == leader) and '<span class="lead">&#9670;</span> ' or ''

    return '<div class="m' .. (here and '' or ' away') .. '">'
        .. '<div class="mtop"><div class="mn">' .. tag .. esc(name) .. '</div>'
        .. '<div class="mmeta">' .. table.concat(meta, " &middot; ") .. '</div></div>'
        .. bar(tonumber(i.hp), tonumber(i.mhp), "hp")
        .. bar(tonumber(i.mn), tonumber(i.mmn), "mana")
        .. bar(tonumber(i.mv), tonumber(i.mmv), "moves")
        .. '</div>'
end

--[[
    You, shaped like a group member.

    Aardwolf sends no 'group' package at all when you're solo, so the roster
    would otherwise sit empty. The abbreviations differ between the two
    sources — a member carries hp/mhp/mn/mmn/mv/mmv while char.vitals and
    char.maxstats split current from max across two packages — so this maps
    one onto the other rather than reusing either shape directly.
]]
local function solo_member()
    local b = gmcp_get({ "char.base", "Char.Base" })
    if type(b) ~= "table" then return nil end

    local v = gmcp_get({ "char.vitals", "Char.Vitals" })       or {}
    local m = gmcp_get({ "char.maxstats", "Char.Maxstats", "Char.MaxStats" }) or {}
    local t = gmcp_get({ "char.status", "Char.Status" })       or {}

    return {
        name = b.name,
        info = {
            hp  = tonumber(v.hp),    mhp  = tonumber(m.maxhp),
            mn  = tonumber(v.mana),  mmn  = tonumber(m.maxmana),
            mv  = tonumber(v.moves), mmv  = tonumber(m.maxmoves),
            lvl = tonumber(t.level) or tonumber(b.level),
            tnl = tonumber(t.tnl),
            here = 1,
        },
    }
end

local function render()
    if not widget then return end

    local members = each(grp.members)
    local leader  = str(grp.leader)
    local solo    = false

    if #members == 0 then
        local me = solo_member()
        if me then
            members = { me }
            solo    = true
        end
    end

    local body
    if #members == 0 then
        body = '<div class="empty">Waiting for character data</div>'
    else
        local rows = {}
        for _, m in ipairs(members) do
            if type(m) == "table" then table.insert(rows, member(m, leader)) end
        end
        body = table.concat(rows, "")
    end

    local right
    if solo then
        right = "solo"
    else
        right = str(grp.groupname) or (leader and ("led by " .. esc(leader))) or ""
        if #members > 0 then right = right .. " &middot; " .. #members end
    end

    setWidgetProperty(widget, "content", CSS
        .. '<div class="arc-gr">'
        .. '<div class="hd"><span>Group</span><b>' .. right .. '</b></div>'
        .. body
        .. '</div>')
end

local function pull()
    local g = gmcp_get({ "group", "Group" })
    if type(g) == "table" then
        grp.groupname = g.groupname
        grp.leader    = g.leader
        grp.status    = g.status
        grp.members   = g.members
    end
end

local function refresh()
    pull()
    render()

    --[[
        Opt-in. Off by default because a panel that disappears on its own is
        disorienting if you didn't ask for it — the solo row is usually the
        better answer than an empty frame or a vanishing one.
    ]]
    if widget and cfg.autoHide then
        if #each(grp.members) > 0 then showWidget(widget) else hideWidget(widget) end
    end
end

function init()
    --[[
        Declare the GMCP we need. Core owns Core.Supports.Set — it replaces
        the server's record rather than merging, so only one plugin may send
        it — and builds the union from these. Needs: the group package, plus char.* for the solo row.
    ]]
    broadcastPlugin("aw-gmcp", "Group,Char")

    widget = createWidget({
        type     = "html",
        name     = "group",
        title    = "Group",
        position = { x = 16, y = 440 },
        size     = { width = 344, height = 300 },
    })

    local saved = loadTable("aw_group")
    if type(saved) ~= "table" then saved = recall("aw_group") end
    if type(saved) == "table" and saved.autoHide ~= nil then
        cfg.autoHide = saved.autoHide and true or false
    end

    -- the backup is only written on save, so a fresh install has none until
    -- you happen to change something. Write it once, now.
    save_cfg()

    on_package({ "group", "Group" }, refresh)

    -- solo rows come from char.*, so those have to redraw the panel too
    on_package({ "char.vitals",   "Char.Vitals" },                    refresh)
    on_package({ "char.maxstats", "Char.Maxstats", "Char.MaxStats" }, refresh)
    on_package({ "char.base",     "Char.Base" },                      refresh)
    refresh()
end

registerCommand("awgroup", function(args)
    local a = argv(args)

    if a[1] and string.lower(a[1]) == "autohide" then
        cfg.autoHide = not cfg.autoHide
        save_cfg()
        if not cfg.autoHide then showWidget(widget) end
        refresh()
        utilprint(TAG .. "auto-hide when ungrouped: " .. (cfg.autoHide and "on" or "off"))
        return
    end

    local g = gmcp_get({ "group", "Group" })
    if not g then
        utilprint(TAGR .. "no group package yet — is Aardwolf Core enabled? It sends 'group on'.")
        return
    end

    utilprint(TAG .. "" .. #each(g.members) .. " member(s) parsed from the raw payload:")
    tprint(g)
end, "Dump the raw group GMCP payload")
