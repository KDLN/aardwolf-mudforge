--[[
    aw-portrait.lua
    Sean Stoves (Solao) — 2026-08-03

    Character Info — one panel: portrait, identity, experience progress, the
    full stat grid, and alignment.

    Everything comes from GMCP, spread over five packages:
      char.base      name, race, class, subclass, level, tier, perlevel
      char.status    level, tnl, align, pos, state
      char.vitals    hp, mana, moves            (current only)
      char.maxstats  maxhp/maxmana/maxmoves + per-stat ceilings
      char.stats     str, int, wis, dex, con, luck, hr, dr, saves

    Portrait defaults to a generated race/class template picked from char.base;
    '/avatar <url>' overrides it with the player's own.
]]

plugin = {
    id          = "aw-portrait",
    name        = "Aardwolf Character Info",
    version     = "1.11.1",
    author      = "Solao",
    description = "Character panel: portrait, level, stat grid, vitals, alignment and experience to level.",
    settings    = { saveState = true },
}

-- @category widgets

--[[
    Every diagnostic line carries the running version. Chasing a bug that
    was already fixed on disk cost several rounds — the output has to say
    which build is actually answering.
]]
local TAG  = "$Y[Portrait v" .. plugin.version .. "]$w "
local TAGR = "$R[Portrait v" .. plugin.version .. "]$w "

local RAW_BASE    = "https://raw.githubusercontent.com/SeanStoves/aardwolf-mudforge/main/dist/img"
local AVATAR_BASE = RAW_BASE .. "/icons/avatars"
local FRAME_BASE  = RAW_BASE .. "/frames"

--[[
    Aardwolf alignment, confirmed in game:
         875 .. 2500  Good
        -874 .. 874   Neutral
       -2500 .. -875  Evil
]]
local ALIGN_MAX     = 2500
local ALIGN_NEUTRAL = 875

--[[
    The blank portrait is baked into the icons library as a data URI so there
    is always something to draw. DOMPurify strips inline onerror, so there is
    no JS hook for a failed image load — instead the portrait is a div with
    two stacked background layers. If the remote race/class art 404s, nothing
    paints on the top layer and the blank underneath shows through.
]]
local blank = nil
do
    local ok, icons = pcall(require, "arcanum-icons")
    if ok and type(icons) == "table" then
        blank = icons["icons/avatars/generic"]
    end
end

--[[
    Aardwolf doesn't always send char.base.class — a level 181 Blacksmith came
    through with race and subclass set but class missing. Subclasses map onto
    exactly one primary class, so derive it rather than showing "undefined".
    This also fixes the avatar lookup, which keys on race + primary class.
]]
local SUBCLASS_CLASS = {
    elementalist = "Mage",    enchanter = "Mage",    sorcerer   = "Mage",
    priest       = "Cleric",  oracle    = "Cleric",  harmer     = "Cleric",
    ninja        = "Thief",   bandit    = "Thief",   venomist   = "Thief",
    barbarian    = "Warrior", soldier   = "Warrior", blacksmith = "Warrior",
    shaman       = "Ranger",  hunter    = "Ranger",  crafter    = "Ranger",
    guardian     = "Paladin", knight    = "Paladin", avenger    = "Paladin",
    mentalist    = "Psionicist", navigator = "Psionicist", necromancer = "Psionicist",
}

local widget = nil
local view   = "panel"   -- "panel" | "settings"
local ch = {}

--[[
    Portrait frame, driven by progression.

    char.base carries tier, remorts and redos, so the ring can say something
    about the character rather than being decoration. Remorts set the metal;
    tier adds an outer ring and lifts the glow; redos add a bright inner
    hairline. A fresh character gets plain iron and nothing else, so the
    ornamentation is earned rather than default.

    Colours live in a generated <style> rule — inline style attributes lose
    colour to the sanitiser, which is what left the alignment scale grey.
]]
--[[
    Indexed by remorts COMPLETED, which is char.base.remorts minus one —
    Aardwolf reports an unremorted character as remorts = 1, not 0. Reading
    the field directly would hand every newbie a bronze frame.
]]
local REMORT_METAL = {
    [0] = { "#6f665c", "iron" },
    [1] = { "#a9713f", "bronze" },
    [2] = { "#9aa0a6", "steel" },
    [3] = { "#c9a227", "gold" },
    [4] = { "#57b7c4", "aquamarine" },
    [5] = { "#7d5ac2", "amethyst" },
    [6] = { "#c4574f", "garnet" },
    [7] = { "#3fa96b", "emerald" },
    [8] = { "#d1d5db", "platinum" },
    [9] = { "#e8c84c", "solar" },
}

local function frame_rank()
    local r = tonumber(ch.remorts)
    if type(r) ~= "number" then return 0 end

    r = math.floor(r) - 1          -- remorts completed
    if r < 0 then return 0 end
    if r > 9 then return 9 end
    return r
end

local PALETTES = {
    { id = "",          name = "Classic" },   -- cyan / yellow / red
    { id = "p-verdant", name = "Verdant" },
    { id = "p-frost",   name = "Frost" },
    { id = "p-ember",   name = "Ember" },
}

local cfg = {
    avatar  = nil,   -- custom URL, per character
    sex     = nil,   -- portrait variant, per character
    palette = "",
    sizeW   = nil,   -- flat, never nested: see the note in init()
    sizeH   = nil,
}

local who = nil      -- character cfg.avatar and cfg.sex belong to; nil until char.base names us

-- pre-1.10 kept one avatar for everybody. Adopted by the first character we
-- see and then dropped; see load_char().
local legacy = { avatar = nil, sex = nil }

--[[
    Settings that survive a reinstall.

    saveTable is scoped to the plugin, and removing a plugin takes its rows
    with it — which is exactly how every update to these plugins is installed.
    A world variable isn't tied to the plugin, so it comes through. That matters
    most here: a custom avatar is something you chose, not something derivable.

    saveTable stays as the fast path; this is the copy that actually persists,
    and load falls back to it.
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

--[[
    Two tables, because they have two different lifetimes.

    saveTable is keyed on (plugin_id, table_name) and nothing else — no
    profile, no character, one row shared by the lot. That's straight off
    plugin_tables.db, not a guess. So a custom avatar set on one alt turned up
    on all of them, and the character has to go in the table NAME or nothing
    changes.

    Only what's actually about the character goes in the per-character row:
    the uploaded avatar and the sex override. Everything else is a UI
    preference and stays shared. The default portrait is derived from char.base
    on every render and stores nothing at all, so an alt you've never set an
    avatar for needs no row.
]]
local function save_cfg()
    local prefs = { palette = cfg.palette, sizeW = cfg.sizeW, sizeH = cfg.sizeH }
    saveTable("aw_portrait", prefs)
    keep("aw_portrait", prefs)

    if who then
        local mine = { avatar = cfg.avatar, sex = cfg.sex }
        saveTable("aw_portrait_" .. who, mine)
        keep("aw_portrait_" .. who, mine)
    end
end

--[[
    Takes a table, NOT varargs. MudForge transpiles Lua to JavaScript instead
    of running a VM, and `{...}` vararg packing doesn't survive the trip — the
    loop still runs but every name arrives undefined, so getGMCPData blows up
    on e.split("."). Cost an hour to find; don't reintroduce varargs anywhere.
]]
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

-- Manual grouping — MudForge's string library runs on JS regex, so the usual
-- Lua "%d%d%d" gsub trick isn't worth trusting here.
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

--[[
    JS undefined leaks through the transpiler as the literal string
    "undefined" rather than becoming nil, so `x or ""` never fires and the
    panel cheerfully renders "SPRITE UNDEFINED". Launder every string that
    comes off a GMCP table through this.
]]
local function str(v)
    if type(v) ~= "string" then return nil end
    if v == "" or v == "undefined" or v == "null" then return nil end
    return v
end

-- Primary class, falling back to whatever the subclass implies.
local function class_of()
    local c = str(ch.class)
    if c then return c end

    local sub = str(ch.subclass)
    if sub then return SUBCLASS_CLASS[string.lower(sub)] end

    return nil
end

--[[
    Command arguments arrive from JavaScript, where arrays start at 0, while
    Lua expects 1. '/avatar sex male' handed us args[1] = "male" — the second
    word — so the sex branch never matched and the command fell through to
    URL validation complaining about "male". Same 0-vs-1 trap as GMCP arrays.
    Normalise to a proper 1-based list before reading anything.
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

local function slug(s)
    if type(s) ~= "string" then return "" end
    return string.gsub(string.lower(s), " ", "-")
end

--[[
    Swap in this character's avatar and sex override, and swap again if the
    name changes — quitting to the login and coming back as an alt is one
    session, and the panel would otherwise keep wearing the last one's face.

    Called from pull(), so it runs as soon as char.base names us.
]]
local function load_char()
    local key = slug(str(ch.name) or "")
    if key == "" or key == who then return end

    who = key
    cfg.avatar, cfg.sex = nil, nil

    local saved = loadTable("aw_portrait_" .. key)
    if type(saved) ~= "table" then saved = recall("aw_portrait_" .. key) end

    if type(saved) == "table" then
        if str(saved.avatar) then cfg.avatar = saved.avatar end
        if saved.sex == "m" or saved.sex == "f" then cfg.sex = saved.sex end

    elseif legacy.avatar ~= nil or legacy.sex ~= nil then
        -- hand the old shared avatar to whoever logs in first and drop it,
        -- rather than painting it onto every alt in turn
        cfg.avatar, cfg.sex = legacy.avatar, legacy.sex
        legacy.avatar, legacy.sex = nil, nil
        save_cfg()
    end
end

local function esc(s)
    if type(s) ~= "string" then return "" end
    s = string.gsub(s, "&", "&amp;")
    s = string.gsub(s, "<", "&lt;")
    s = string.gsub(s, ">", "&gt;")
    s = string.gsub(s, '"', "&quot;")
    return s
end

--[[
    Portrait variant. Aardwolf's char.base carries no gender field at all —
    name, class, subclass, race, clan, pretitle, perlevel, tier, remorts,
    redos, classes, level, pups, totpups and nothing else — so this can't be
    detected and has to be chosen. '/avatar sex m|f' sets it, and it's
    remembered per character.
]]
--[[
    Frame classes, from progression. Remorts pick the metal (.m0-.m9), tier
    adds the outer ring, redos add the inner hairline — all static rules, so
    this only chooses names. Also returns a description for /awchar and the
    settings pane.
]]
local function frame_classes()
    local rank  = frame_rank()
    local tier  = tonumber(ch.tier) or 0
    local redos = tonumber(ch.redos) or 0

    local cls = { "m" .. rank }
    if tier > 0 then table.insert(cls, "tier") end
    if redos > 0 then table.insert(cls, "redo") end

    local desc = REMORT_METAL[rank][2]
    if rank > 0 then desc = desc .. " x" .. rank end
    if tier > 0 then desc = desc .. ", tier " .. tier end
    if redos > 0 then desc = desc .. ", " .. redos .. " redo" .. (redos > 1 and "s" or "") end

    return table.concat(cls, " "), desc
end

local function avatar_url()
    if cfg.avatar and cfg.avatar ~= "" then return cfg.avatar end

    local race  = slug(str(ch.race) or "")
    local class = slug(class_of() or "")
    local sex   = (cfg.sex == "m" or cfg.sex == "f") and cfg.sex or nil

    if race ~= "" and class ~= "" and sex then
        return AVATAR_BASE .. "/" .. race .. "-" .. class .. "-" .. sex .. ".png"
    end

    if race ~= "" and class ~= "" then
        return AVATAR_BASE .. "/" .. race .. "-" .. class .. ".png"
    end

    return AVATAR_BASE .. "/generic.png"
end

local CSS = [[
    .arc-port {
        position: relative;
        font-family: "JetBrains Mono", ui-monospace, monospace;
        color: hsl(var(--foreground, 35 34% 78%));
        padding: 11px;
        height: 100%;
        box-sizing: border-box;
        overflow: hidden;
        background:
            radial-gradient(130% 120% at 22% -10%, rgba(147,25,24,0.16), transparent 62%),
            hsl(var(--card, 0 12% 8%));
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: var(--glass-radius, 4px);
    }

    .arc-port .head { display: flex; gap: 12px; align-items: center; }
    /*
       Frame and alignment colours are driven ENTIRELY by static classes plus
       currentColor — no generated CSS. Rules emitted in a second <style>
       element never applied, and neither did colour in an inline style
       attribute, so both of those routes are dead. Class names on markup do
       work, so the palette is enumerated here and the Lua only picks a class.
    */
    /*
       The frame is artwork laid over the portrait, so the slot is bigger than
       the picture: the avatar fills the ring's opening and the ring itself
       overhangs it. Colour classes below stay as the fallback for a rank
       whose frame image hasn't loaded.
    */
    .arc-port .slot {
        position: relative;
        flex: none;
        width: 78px; height: 78px;
    }
    .arc-port .face {
        position: absolute;
        left: 9px; top: 9px;                   /* centred in the 78px slot */
        width: 60px; height: 60px;
        border-radius: 50%;
        overflow: hidden;
        color: #6f665c;                        /* metal, overridden by .mN */
        background-color: rgba(0,0,0,0.5);
        box-shadow: 0 0 10px currentColor;
    }
    .arc-port .ring {
        position: absolute; inset: 0;
        background-size: contain;
        background-position: center;
        background-repeat: no-repeat;
        pointer-events: none;
    }
    /* no frame art yet: fall back to the coloured ring so the rank still reads */
    .arc-port .slot.noart .face {
        border: 2px solid currentColor;
        box-shadow: 0 0 0 1px rgba(0,0,0,0.85), 0 0 14px currentColor;
    }
    .arc-port .slot.m0 { color: #6f665c; }     /* iron — unremorted */
    .arc-port .slot.m1 { color: #a9713f; }     /* bronze */
    .arc-port .slot.m2 { color: #9aa0a6; }     /* steel */
    .arc-port .slot.m3 { color: #c9a227; }     /* gold */
    .arc-port .slot.m4 { color: #57b7c4; }     /* aquamarine */
    .arc-port .slot.m5 { color: #7d5ac2; }     /* amethyst */
    .arc-port .slot.m6 { color: #c4574f; }     /* garnet */
    .arc-port .slot.m7 { color: #3fa96b; }     /* emerald */
    .arc-port .slot.m8 { color: #d1d5db; }     /* platinum */
    .arc-port .slot.m9 { color: #e8c84c; }     /* solar */

    /* tier adds an outer ring and a stronger glow, in the same metal */
    /* tier lifts the whole frame with a halo behind the art */
    .arc-port .slot.tier .ring {
        filter: drop-shadow(0 0 6px currentColor) drop-shadow(0 0 12px currentColor);
    }
    /* redos add a bright hairline just inside the ring */
    .arc-port .slot.redo .face {
        outline: 1px solid currentColor;
        outline-offset: -1px;
    }
    /* the background-image layers are generated per render: remote art on
       top of the embedded blank, so a 404 falls through instead of drawing a
       broken-image placeholder */
    .arc-port .face {
        background-size: cover;
        background-position: center top;
        background-repeat: no-repeat;
    }
    .arc-port .who { min-width: 0; flex: 1; padding-right: 26px; }
    .arc-port .nm {
        font-size: 19px;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .arc-port .sub {
        font-size: 9px; letter-spacing: 0.16em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        margin-top: 4px;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .arc-port .coin {
        font-size: 10px; letter-spacing: 0.04em;
        color: #d7a63c;
        margin-top: 3px;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .arc-port .sub2 {
        font-size: 9px; letter-spacing: 0.06em;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        margin-top: 3px;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }

    /* experience box */
    .arc-port .xp {
        margin-top: 11px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: 3px;
        padding: 7px 8px;
        background: rgba(0,0,0,0.25);
    }
    .arc-port .xp .lbl {
        display: flex; justify-content: space-between; align-items: baseline;
        font-size: 8px; letter-spacing: 0.16em; text-transform: uppercase;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        margin-bottom: 5px;
    }
    .arc-port .xp .lbl b {
        font-weight: normal; letter-spacing: 0.06em;
        color: hsl(var(--primary, 0 72% 42%));
    }
    .arc-port .track {
        position: relative; height: 13px;
        border-radius: 7px;
        background: rgba(0,0,0,0.6);
        border: 1px solid hsl(var(--border, 0 22% 17%));
        overflow: hidden;
    }
    .arc-port .fill {
        position: absolute; inset: 0 auto 0 0;
        border-radius: 7px 0 0 7px;
        transition: width .2s ease-out;
        background: linear-gradient(90deg, #8a6a20, #d7a63c 70%, #f0cf7a);
    }

    /* stat grid */
    .arc-port .grid {
        margin-top: 10px;
        display: grid;
        grid-template-columns: repeat(4, 1fr);
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: 3px;
        overflow: hidden;
        background: rgba(0,0,0,0.22);
    }
    .arc-port .cell {
        padding: 4px 4px 5px;
        border-right: 1px solid hsl(var(--border, 0 22% 17%));
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
        min-width: 0;
    }
    .arc-port .cell:nth-child(4n) { border-right: none; }

    /* worth is three across, and the trailing cell is a spacer */
    .arc-port .grid.worth {
        grid-template-columns: repeat(3, 1fr);
        margin-top: 7px;
    }
    .arc-port .grid.worth .cell:nth-child(4n) { border-right: 1px solid hsl(var(--border, 0 22% 17%)); }
    .arc-port .grid.worth .cell:nth-child(3n) { border-right: none; }
    .arc-port .cell.lastrow { border-bottom: none; }
    .arc-port .cell .k {
        font-size: 7px; letter-spacing: 0.13em; text-transform: uppercase;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .arc-port .cell .v {
        font-size: 11px; margin-top: 3px;
        color: hsl(var(--foreground, 35 34% 78%));
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
        font-variant-numeric: tabular-nums;
    }
    .arc-port .cell .v .sl {
        color: hsl(var(--muted-foreground, 35 14% 52%));
        margin: 0 1px;
    }
    .arc-port .cell .v.dim { color: hsl(var(--muted-foreground, 35 14% 52%)); }

    /* alignment scale */
    .arc-port .align { margin-top: 10px; }
    .arc-port .align .cap {
        display: flex; justify-content: space-between;
        font-size: 8px; letter-spacing: 0.16em; text-transform: uppercase;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-port .align .cap b { font-weight: normal; letter-spacing: 0.06em; }
    .arc-port .align .scale { position: relative; height: 13px; margin: 3px 6px 0; }
    .arc-port .align .rule {
        position: absolute; left: 0; right: 0; top: 50%;
        height: 3px; margin-top: -1.5px; opacity: 0.6;
        border-radius: 2px;
        background: linear-gradient(90deg, #d4453f 0%, #e8c84c 50%, #3fd6d6 100%);
    }
    .arc-port .align .tick {
        position: absolute; top: 1px; bottom: 1px; width: 1px;
        background: hsl(var(--muted-foreground, 35 14% 52%));
        opacity: 0.8;
    }
    .arc-port .align .knob {
        position: absolute; top: 50%;
        width: 9px; height: 9px; margin: -4.5px 0 0 -4.5px;
        border-radius: 50%;
        border: 1px solid rgba(0,0,0,0.75);
        transition: left .2s ease-out;
        color: #e8c84c;
        background: currentColor;
        box-shadow: 0 0 8px currentColor;
    }
    /*
       Alignment palettes are static classes on the .align container. Colour
       cannot be generated at runtime here — inline colour and second <style>
       elements are both discarded — so the choices are enumerated instead.
    */
    .arc-port .align .knob.good    { color: #3fd6d6; }
    .arc-port .align .knob.neutral { color: #e8c84c; }
    .arc-port .align .knob.evil    { color: #d4453f; }

    .arc-port .align.p-verdant .knob.good    { color: #86c48f; }
    .arc-port .align.p-verdant .knob.neutral { color: #e8c84c; }
    .arc-port .align.p-verdant .knob.evil    { color: #d4453f; }
    .arc-port .align.p-verdant .rule {
        background: linear-gradient(90deg, #d4453f 0%, #e8c84c 50%, #86c48f 100%); }
    .arc-port .align.p-verdant .tier.good { color: #86c48f; }

    .arc-port .align.p-frost .knob.good    { color: #6f9bd1; }
    .arc-port .align.p-frost .knob.neutral { color: #9a8d7e; }
    .arc-port .align.p-frost .knob.evil    { color: #c0392f; }
    .arc-port .align.p-frost .rule {
        background: linear-gradient(90deg, #c0392f 0%, #9a8d7e 50%, #6f9bd1 100%); }
    .arc-port .align.p-frost .tier.good    { color: #6f9bd1; }
    .arc-port .align.p-frost .tier.neutral { color: #9a8d7e; }

    .arc-port .align.p-ember .knob.good    { color: #e8bf5c; }
    .arc-port .align.p-ember .knob.neutral { color: #e8a33d; }
    .arc-port .align.p-ember .knob.evil    { color: #8f2b2f; }
    .arc-port .align.p-ember .rule {
        background: linear-gradient(90deg, #8f2b2f 0%, #e8a33d 50%, #e8bf5c 100%); }
    .arc-port .align.p-ember .tier.good    { color: #e8bf5c; }
    .arc-port .align.p-ember .tier.neutral { color: #e8a33d; }
    .arc-port .align.p-ember .tier.evil    { color: #8f2b2f; }

    /* settings pane */
    .arc-port .set { padding: 2px 0 0; }
    .arc-port .sec {
        font-size: 8px; letter-spacing: 0.18em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        margin: 11px 0 5px; padding-bottom: 4px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-port .sec:first-child { margin-top: 0; }
    .arc-port .chips { display: flex; flex-wrap: wrap; gap: 4px; }
    .arc-port .chip {
        font-size: 8px; letter-spacing: 0.1em; text-transform: uppercase;
        padding: 3px 7px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer; white-space: nowrap; user-select: none;
    }
    .arc-port .chip:hover { color: hsl(var(--foreground, 35 34% 78%)); }
    .arc-port .chip.on {
        color: hsl(var(--primary, 0 72% 42%));
        border-color: hsl(var(--primary, 0 72% 42%));
        background: rgba(147,25,24,0.14);
    }
    .arc-port form { display: flex; gap: 5px; margin-top: 6px; }
    .arc-port input[type=text] {
        flex: 1; min-width: 0;
        background: rgba(0,0,0,0.45);
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: 2px;
        color: hsl(var(--foreground, 35 34% 78%));
        font-family: inherit; font-size: 10px; padding: 3px 6px;
    }
    .arc-port input[type=text]:focus {
        outline: none; border-color: hsl(var(--primary, 0 72% 42%));
    }
    .arc-port button {
        font-family: inherit;
        font-size: 8px; letter-spacing: 0.12em; text-transform: uppercase;
        padding: 4px 9px; border-radius: 2px;
        background: rgba(147,25,24,0.16);
        border: 1px solid hsl(var(--primary, 0 72% 42%));
        color: hsl(var(--primary, 0 72% 42%));
        cursor: pointer;
    }
    .arc-port button:hover { background: rgba(147,25,24,0.3); }
    /*
       Top right, pinned. In the flow it landed under the alignment scale and
       fell off the bottom of a short panel; floating at the bottom it sat on
       the scale's end labels. Up here the header has spare room beside the
       name, and .who reserves space so nothing runs under it.
    */
    .arc-port .gear {
        position: absolute; top: 10px; right: 11px;
        font-size: 9px; padding: 2px 6px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer; user-select: none;
    }
    .arc-port .gear:hover { color: hsl(var(--primary, 0 72% 42%)); }
    .arc-port .note {
        font-size: 9px; line-height: 1.5; margin-top: 8px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }

    /* depth into the tier, as a brightness ramp — dim at a boundary, full at
       the extreme, so crossing a tier reads as a hue change not a jump */
    .arc-port .align .knob.d0 { filter: brightness(0.55); }
    .arc-port .align .knob.d1 { filter: brightness(0.70); }
    .arc-port .align .knob.d2 { filter: brightness(0.85); }
    .arc-port .align .knob.d3 { filter: brightness(1.00); }
    .arc-port .align .knob.d4 { filter: brightness(1.15); }

    .arc-port .align .tier.good    { color: #3fd6d6; }
    .arc-port .align .tier.neutral { color: #e8c84c; }
    .arc-port .align .tier.evil    { color: #d4453f; }
    .arc-port .align .ends {
        display: flex; justify-content: space-between;
        font-size: 7px; letter-spacing: 0.1em; text-transform: uppercase;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        opacity: 0.7;
        margin: 1px 2px 0;
    }
]]

--[[
    Which tier, and how deep into it — 0 at the boundary, 1 at the extreme.
    Neutral inverts: deepest at true zero, fading as it approaches either
    boundary, so a character about to tip Good or Evil looks like it.
]]
local function align_tier(a)
    local span = ALIGN_MAX - ALIGN_NEUTRAL

    if a >= ALIGN_NEUTRAL then
        return "good", "Good", math.min((a - ALIGN_NEUTRAL) / span, 1)
    end

    if a <= -ALIGN_NEUTRAL then
        return "evil", "Evil", math.min((-a - ALIGN_NEUTRAL) / span, 1)
    end

    return "neutral", "Neutral", 1 - (math.abs(a) / ALIGN_NEUTRAL)
end

local function align_row()
    local a = ch.align

    local ticks = ''
    for _, at in ipairs({ -ALIGN_NEUTRAL, ALIGN_NEUTRAL }) do
        local p = (at + ALIGN_MAX) / (ALIGN_MAX * 2) * 100
        ticks = ticks .. '<div class="tick" style="left:' .. string.format("%.2f", p) .. '%"></div>'
    end

    --[[
        Only geometry goes inline; colour comes from classes. Inline colour
        and runtime-generated <style> rules are both discarded here, so the
        tier and its depth bucket select from static rules instead.
    ]]
    local knob, right = '', '--'

    if type(a) == "number" then
        local clamped = a
        if clamped >  ALIGN_MAX then clamped =  ALIGN_MAX end
        if clamped < -ALIGN_MAX then clamped = -ALIGN_MAX end

        local pos = (clamped + ALIGN_MAX) / (ALIGN_MAX * 2) * 100
        local cls, label, depth = align_tier(clamped)
        -- depth bucketed to the five static brightness classes
        local d = math.floor(depth * 4 + 0.5)
        if d < 0 then d = 0 end
        if d > 4 then d = 4 end

        knob  = '<div class="knob ' .. cls .. ' d' .. d .. '" style="left:'
            .. string.format("%.2f", pos) .. '%"></div>'
        right = '<span class="tier ' .. cls .. '">' .. label .. '</span> &middot; ' .. commas(a)
    end

    local pal = str(cfg.palette)
    return '<div class="align' .. (pal and (' ' .. pal) or '') .. '">'
        .. '<div class="cap"><span>Alignment</span><b>' .. right .. '</b></div>'
        .. '<div class="scale"><div class="rule"></div>' .. ticks .. knob .. '</div>'
        .. '<div class="ends"><span>Evil</span><span>Neutral</span><span>Good</span></div>'
        .. '</div>'
end

local function cell(key, value, lastrow, dim)
    return '<div class="cell' .. (lastrow and ' lastrow' or '') .. '">'
        .. '<div class="k">' .. key .. '</div>'
        .. '<div class="v' .. (dim and ' dim' or '') .. '">' .. value .. '</div>'
        .. '</div>'
end

--[[
    One number per cell, not a pair.

    A quarter-width cell can't hold "5,658/5,658" at a readable size — it
    ellipsised to "5,658/5…" and lost the half that mattered. Which half to
    keep differs by row:

      stats (str, dex, …)  current, because gear pushes it past the trainable
                           max and the effective value is what you play with
      pools (hp, mana, …)  max, because Live Vitals already gauges current
                           against it and the ceiling is the character fact
]]
local function cur(v)
    if type(v) == "number" then return commas(v) end
    return "--"
end

local function cap(current, max)
    if type(max) == "number" then return commas(max) end
    if type(current) == "number" then return commas(current) end
    return "--"
end

local function signed(n)
    if type(n) ~= "number" then return "--" end
    if n >= 0 then return "+" .. commas(n) end
    return commas(n)
end

--[[
    Experience counts DOWN toward the level, so the bar is inverted to fill
    UP: perlevel is the level's total, tnl is what's left, progress is the
    difference. char.base.perlevel is the only denominator Aardwolf gives —
    without it the bar stays empty and only the countdown shows, rather than
    inventing a ratio.
]]
local function xp_box()
    local per, left = ch.perlevel, ch.tnl
    local right, done = "--", 0

    if type(left) == "number" then
        if type(per) == "number" and per > 0 then
            done  = pct(per - left, per)
            right = commas(per - left) .. " / " .. commas(per)
        else
            right = commas(left) .. " to go"
        end
    end

    return '<div class="xp">'
        .. '<div class="lbl"><span>Experience &mdash; TNL ' .. commas(left) .. '</span><b>' .. right .. '</b></div>'
        .. '<div class="track"><div class="fill" style="width:' .. string.format("%.2f", done) .. '%"></div></div>'
        .. '</div>'
end

local function chip(action, data, label, on)
    return '<div class="chip' .. (on and ' on' or '') .. '"'
        .. ' data-mud-action="' .. action .. '" data-mud-data="' .. esc(data) .. '">'
        .. esc(label) .. '</div>'
end

local function render_settings()
    local sex = str(cfg.sex)

    local body = '<div class="sec">Portrait</div><div class="chips">'
        .. chip("sex", "m",     "male",   sex == "m")
        .. chip("sex", "f",     "female", sex == "f")
        .. chip("sex", "clear", "unisex", sex == nil)
        .. '</div>'

    body = body .. '<div class="note">Using: ' .. esc(avatar_url()) .. '</div>'
        .. '<form>'
        .. '<input type="hidden" name="op" value="avatar">'
        .. '<input type="text" name="url" placeholder="https:// or data:image/ for your own" autocomplete="off">'
        .. '<button type="submit">Set</button>'
        .. '</form>'
        .. '<div class="chips" style="margin-top:6px">'
        .. chip("avatarclear", "1", "back to template", false)
        .. '</div>'

    body = body .. '<div class="sec">Alignment palette</div><div class="chips">'
    for _, p in ipairs(PALETTES) do
        body = body .. chip("palette", p.id, p.name, (str(cfg.palette) or "") == p.id)
    end
    body = body .. '</div>'

    local _, frameDesc = frame_classes()
    body = body .. '<div class="sec">Frame</div>'
        .. '<div class="note">' .. esc(frameDesc) .. ' &mdash; set by remorts, tier and redos, '
        .. 'so it changes as the character does.</div>'

    body = body .. '<div class="sec">Panel</div><div class="chips">'
        .. chip("pinsize", "1", "pin current size", false)
        .. '</div>'
        .. '<div class="note">Pins the size this panel opens at on a fresh profile.</div>'

    return body
end

local function render()
    if not widget then return end

    local name = esc(str(ch.name) or "Unknown")
    local lvl  = ch.level and ("Lv. " .. ch.level) or "Lv. --"

    local bits = {}
    if str(ch.race) then table.insert(bits, esc(str(ch.race))) end
    if class_of()   then table.insert(bits, esc(class_of())) end
    local kind = table.concat(bits, " ")

    local line2 = {}
    if str(ch.subclass) then table.insert(line2, esc(str(ch.subclass))) end
    if str(ch.pos) then table.insert(line2, esc(str(ch.pos))) end
    if ch.tier and ch.tier ~= 0 then table.insert(line2, "Tier " .. ch.tier) end

    -- gold gets its own line: on the identity line it was the first thing to
    -- be ellipsised away, and it's worth reading at a glance
    local coin = ""
    if type(ch.gold) == "number" then
        coin = '<div class="coin">' .. commas(ch.gold) .. ' gold</div>'
    end

    --[[
        Short labels on purpose. "CONSTITUTION" ellipsised to "CONSTITUTI…"
        in a quarter-width cell, and the space it stole pushed six-figure
        values like 5,658/5,658 into "5,658/5…" — losing the half of the pair
        that matters. STR/CON/HR is how the MUD says it anyway.
    ]]
    local grid = '<div class="grid">'
        .. cell("Str",   cur(ch.str), false)
        .. cell("Int",   cur(ch.int), false)
        .. cell("Wis",   cur(ch.wis), false)
        .. cell("Dex",   cur(ch.dex), false)
        .. cell("Con",   cur(ch.con), false)
        .. cell("Luck",  cur(ch.luck), false)
        .. cell("Hit",   signed(ch.hr), false)
        .. cell("Dam",   signed(ch.dr), false)
        .. cell("Saves", signed(ch.saves), true, true)
        -- values are the maxima; the label doesn't need to say so
        .. cell("Health", cap(ch.hp, ch.maxhp), true)
        .. cell("Mana",   cap(ch.mana, ch.maxmana), true)
        .. cell("Move",   cap(ch.moves, ch.maxmoves), true)
        .. '</div>'

    --[[
        Worth on its own three-wide grid rather than crammed into the stat
        block: these are the spendable resources and they're read together,
        not against str and dex.
    ]]
    local worth = '<div class="grid worth">'
        .. cell("Bank",   cur(ch.bank), false)
        .. cell("QP",     cur(ch.qp), false)
        .. cell("TP",     cur(ch.tp), false)
        .. cell("Trains", cur(ch.trains), true)
        .. cell("Pracs",  cur(ch.pracs), true)
        .. '<div class="cell lastrow"></div>'
        .. '</div>'

    --[[
        ONE <style> element for everything.

        Extra <style> blocks emitted alongside the first had no effect — the
        frame colour and the whole alignment scale rendered unstyled while
        the original block applied fine. So every generated rule is
        concatenated into the same stylesheet instead of shipped separately.
    ]]
    local frameCls  = frame_classes()
    local alignHtml = align_row()

    --[[
        Both images as stacked CSS backgrounds, remote on top of the embedded
        blank. url() works inside a <style> block — that's how the blank has
        been rendering — so a remote that 404s simply paints nothing and the
        blank shows through, with no broken-image icon. An <img> can't do
        that: a failed src draws the browser's placeholder, which is what put
        a broken thumbnail over the portrait.
    ]]
    local layers = 'url("' .. esc(avatar_url()) .. '")'
    if blank then layers = layers .. ', url("' .. blank .. '")' end

    --[[
        Both the portrait and its frame are injected as background-image into
        the single stylesheet. A dynamic url() works there — that is how the
        avatar has been rendering — while inline style attributes lose it.
    ]]
    local blankCss = '.arc-port .face{background-image:' .. layers .. '}'
        .. '.arc-port .ring{background-image:url("' .. FRAME_BASE .. '/rank-' .. frame_rank() .. '.png")}'

    local gear = '<div class="gear" data-mud-action="view" data-mud-data="'
        .. (view == "settings" and "panel" or "settings") .. '">'
        .. (view == "settings" and "&#9664; back" or "&#9881;") .. '</div>'

    if view == "settings" then
        setWidgetProperty(widget, "content", '<style>' .. CSS .. blankCss .. '</style>'
            .. '<div class="arc-port">' .. gear
            .. '<div class="set">' .. render_settings() .. '</div></div>')
        return
    end

    local html = '<style>' .. CSS .. blankCss .. '</style>'
        .. '<div class="arc-port">' .. gear
        .. '<div class="head">'
        .. '<div class="slot ' .. frameCls .. '">'
        .. '<div class="face"></div><div class="ring"></div></div>'
        .. '<div class="who">'
        .. '<div class="nm">' .. name .. '</div>'
        .. '<div class="sub">' .. lvl .. ' &mdash; ' .. kind .. '</div>'
        .. '<div class="sub2">' .. table.concat(line2, " &middot; ") .. '</div>'
        .. coin
        .. '</div></div>'
        .. xp_box()
        .. grid
        .. worth
        .. alignHtml
        .. '</div>'

    setWidgetProperty(widget, "content", html)
end

local function pull()
    local b = gmcp_get({ "char.base", "Char.Base" })
    if type(b) == "table" then
        ch.name     = b.name
        ch.race     = b.race
        ch.class    = b.class
        ch.subclass = b.subclass
        ch.level    = tonumber(b.level)
        ch.tier     = tonumber(b.tier)
        ch.perlevel = tonumber(b.perlevel)
        ch.remorts  = tonumber(b.remorts)
        ch.redos    = tonumber(b.redos)

        load_char()
    end

    local s = gmcp_get({ "char.status", "Char.Status" })
    if type(s) == "table" then
        ch.level = tonumber(s.level) or ch.level
        ch.tnl   = tonumber(s.tnl)
        ch.align = tonumber(s.align)
        ch.pos   = s.pos
    end

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
        ch.maxstr   = tonumber(m.maxstr)
        ch.maxint   = tonumber(m.maxint)
        ch.maxwis   = tonumber(m.maxwis)
        ch.maxdex   = tonumber(m.maxdex)
        ch.maxcon   = tonumber(m.maxcon)
        ch.maxluck  = tonumber(m.maxluck)
    end

    local st = gmcp_get({ "char.stats", "Char.Stats" })
    if type(st) == "table" then
        ch.str   = tonumber(st.str)
        ch.int   = tonumber(st.int)
        ch.wis   = tonumber(st.wis)
        ch.dex   = tonumber(st.dex)
        ch.con   = tonumber(st.con)
        ch.luck  = tonumber(st.luck)
        ch.hr    = tonumber(st.hr)
        ch.dr    = tonumber(st.dr)
        ch.saves = tonumber(st.saves)
    end

    --[[
        char.worth also carries qpearned and totqp; both are lifetime totals
        rather than anything spendable, so they're deliberately not read.
    ]]
    local w = gmcp_get({ "char.worth", "Char.Worth" })
    if type(w) == "table" then
        ch.gold   = tonumber(w.gold)
        ch.bank   = tonumber(w.bank)
        ch.qp     = tonumber(w.qp)
        ch.tp     = tonumber(w.tp)
        ch.trains = tonumber(w.trains)
        ch.pracs  = tonumber(w.pracs)
    end
end

local function refresh()
    pull()
    render()
end

function init()
    --[[
        Declare the GMCP we need. Core owns Core.Supports.Set — it replaces
        the server's record rather than merging, so only one plugin may send
        it — and builds the union from these. Needs: char.base, status, vitals, maxstats, stats, worth.
    ]]
    broadcastPlugin("aw-gmcp", "Char")

    widget = createWidget({
        type     = "html",
        name     = "portrait",
        title    = "Character Info",
        position = { x = 16, y = 90 },
        size     = { width = 400, height = 500 },
    })

    registerWidgetEvent(widget, "action", function(data)
        if type(data) ~= "table" then return end

        local act = tostring(data.action or "")
        local arg = tostring(data.data or "")

        if act == "view" then
            view = (arg == "settings") and "settings" or "panel"

        elseif act == "sex" then
            cfg.sex = (arg == "m" or arg == "f") and arg or nil

        elseif act == "palette" then
            local ok = false
            for _, p in ipairs(PALETTES) do
                if p.id == arg then ok = true end
            end
            if not ok then return end
            cfg.palette = arg

        elseif act == "avatarclear" then
            cfg.avatar = nil

        elseif act == "pinsize" then
            local w, h = widgetInfo(widget, 3), widgetInfo(widget, 4)
            if type(w) == "number" and type(h) == "number" then
                cfg.sizeW, cfg.sizeH = math.floor(w), math.floor(h)
                utilprint(TAG .. "opens at " .. cfg.sizeW .. "x" .. cfg.sizeH .. " now.")
            end

        else
            return
        end

        save_cfg()
        refresh()
    end)

    --[[
        Form submits hand over every named field, which is how the URL box
        works without any JavaScript in the widget.
    ]]
    registerWidgetEvent(widget, "submit", function(data)
        if type(data) ~= "table" then return end

        local f = data.formData
        if type(f) ~= "table" then return end
        if str(f.op) ~= "avatar" then return end

        local url = str(f.url)
        if not url then
            cfg.avatar = nil
        elseif string.sub(url, 1, 8) == "https://" or string.sub(url, 1, 11) == "data:image/" then
            cfg.avatar = url
        else
            utilprint(TAGR .. "needs an https:// URL or a data:image/ URI.")
            return
        end

        save_cfg()
        refresh()
    end)

    local saved = loadTable("aw_portrait")
    if type(saved) ~= "table" then saved = recall("aw_portrait") end
    --[[
        type() checks, not truthiness.

        JS undefined is neither Lua nil nor false, so `if x then` treats it as
        TRUE and the next dereference throws — this crashed the plugin on load
        with "undefined is not an object (evaluating 'cfg.size.width')".
        Anything that came from the JavaScript side has to be type-checked
        before it is indexed.
    ]]
    if type(saved) == "table" then
        -- avatar and sex used to live here, shared by every character. Held
        -- aside for load_char() to hand to the first one that logs in.
        if str(saved.avatar) then legacy.avatar = saved.avatar end
        if saved.sex == "m" or saved.sex == "f" then legacy.sex = saved.sex end

        if str(saved.palette) or saved.palette == "" then cfg.palette = saved.palette end
        --[[
            Flat numbers, not a nested { width, height }. A nested table that
            came back through loadTable kept crashing on load with
            "undefined is not an object (evaluating 'cfg.size.width')" even
            behind a type() guard — whatever loadTable rehydrates a nested
            object into does not behave like a Lua table. Two scalars can't
            have that problem.
        ]]
        cfg.sizeW = tonumber(saved.sizeW)
        cfg.sizeH = tonumber(saved.sizeH)
    end

    -- pinned by /awchar default; MudForge overrides with its own saved
    -- geometry when it has one, so this only bites on a fresh profile
    -- the backup is only written on save; make sure one exists from the start
    save_cfg()

    if cfg.sizeW and cfg.sizeH then
        resizeWidget(widget, cfg.sizeW, cfg.sizeH)
    end

    on_package({ "char.base",     "Char.Base" },                      refresh)
    on_package({ "char.status",   "Char.Status" },                    refresh)
    on_package({ "char.vitals",   "Char.Vitals" },                    refresh)
    on_package({ "char.maxstats", "Char.Maxstats", "Char.MaxStats" }, refresh)
    on_package({ "char.stats",    "Char.Stats" },                     refresh)
    on_package({ "char.worth",    "Char.Worth" },                     refresh)

    refresh()

    --[[
        char.base only fires at login. Reloading the plugin mid-session means
        the one pull() in init can land before the GMCP store is readable —
        which is exactly what happened: race, class and remorts all came back
        empty while the raw package plainly had them, and nothing re-fired to
        correct it. Two nudges after load cover that window.
    ]]
    setTimeout(refresh, 800)
    setTimeout(refresh, 2500)
end

registerCommand("avatar", function(args)
    local a   = argv(args)
    local sub = a[1] or ""

    if sub == "" or sub == "show" then
        utilprint(TAG .. "using: " .. avatar_url())
        utilprint("$w  stored for: " .. (who or "nobody yet — waiting on char.base"))
        utilprint("$w  /avatar <https url or data: uri>   set your own")
        utilprint("$w  /avatar clear                      back to the race/class template")
        utilprint("$w  /avatar sex <male|female|clear>     pick the portrait variant")
        return
    end

    if string.lower(sub) == "sex" then
        local want = a[2] and string.lower(a[2]) or ""
        local map  = { m = "m", male = "m", f = "f", female = "f" }

        if want == "clear" or want == "none" then
            cfg.sex = nil
            save_cfg()
            refresh()
            utilprint(TAG .. "using the unisex portrait.")
            return
        end

        if not map[want] then
            utilprint(TAGR .. "/avatar sex <male|female|clear>")
            return
        end

        cfg.sex = map[want]
        save_cfg()
        refresh()
        utilprint(TAG .. "portrait set to " .. (cfg.sex == "m" and "male" or "female") .. ".")
        return
    end

    if string.lower(sub) == "clear" then
        cfg.avatar = nil
        save_cfg()
        refresh()
        utilprint(TAG .. "back to the " .. slug(ch.race) .. "-" .. slug(ch.class) .. " template.")
        return
    end

    --[[
        Only https and data: get through. DOMPurify would drop anything else
        on an <img> anyway, but rejecting it here means the player gets told
        why instead of watching the portrait silently go blank.
    ]]
    if string.sub(sub, 1, 8) ~= "https://" and string.sub(sub, 1, 11) ~= "data:image/" then
        utilprint(TAGR .. "needs an https:// URL or a data:image/ URI.")
        return
    end

    cfg.avatar = sub
    save_cfg()
    refresh()
    utilprint(TAG .. "avatar set.")
end, "Set your portrait: /avatar <https url|data uri>, /avatar clear")

registerCommand("awchar", function(args)
    local a = argv(args)

    -- re-read before reporting; otherwise this describes whatever state the
    -- plugin happened to load with rather than what GMCP holds now
    refresh()

    --[[
        '/awchar default' pins the panel's current size as the one it opens
        at. MudForge already remembers geometry per widget id, so this only
        matters on a fresh profile — but it beats hardcoding a number guessed
        off a scaled screenshot, and it means the size is whatever you
        actually dragged it to.
    ]]
    if a[1] and string.lower(a[1]) == "default" then
        local w, h = widgetInfo(widget, 3), widgetInfo(widget, 4)

        if type(w) ~= "number" or type(h) ~= "number" then
            utilprint(TAGR .. "couldn't read the panel size.")
            return
        end

        cfg.sizeW, cfg.sizeH = math.floor(w), math.floor(h)
        save_cfg()
        utilprint(TAG .. "default size is now " .. cfg.sizeW .. "x" .. cfg.sizeH .. ".")
        return
    end

    utilprint(TAG .. "size: " .. tostring(widgetInfo(widget, 3)) .. "x" .. tostring(widgetInfo(widget, 4))
        .. "   ('/awchar default' pins this as the opening size)")
    utilprint(TAG .. "icons library: " .. (blank and "loaded" or "$RNOT LOADED$w — no blank fallback"))
    utilprint(TAG .. "race=" .. tostring(str(ch.race))
        .. "  class=" .. tostring(str(ch.class))
        .. "  derived=" .. tostring(class_of())
        .. "  subclass=" .. tostring(str(ch.subclass)))
    utilprint(TAG .. "avatar: " .. avatar_url())
    local _, frameDesc = frame_classes()
    utilprint(TAG .. "frame: " .. frameDesc .. "  (remorts=" .. tostring(ch.remorts) .. " tier=" .. tostring(ch.tier) .. " redos=" .. tostring(ch.redos) .. ")")
    utilprint(TAG .. "raw char.base:")
    tprint(gmcp_get({ "char.base", "Char.Base" }) or { none = true })
end, "Dump what the portrait panel is reading from GMCP")

registerCommand("aligncolor", function(args)
    local a    = argv(args)
    local want = a[1] and string.lower(a[1]) or ""

    --[[
        A preset, not an arbitrary colour. Runtime-generated CSS never reaches
        these widgets, so the palettes are enumerated as static classes and
        this picks between them — see the settings pane for the same thing
        with clicks.
    ]]
    if want == "" then
        local names = {}
        for _, p in ipairs(PALETTES) do
            table.insert(names, string.lower(p.name) .. ((str(cfg.palette) or "") == p.id and " *" or ""))
        end
        utilprint(TAG .. "palettes: " .. table.concat(names, ", "))
        utilprint("$w  /aligncolor <name>")
        return
    end

    for _, p in ipairs(PALETTES) do
        if string.lower(p.name) == want then
            cfg.palette = p.id
            save_cfg()
            refresh()
            utilprint(TAG .. "alignment palette: " .. p.name)
            return
        end
    end

    utilprint(TAGR .. "no palette called '" .. want .. "'")
end, "Pick the alignment palette: /aligncolor verdant")
