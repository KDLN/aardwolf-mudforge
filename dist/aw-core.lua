--[[
    aw-core.lua
    Sean Stoves (Solao) — 2026-08-03

    Session bootstrap for the Aardwolf UI. Negotiates the GMCP options the
    panels depend on and primes the server into resending current state.

    Two things make this necessary:
      - Aardwolf's group monitor is OFF by default. Nothing gets a group
        packet until either "Group 1" is in Core.Supports.Set or a literal
        'group on' is sent.
    Other plugins declare what they need and Core sends the union:

        broadcastPlugin("aw-gmcp", "Char,Room")

    See docs/CORE.md for the contract, and docs/MUDFORGE-NOTES.md for the
    runtime and sanitiser behaviour every plugin here has had to work around.
]]

plugin = {
    id          = "aw-core",
    name        = "Aardwolf Core",
    version     = "2.6.0",
    author      = "Solao",
    description = "GMCP negotiation and session bootstrap. Required by the other Aardwolf panels.",
    settings    = { saveState = true },
}

-- @category utilities

--[[
    Every diagnostic line carries the running version. Chasing a bug that
    was already fixed on disk cost several rounds — the output has to say
    which build is actually answering.
]]
local TAG  = "$Y[Core v" .. plugin.version .. "]$w "
local TAGR = "$R[Core v" .. plugin.version .. "]$w "

--[[
    The supports list is built from what the loaded plugins actually ask for,
    not hardcoded at its maximum.

    Core.Supports.Set REPLACES the server's record rather than merging into
    it, so exactly one plugin may ever send it — this one. Everything else
    declares what it needs and Core sends the union:

        broadcastPlugin("aw-gmcp", "Char,Room")

    A comma-separated string, deliberately, not a table: arrays crossing the
    plugin boundary have arrived 0-indexed, undefined, or as JSON objects
    with numeric keys more than once in this codebase. A string can't.

    The union is persisted, because Core may well load before the plugins
    that need things — on the next login it already knows the full set rather
    than starting narrow and widening after everything else has registered.

    Aardwolf rejects anything outside this set with "unsupported keyword".
]]
local VALID = { core = "Core", char = "Char", comm = "Comm",
                room = "Room", group = "Group" }

--[[
    A usable string, or nil. JS undefined reaching a string field arrives as
    the literal text "undefined" and is truthy besides, so `x or default`
    never fires on it.
]]
local function str(v)
    if type(v) ~= "string" then return nil end
    if v == "" or v == "undefined" or v == "null" then return nil end
    return v
end

--[[
    The id of the room we're standing in.

    getCurrentRoom() returns the room RECORD — a 14-field table — while
    getPlayerRoom() returns the number. Passing the table to gotoRoom and
    getRoomArea is why every attempt to nudge the map view did nothing, and why
    the diagnostic printed "for room [object Object]" with every reader nil.
]]
local function here_id()
    local ok, v = pcall(function() return getPlayerRoom() end)
    if ok and tonumber(v) then return tonumber(v) end

    ok, v = pcall(function() return getCurrentRoom() end)
    if ok then
        if tonumber(v) then return tonumber(v) end
        if type(v) == "table" and tonumber(v.num) then return tonumber(v.num) end
    end

    return nil
end

--[[
    A real number, or nil. type(x) == "number" isn't enough on its own: NaN is
    a number and prints as "NaN", which is exactly what a missing field did to
    the import panel's counters.
]]
local function num(v)
    local n = tonumber(v)
    if type(n) ~= "number" then return nil end
    if n ~= n then return nil end
    return n
end

--[[
    Baseline. Core is never optional, and neither is Room: MudForge's own
    mapper reads room.info and is not a plugin, so it can't declare a need.
    Leaving Room to whichever plugin happens to want it means disabling that
    plugin silently kills the map — the exact failure this whole one-owner
    arrangement exists to prevent.
]]
local BASELINE = { Core = true, Room = true }

--[[
    Declarations kept per plugin, not merged straight into a set.

    A merged set can only grow: disable a plugin and its packages stay
    subscribed forever, which defeats asking for only what's needed. Keyed by
    the plugin that asked, the union can be rebuilt from whoever is actually
    loaded — so removing a plugin narrows the list on the next rebuild.
]]
local declared = {}      -- [pluginId] = "Char,Room"
local needs    = { Core = true, Room = true }

--[[
    Aardwolf's own commands are not JSON — they go over as bare strings.
    sendGMCP(package) with no data argument passes the string through
    untouched, the equivalent of MUSHclient's 'sendgmcp group on'.
]]
local OPTIONS = {
    "group on",         -- group monitor, needed by the group panel
}

--[[
    'gmcpchannels on' is NOT sent by default, and this is the important bit:
    Aardwolf's own doc says it makes channels go over GMCP *only*, which is a
    server-side gag on every channel at once. Channel text simply stops
    arriving in the main window, no matter what the Comms panel is set to —
    which is exactly the "gagging when unchecked" behaviour it caused.

    comm.channel does NOT depend on it. GMCP channel messages come from
    "Comm 1" in the supports list, which is always sent; this option only
    adds the suppression on top.

    Left off so channels appear in both places, which is the sane default.
    Anyone who wants the terminal quiet can turn it on here rather than
    gagging channel by channel.
]]
local gmcpOnly = false

--[[
    Asked for after the options land, so the panels get a full state dump
    instead of waiting for the next natural change.

    'request char' is deliberately NOT here. It makes Aardwolf resend char.*,
    including char.base — which is the very packet this plugin bootstraps on.
    That closes a loop: request char -> char.base -> bootstrap -> request char,
    forever, at whatever rate the server answers. It ran away exactly like
    that on a live session. Room and quest don't feed back, so they're safe.

    The manual /awcore path still asks for char, because by then the latch is
    already set and the reply can't re-trigger anything.
]]
local REQUESTS = {
    "request room",
    "request quest",
}

local debugOn = false
local quiet   = false

--[[
    MudForge refuses to create a timer while the session is disconnected —
    "Cannot add timer - not connected to server". The importer is driven
    entirely by setTimeout, so starting one at the login prompt produced a run
    that reported itself as running and never advanced a single row.
]]
local connected = false

--[[
    Core has no panel of its own — it's protocol plumbing. Rather than park a
    permanent widget on screen for a handful of toggles, the settings window
    is created hidden and summoned with /awcore.
]]
local panel = nil
local shown = false

--[[
    Settings that survive a reinstall.

    saveTable is scoped to the plugin, and removing a plugin takes its rows
    with it — which is exactly how every update to these plugins is installed.
    A world variable isn't tied to the plugin, so it comes through.

    For Core this is what keeps the declaration list: without it a reinstall
    drops every plugin's GMCP request and the panels sit unsubscribed until
    each one is reloaded by hand.
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
    Hand-rolled JSON array, deliberately.

    Passing a Lua table to sendGMCP sends {"1":"Core 1","2":"Char 1",...} —
    a JSON *object* with numeric keys. Lua arrays are 1-indexed, and MudForge
    transpiles to JavaScript rather than running a VM, so the table comes out
    the other side as an object, not an array. Aardwolf rejects that outright
    ("expected element to be string"), which means the whole subscription
    silently never takes.

    sendGMCP passes a string argument through untouched, so build the array
    text ourselves and let it go as-is.
]]
-- stable order, so an unchanged set produces an identical string and the
-- change check below doesn't fire on table iteration order alone
local function supports_list()
    local out = {}
    for _, name in ipairs({ "Core", "Char", "Comm", "Room", "Group" }) do
        if needs[name] then table.insert(out, name .. " 1") end
    end
    return out
end

local function supports_json()
    local parts = {}

    for _, pkg in ipairs(supports_list()) do
        table.insert(parts, '"' .. pkg .. '"')
    end

    -- Makes Aardwolf echo its own GMCP parse errors back to us. Worth having
    -- while wiring up a new panel, noisy the rest of the time.
    if debugOn then table.insert(parts, '"debug 1"') end

    return "[" .. table.concat(parts, ",") .. "]"
end

--[[
    char.base fires more than once per login, and we subscribe under both
    casings, so an unguarded handler re-sends the whole sequence several
    times per connect — four Core.Supports.Set in a row on the last run.
    Latch it, and only re-arm on disconnect or an explicit /awcore.
]]
local booted = false
local lastRun = 0

-- Hard floor between negotiations, latch or no latch. If anything ever
-- re-opens a feedback loop, this caps it at one round per interval instead
-- of letting it run at whatever rate the server answers.
local MIN_GAP_MS = 5000

local function bootstrap(why, force)
    if booted and not force then return end

    local now = getCurrentTime()
    if lastRun > 0 and (now - lastRun) < MIN_GAP_MS then return end

    booted = true
    lastRun = now

    sendGMCP("Core.Supports.Set", supports_json())

    for _, opt in ipairs(OPTIONS) do
        sendGMCP(opt)
    end

    -- explicitly off unless asked for, so a stale server-side setting from an
    -- earlier session gets cleared rather than lingering
    sendGMCP(gmcpOnly and "gmcpchannels on" or "gmcpchannels off")

    for _, req in ipairs(REQUESTS) do
        sendGMCP(req)
    end

    -- safe here only because the latch is already set, so the char.* reply
    -- can't come back around and re-trigger us
    if force then sendGMCP("request char") end

    --[[
        One line, and silenceable. Note this is only ours — the "GMCP Sent:"
        echo above it is MudForge's own protocol debug, turned off under
        Settings -> Debug, not from here.
    ]]
    if not quiet then
        utilprint(TAG .. "GMCP ready (" .. why .. ")")
    end
end

--[[
    Tag-based output (statmon and friends) goes here once the panels that
    need it exist. Deliberately not stubbed with guessed commands.
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

local CSS = [[
<style>
    .arc-c {
        font-family: "JetBrains Mono", ui-monospace, monospace;
        color: hsl(var(--foreground, 35 34% 78%));
        padding: 11px; height: 100%; box-sizing: border-box; overflow-y: auto;
        background:
            radial-gradient(130% 120% at 20% -10%, rgba(147,25,24,0.14), transparent 62%),
            hsl(var(--card, 0 12% 8%));
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: var(--glass-radius, 4px);
    }
    .arc-c .sec {
        font-size: 8px; letter-spacing: 0.18em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        margin: 11px 0 5px; padding-bottom: 4px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-c .sec:first-child { margin-top: 0; }
    .arc-c .chips { display: flex; flex-wrap: wrap; gap: 4px; }
    .arc-c .chip {
        font-size: 8px; letter-spacing: 0.1em; text-transform: uppercase;
        padding: 3px 7px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer; white-space: nowrap; user-select: none;
    }
    .arc-c .chip:hover { color: hsl(var(--foreground, 35 34% 78%)); }
    .arc-c .chip.on {
        color: hsl(var(--primary, 0 72% 42%));
        border-color: hsl(var(--primary, 0 72% 42%));
        background: rgba(147,25,24,0.14);
    }
    .arc-c .note {
        font-size: 9px; line-height: 1.55; margin-top: 7px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-c .note code { color: hsl(var(--foreground, 35 34% 78%)); }
    .arc-c .step {
        font-size: 9px; line-height: 1.6; margin: 5px 0 5px 2px;
        padding-left: 9px;
        border-left: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-c .step b { color: hsl(var(--primary, 0 72% 42%)); }
    .arc-c .step code { color: hsl(var(--foreground, 35 34% 78%)); }

    .arc-c .pkg {
        font-size: 10px; margin-top: 4px;
        color: hsl(var(--foreground, 35 34% 78%));
        word-break: break-all;
    }
</style>
]]

local function chip(action, label, on)
    return '<div class="chip' .. (on and ' on' or '') .. '" data-mud-action="' .. action .. '">'
        .. label .. '</div>'
end

------------------------------------------------------------------------------
-- MUSHclient map importer
--
-- Brings a MUSHclient Aardwolf mapper database into MudForge's mapper.
--
-- The SQLite half happens outside the client — tools/import-mushmap.py turns
-- Aardwolf.db into numbered Lua chunks under libs/, because a plugin can't
-- open a database file and there is no JSON parser in the sandbox either.
-- All that crosses over is Lua source, which require() already handles.
--
-- 23k rooms and 76k exits is far too much for one pass. Doing it in a loop
-- would wedge the client for however long it took, so the work runs on a
-- TIME budget rather than a row count: each tick applies rows until it has
-- spent IMP_BUDGET milliseconds, then hands the UI back for IMP_GAP. A slow
-- machine does fewer rows per tick and takes longer; it never stops
-- responding. That's the whole reason there's no batch-size setting.
------------------------------------------------------------------------------

--[[
    Instructions, and only instructions.

    None of this is the plugin's work: a script reads a MUSHclient database and
    writes MudForge's own export format, and MudForge imports it. Core says how
    because this is where someone will look, not because it does any of it.
]]
local function map_help()
    return '<div class="sec">Map import</div>'
        .. '<div class="note">Bring a MUSHclient map across in three steps.</div>'
        .. '<div class="step"><b>1.</b> Double-click <b>Import Aardwolf Map</b> in '
        .. 'the <code>tools</code> folder and choose your <code>Aardwolf.db</code>. '
        .. 'It is read, never modified.</div>'
        .. '<div class="step"><b>2.</b> It writes <code>aardwolf-map.json</code> to '
        .. 'your Desktop. Open the map panel\'s <b>&#8943;</b> menu, choose '
        .. '<b>Import Map Data</b>, and pick that file.</div>'
        .. '<div class="step"><b>3.</b> Restart MudForge. The map view is built at '
        .. 'startup and won\'t show the new rooms until it is.</div>'
        .. '<div class="note">Rooms, areas, terrain, doors and portals all come over, '
        .. 'and your existing map settings are kept. Aardwolf vnums are the room ids '
        .. 'on both sides, so anything already mapped here merges rather than '
        .. 'duplicating.</div>'
end

local function render()
    if not panel then return end

    setWidgetProperty(panel, "content", CSS
        .. '<div class="arc-c">'
        .. '<div class="sec">Session</div><div class="chips">'
        .. chip("renegotiate", "re-negotiate now", false)
        .. chip("quiet", "quiet startup", quiet)
        .. chip("gmcponly", "channels via GMCP only", gmcpOnly)

        .. '</div>'
        .. '<div class="note"><b>Channels via GMCP only</b> tells Aardwolf to stop '
        .. 'printing channel text in the terminal, leaving it to the Comms panel. '
        .. 'Off by default: it silences every channel at once, server-side, and '
        .. 'no per-channel setting can override it.</div>'
        .. '<div class="note">Re-sends the supports list and the channel options, '
        .. 'then asks Aardwolf to resend current state.</div>'
        .. '<div class="sec">Subscribed packages</div>'
        .. '<div class="pkg">' .. table.concat(supports_list(), " &middot; ") .. '</div>'
        .. '<div class="note">Built from what the loaded plugins ask for, rebuilt when '
        .. 'one is enabled, disabled or removed. '
        .. 'Aardwolf <b>replaces</b> this list rather than merging, so only Core sends '
        .. 'it — a second sender would silently unsubscribe everything absent from its '
        .. 'own list, including the mapper.</div>'
        .. map_help()
        .. '<div class="sec">Debug</div><div class="chips">'
        .. chip("debug", "server GMCP errors", debugOn)
        .. '</div>'
        .. '<div class="note">Adds <code>debug 1</code> to the supports list so Aardwolf '
        .. 'echoes its own parse errors back. The <code>GMCP Sent:</code> lines in the '
        .. 'terminal are MudForge\'s own protocol echo, not ours — those are under '
        .. 'Settings, Debug.</div>'
        .. '</div>')
end

local function load_cfg()
    local saved = loadTable("aw_core")
    if type(saved) ~= "table" then saved = recall("aw_core") end
    if type(saved) ~= "table" then return end

    if saved.quiet == true then quiet = true end
    if saved.gmcpOnly == true then gmcpOnly = true end



    --[[
        Restore last session's declarations. Core often loads before the
        plugins that need things, and negotiating narrow then widening a
        second later means a login where half the panels start empty.

        These are only a head start — rebuild() drops any whose plugin isn't
        loaded, so a plugin removed between sessions doesn't keep its
        packages subscribed.
    ]]
    local blob = saved.declared
    if type(blob) ~= "string" then return end

    local cur = ""
    for i = 1, string.len(blob) + 1 do
        local c = (i <= string.len(blob)) and string.sub(blob, i, i) or ";"
        if c == ";" then
            local pid, csv = string.match(cur, "^([^=]+)=(.*)$")
            if pid and csv then declared[pid] = csv end
            cur = ""
        else
            cur = cur .. c
        end
    end

end

--[[
    A plugin declaring what it needs. Unknown keywords are dropped rather
    than passed on: Aardwolf answers those with "unsupported keyword", and
    one bad entry taints the whole Core.Supports.Set message.
]]
local resendPending = false

-- every plugin id currently loaded and enabled
local function live_plugins()
    local out = {}
    local list = getLoadedPlugins()
    if type(list) ~= "table" then return out end

    -- arrays from the JS side arrive 0-indexed; read both ways
    local seen = false
    local i = 0
    while list[i] ~= nil do
        local p = list[i]
        if type(p) == "table" and str(p.id) and p.enabled ~= false then out[p.id] = true end
        seen = true
        i = i + 1
    end

    if not seen then
        for _, p in ipairs(list) do
            if type(p) == "table" and str(p.id) and p.enabled ~= false then out[p.id] = true end
        end
    end

    return out
end

local function add_csv(set, csv)
    local cur = ""
    for i = 1, string.len(csv) + 1 do
        local c = (i <= string.len(csv)) and string.sub(csv, i, i) or ","
        if c == "," then
            local name = VALID[string.lower(string.gsub(cur, " 1", ""))]
            if name then set[name] = true end
            cur = ""
        elseif c ~= " " then
            cur = cur .. c
        end
    end
end

--[[
    Rebuild the union from declarations whose plugin is still loaded, and say
    whether it changed. Dropping a stale declaration is the point: it's what
    lets the list narrow when a plugin is disabled or removed.
]]
local function rebuild()
    local before = table.concat(supports_list(), ",")
    local live   = live_plugins()

    --[[
        An empty plugin list is "can't tell", not "nothing is loaded".

        Pruning on it was destructive and self-inflicting: reloading Core while
        getLoadedPlugins() wasn't ready dropped every declaration, persisted the
        loss, and every negotiation after that sent ["Core 1","Room 1"] — so the
        character panel, comms, group and SnD all sat there with no packages
        subscribed and no way back short of reloading each plugin by hand.

        Prune only against a list that actually has something in it.
    ]]
    --[[
        Prune only when the two id spaces demonstrably agree.

        onPluginBroadcast hands over MudForge's instance UUID — the persisted
        declarations read '118ee8b5-...=Comm,Room' — while getLoadedPlugins
        reports something else. Nothing ever matched, so every declaration was
        dropped on load and the supports list fell back to Core+Room on every
        reload, leaving the character panel, comms and group unsubscribed.

        A list that shares no ids with our own records can't tell us anything
        about who's gone, so it isn't allowed to remove anyone.
    ]]
    local credible = false
    for pid in pairs(declared) do
        if live[pid] then credible = true break end
    end

    needs = {}
    for name in pairs(BASELINE) do needs[name] = true end

    for pid, csv in pairs(declared) do
        if live[pid] or not credible then
            add_csv(needs, csv)
        else
            declared[pid] = nil          -- gone; forget what it asked for
        end
    end

    return table.concat(supports_list(), ",") ~= before
end

local function persist()
    local csv = {}
    for pid, want in pairs(declared) do
        table.insert(csv, pid .. "=" .. want)
    end
    table.sort(csv)

    local blob = { quiet = quiet, gmcpOnly = gmcpOnly,
                   declared = table.concat(csv, ";") }
    saveTable("aw_core", blob)
    keep("aw_core", blob)
end

local function want(pluginId, csv)
    if declared[pluginId] == csv then return end
    declared[pluginId] = csv

    if not rebuild() then
        persist()
        return
    end

    persist()

    --[[
        Debounced. Every plugin registers during its own init, so a fresh
        session would otherwise fire one Core.Supports.Set per plugin — the
        same storm the bootstrap latch exists to prevent.
    ]]
    if resendPending then return end
    resendPending = true

    setTimeout(function()
        resendPending = false
        if booted then bootstrap("packages changed", true) end
        render()
    end, 1200)
end

function init()
    load_cfg()

    -- load_cfg sits above persist(), so the backup is written here instead:
    -- calling it from up there would resolve persist as a global and be nil
    persist()

    onPluginBroadcast(function(senderId, message, data)
        if tostring(message or "") ~= "aw-gmcp" then return end
        want(tostring(senderId or "?"), tostring(data or ""))
    end)

    --[[
        The client fires these as it enables, disables and removes plugins.
        Without them the list only ever grows: a plugin can be uninstalled and
        its packages stay subscribed until the next restart.

        The rebuild is deferred a beat because the event arrives while the
        client is still updating its own plugin list — asking immediately can
        report the plugin that just left as still loaded.
    ]]
    for _, ev in ipairs({ "plugin-disabled", "plugin-enabled", "plugin-uninstalled" }) do
        addEventHandler(ev, function()
            setTimeout(function()
                if rebuild() then
                    persist()
                    if booted then bootstrap("plugins changed", true) end
                    render()
                end
            end, 700)
        end)
    end

    -- and once at load, against whatever is actually running now
    setTimeout(function()
        if rebuild() then
            persist()
            if booted then bootstrap("startup rebuild", true) end
        end
        render()
    end, 2500)

    panel = createWidget({
        type     = "html",
        name     = "settings",
        title    = "Aardwolf Core",
        position = { x = 520, y = 200 },
        size     = { width = 380, height = 330 },
        visible  = false,
    })

    registerWidgetEvent(panel, "action", function(data)
        if type(data) ~= "table" then return end
        local act = tostring(data.action or "")

        if act == "quiet" then
            quiet = not quiet
            persist()

        elseif act == "debug" then
            debugOn = not debugOn
            bootstrap(debugOn and "debug on" or "debug off", true)

        elseif act == "gmcponly" then
            gmcpOnly = not gmcpOnly
            persist()
            bootstrap("channels", true)

        elseif act == "renegotiate" then
            bootstrap("manual", true)

        else
            return
        end

        render()
    end)

    render()

    --[[
        char.base only arrives at login, which is safely after the client has
        finished its own GMCP negotiation. That matters: our supports list
        REPLACES whatever MudForge sent, so going last is the point. Doing it
        at connect alone would risk the client overwriting us straight after.
    ]]
    onGMCPUpdate("char.base", function() connected = true bootstrap("login") end)
    onGMCPUpdate("Char.Base", function() connected = true bootstrap("login") end)

    -- Reloading the plugin mid-session means that login moment has passed.
    -- loaded mid-session: onConnect already fired and we missed it
    if getGMCPData("char.base") or getGMCPData("Char.Base") then
        connected = true
        bootstrap("reload")
    end
end

-- Safety net for characters that somehow never emit char.base. Delayed so it
-- lands after the client's own negotiation rather than racing it; the latch
-- means this is a no-op whenever char.base already did the job.
function onConnect(sessionId)
    connected = true
    setTimeout(function() bootstrap("connect") end, 3000)


end

-- New session, new negotiation.
function onDisconnect(sessionId)
    connected = false
    booted = false
end

--[[
    Progress updates write into the two bound spans rather than rebuilding the
    panel. A tick lands roughly every 35ms; re-rendering at that rate would
    fight the user for the settings window and reset its scroll each time.
    A full render happens only when the phase changes or the run stops.
]]

registerCommand("awcore", function(args)
    local a   = argv(args)
    local arg = a[1] and string.lower(a[1]) or ""

    -- bare /awcore opens the settings window; it's created hidden, since a
    -- protocol plugin has no business occupying screen space by default
    if arg == "" then
        shown = not shown
        if shown then showWidget(panel) else hideWidget(panel) end
        render()
        return
    end

    if arg == "go" or arg == "now" then
        bootstrap("manual", true)
        return
    end

    -- forced: manual invocations bypass the once-per-login latch
    if arg == "debug" then
        debugOn = not debugOn
        bootstrap(debugOn and "debug on" or "debug off", true)
        return
    end

    if arg == "gmcp" then
        utilprint(TAG .. "sending: " .. table.concat(supports_list(), ", "))
        local any = false
        for pid, csv in pairs(declared) do
            utilprint("$w    " .. pid .. " -> " .. csv)
            any = true
        end
        if not any then utilprint("$w    (nothing declared; baseline only)") end
        return
    end

    --[[
        What the sandbox actually exposes.

        The documentation doesn't list it and the binary won't tell you — the
        frontend is compressed in there, so even known-good names like
        savePluginFile don't turn up as strings. _G is real (the transpiler
        emits _G.next for a bare `next`, which is how we found next() missing),
        so enumerating it is the only honest way to answer "can a plugin do X".

        '/awcore api' for everything, '/awcore api room' to filter.
    ]]
    if arg == "api" then
        local want = a[2] and string.lower(a[2]) or nil
        local fns, other = {}, 0

        local ok = pcall(function()
            for k, v in pairs(_G) do
                local name = tostring(k)
                if want == nil or string.find(string.lower(name), want, 1, true) then
                    if type(v) == "function" then
                        table.insert(fns, name)
                    else
                        other = other + 1
                    end
                end
            end
        end)

        if not ok then
            utilprint(TAGR .. "cannot iterate _G — the sandbox hides it.")
            return
        end

        table.sort(fns)
        utilprint(TAG .. #fns .. " function(s)"
            .. (want and (" matching '" .. want .. "'") or "")
            .. ", " .. other .. " other value(s)")

        local line = ""
        for _, name in ipairs(fns) do
            line = line .. name .. "  "
            if string.len(line) > 88 then
                utilprint("$w  " .. line)
                line = ""
            end
        end
        if line ~= "" then utilprint("$w  " .. line) end
        return
    end

    --[[
        What the mapper says about where you're standing.

        The API surface is large and undocumented — 326 functions, with both a
        MUSHclient and a Mudlet compatibility layer in there — and the names
        don't give away argument order or return shape. This calls the readers
        for the current room and prints what came back, which is the cheapest
        way to learn the shapes before building against them.
    ]]
    if arg == "map" then
        local function shape(v)
            local t = type(v)
            if t ~= "table" then return t .. " " .. tostring(v) end

            local n, keys = 0, {}
            for k, sub in pairs(v) do
                n = n + 1
                if n <= 6 then
                    table.insert(keys, tostring(k) .. "=" .. tostring(sub))
                end
            end
            return "table(" .. n .. ") { " .. table.concat(keys, ", ")
                .. (n > 6 and ", ..." or "") .. " }"
        end

        local function show(name, a1, a2)
            local f = _G[name]
            if type(f) ~= "function" then
                utilprint("$w  " .. name .. "  $R-- absent$w")
                return
            end

            local ok, res = pcall(function() return f(a1, a2) end)
            utilprint("$w  " .. name .. " -> "
                .. (ok and shape(res) or ("$Rthrew:$w " .. tostring(res))))
        end

        show("isMapReady")
        show("getMapStats")

        show("getCurrentRoom")
        show("getPlayerRoom")

        local here = here_id()

        utilprint(TAG .. "for room " .. tostring(here) .. ":")
        show("getRoomName", here)
        show("getRoomAreaName", here)
        show("getRoomExits", here)
        show("getSpecialExits", here)
        show("getDoors", here)
        show("getExitStubs", here)
        show("getRoomUserData", here, "aard.area")
        show("getRoomCoordinates", here)
        show("getRoomArea", here)
        show("getMapRoom", here)

        --[[
            A room the import definitely wrote, well away from wherever the
            player happens to be. If this one has coordinates and exits and the
            current room doesn't, then the live room.info feed is overwriting
            imported rooms as you walk through them.
        ]]
        utilprint(TAG .. "and for imported room 32421 (Starlight Way - West):")
        show("getRoomName", 32421)
        show("getRoomAreaName", 32421)
        show("getRoomCoordinates", 32421)
        show("getRoomExits", 32421)

        --[[
            Does anything let us say a room has been seen? The renderer only
            draws visited rooms, so this is the whole question now.
        ]]
        return
    end


    if arg == "quiet" then
        quiet = not quiet
        persist()
        utilprint(TAG .. "startup messages " .. (quiet and "silenced" or "on") .. ".")
        return
    end

    bootstrap("manual", true)
end, "Re-send the Aardwolf GMCP options. '/awcore gmcp' shows the package list. '/awcore debug' toggles server-side GMCP error reporting")
