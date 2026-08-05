--[[
    aw-chat.lua
    Sean Stoves (Solao) — 2026-08-04

    Communications. Replaces MudForge's built-in chat widget.

    Every channel Aardwolf carries over GMCP is registered up front and routed
    through comm.channel, so there is nothing to configure for the common case
    — the channel list below is the authoritative one off the GMCP wiki.
    Channels that are NOT on GMCP (or anything else you want captured) can be
    added with a regex.

    Gagging is done here, not server-side. 'gmcpchannels on' sounds like it
    suppresses the main window but doesn't — channel text still prints — so a
    gag works by watching for the line that matches a message GMCP just
    delivered for a gagged channel, and discarding it from onLine.
]]

plugin = {
    id          = "aw-chat",
    name        = "Aardwolf Comms",
    version     = "1.12.1",
    author      = "Solao",
    description = "Channel panel with tabs, per-channel routing, gagging and custom regex captures.",
    settings    = { saveState = true },
}

-- @category widgets

local TAG  = "$Y[Comms v" .. plugin.version .. "]$w "
local TAGR = "$R[Comms v" .. plugin.version .. "]$w "

local MAX_LINES = 500

--[[
    Every GMCP channel Aardwolf sends, with the tab it lands in by default.
    Straight off the wiki's "The following Channels are covered by GMCP" list;
    mobsay is added because says from mobs use their own channel.

    Question and Answer are deliberately in the same tab — the wiki notes
    players treat them as one channel, and splitting them reads badly.
]]
local CHANNEL_TAB = {
    -- talk
    gossip = "Chat", question = "Chat", answer = "Chat", newbie = "Chat",
    gratz = "Chat", debate = "Chat", music = "Chat", quote = "Chat",
    tech = "Chat", racetalk = "Chat", curse = "Chat", chant = "Chat",
    commune = "Chat", helper = "Chat", srp = "Chat", wangrp = "Chat",
    grapevine = "Chat", gametalk = "Chat", pokerinfo = "Chat",

    -- directed at you or nearby
    tell = "Tells", telepathy = "Tells", spouse = "Tells", say = "Tells",
    mobsay = "Tells", yell = "Tells", immtalk = "Tells",

    -- clan and org
    clantalk = "Clan", claninfo = "Clan", gclan = "Clan", cant = "Clan",
    nobletalk = "Clan", tiertalk = "Clan", ltalk = "Clan",

    -- group
    gtell = "Group", gsocial = "Group", ftalk = "Group",

    -- commerce
    auction = "Trade", market = "Trade", barter = "Trade",

    -- server chatter. inform is deliberately absent: the wiki lists it as a
    -- GMCP channel but the INFO: broadcasts don't actually arrive that way,
    -- so it's seeded as a regex capture below instead. Leaving it here too
    -- would double every line if it ever did fire.
    wardrums = "Info", restore = "Info",
}

--[[
    Seeded on first run for channels that aren't on GMCP.

    Nothing else ships gagged: a channel should appear in the game window AND
    here by default, and it's the player's call to move it. INFO is the one
    exception — it's a firehose of other people's levelling that drowns
    everything around it, so it starts confined to the panel.
]]
local DEFAULT_CAPTURES = {
    info = { pattern = "^INFO: ", tab = "Info", gag = true },
}

local DEFAULT_TABS = { "All", "Chat", "Tells", "Clan", "Group", "Trade", "Info" }

local widget = nil
local view   = "chat"    -- "chat" | "settings"
local lines  = {}        -- { chan, tab, text, who }
local custom = {}        -- live trigger ids, keyed by capture name

--[[
    Messages GMCP just delivered for a gagged channel, waiting to be matched
    against the terminal line so it can be dropped. Short-lived: a stale entry
    would gag an unrelated line that happened to read the same.
]]
local pendingGag = {}

--[[
    Instrumentation for the gag path. Two guesses at the blank-line problem
    have missed, and the assumption underneath both is unverified: that
    onLine fires at all and that returning false from it discards the line.
    /chat debug reports it rather than guessing a third time.
]]
local dbg = { lines = 0, gagged = 0, blankTrig = 0, last = {} }

--[[
    A trigger that matches an empty line, kept disabled and switched on for
    exactly one line after a gag.

    onLine never sees blank lines — /chat debug counted zero across 81 lines
    while the terminal plainly showed gaps — so the client filters empties
    before calling line handlers. Suppressing the blank from onLine is
    therefore impossible; it has to be a trigger, which sits earlier in the
    pipeline. Leaving it enabled would eat every blank line in the game, so
    it arms for one line and disarms itself.
]]
local blankTrigger = nil

local cfg = {
    seeded  = false, -- one-way: defaults are laid down once, never reapplied
    tabs    = nil,   -- ordered list; nil until loaded
    active  = "All",
    chan    = {},    -- [name] = { tab = "...", gag = bool, off = bool }
    capture = {},    -- [name] = { pattern = "...", tab = "...", gag = bool }
}

--[[
    Two stores, because one of them doesn't survive a reinstall.

    saveTable is scoped to the plugin, and removing a plugin takes its tables
    with it — plugin_tables.db holds exactly one row per plugin and the old one
    is gone after a remove-and-re-add. Since that is how every update to these
    plugins is installed, every update reset the channel settings and INFO came
    back ticked into All.

    A world variable isn't tied to the plugin, so it comes through. saveTable
    stays as the fast path and the variable is the one that actually persists;
    whichever has something on load wins, preferring the table.
]]
local VAR = "aw_chat_cfg"

local function cfg_json()
    local function esc(v)
        return string.gsub(string.gsub(tostring(v), "\\", ""), '"', "")
    end

    local function flags(t)
        local out = {}
        if t.tab ~= nil then table.insert(out, '"tab":"' .. esc(t.tab) .. '"') end
        if t.pattern ~= nil then table.insert(out, '"pattern":"' .. esc(t.pattern) .. '"') end
        for _, k in ipairs({ "gag", "off", "noall" }) do
            if t[k] == true or t[k] == false then
                table.insert(out, '"' .. k .. '":' .. (t[k] and "true" or "false"))
            end
        end
        return "{" .. table.concat(out, ",") .. "}"
    end

    local tabs = {}
    for _, t in ipairs(cfg.tabs or {}) do
        table.insert(tabs, '"' .. esc(t) .. '"')
    end

    local chans = {}
    for name, t in pairs(cfg.chan or {}) do
        if type(t) == "table" then
            table.insert(chans, '"' .. esc(name) .. '":' .. flags(t))
        end
    end

    local caps = {}
    for name, t in pairs(cfg.capture or {}) do
        if type(t) == "table" then
            table.insert(caps, '"' .. esc(name) .. '":' .. flags(t))
        end
    end

    return '{"seeded":' .. (cfg.seeded == true and "true" or "false")
        .. ',"active":"' .. esc(cfg.active or "All") .. '"'
        .. ',"tabs":[' .. table.concat(tabs, ",") .. "]"
        .. ',"chan":{' .. table.concat(chans, ",") .. "}"
        .. ',"capture":{' .. table.concat(caps, ",") .. "}}"
end

local function save_cfg()
    saveTable("aw_chat", cfg)
    pcall(function() setVariable(VAR, cfg_json()) end)
end

-- type checks, never truthiness — JS undefined is truthy under Lua rules
local function gmcp_get(names)
    for _, name in ipairs(names) do
        local data = getGMCPData(name)
        if type(data) == "table" then return data end
    end
    return nil
end

local function str(v)
    if type(v) ~= "string" then return nil end
    if v == "" or v == "undefined" or v == "null" then return nil end
    return v
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

--[[
    'next' is not in the plugin sandbox — it isn't among the globals the
    runtime exposes, and calling it fails the whole plugin load with
    "_G.next is not a function". pairs is available, so emptiness is checked
    by trying to take one step.
]]
local function is_empty(t)
    if type(t) ~= "table" then return true end
    for _ in pairs(t) do return false end
    return true
end

--[[
    Pull display text out of whatever a trigger hands us.

    The docs describe the callback as both function(line, wildcards) and
    function(match, ...captures), and in practice the first argument is not a
    string at all — stripAnsiCodes blew up on it with "e.replace is not a
    function" for every INFO line. So probe rather than assume, and never
    hand a non-string to the ANSI stripper.
]]
local function as_text(...)
    local args = { ... }

    for _, v in ipairs(args) do
        if type(v) == "string" and v ~= "" then return v end

        if type(v) == "table" then
            for _, k in ipairs({ "line", "text", "raw", "match", "matched" }) do
                if type(v[k]) == "string" and v[k] ~= "" then return v[k] end
            end
            for i = 0, 2 do
                if type(v[i]) == "string" and v[i] ~= "" then return v[i] end
            end
        end
    end

    return nil
end

local function esc(s)
    if type(s) ~= "string" then return "" end
    s = string.gsub(s, "&", "&amp;")
    s = string.gsub(s, "<", "&lt;")
    s = string.gsub(s, ">", "&gt;")
    s = string.gsub(s, '"', "&quot;")
    return s
end

local function tabs()
    if type(cfg.tabs) == "table" and #cfg.tabs > 0 then return cfg.tabs end
    return DEFAULT_TABS
end

local function has_tab(name)
    for _, t in ipairs(tabs()) do
        if string.lower(t) == string.lower(name) then return t end
    end
    return nil
end

local function chan_cfg(chan)
    local c = cfg.chan[chan]
    if type(c) ~= "table" then
        c = {}
        cfg.chan[chan] = c
    end
    return c
end

local function tab_of(chan)
    local c = chan_cfg(chan)
    if str(c.tab) then return c.tab end

    local cap = cfg.capture[chan]
    if type(cap) == "table" and str(cap.tab) then return cap.tab end

    return CHANNEL_TAB[chan] or "Chat"
end

--[[
    Slug for the CSS class. Colour has to come from a static class — generated
    <style> rules and inline colour are both discarded by the sanitiser — so
    the tab name maps onto one of a fixed set.
]]
local TAB_CLASS = {
    chat = "c-chat", tells = "c-tells", clan = "c-clan",
    group = "c-group", trade = "c-trade", info = "c-info",
}

local function tab_class(tab)
    return TAB_CLASS[string.lower(tab or "")] or "c-chat"
end

local CSS = [[
<style>
    .arc-ch {
        font-family: "JetBrains Mono", ui-monospace, monospace;
        color: hsl(var(--foreground, 35 34% 78%));
        height: 100%;
        display: flex; flex-direction: column;
        box-sizing: border-box;
        background:
            radial-gradient(130% 120% at 20% -10%, rgba(147,25,24,0.13), transparent 62%),
            hsl(var(--card, 0 12% 8%));
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: var(--glass-radius, 4px);
    }
    .arc-ch .bar {
        flex: none;
        display: flex; flex-wrap: wrap; gap: 3px;
        padding: 7px 8px 6px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-ch .tb {
        font-size: 8px; letter-spacing: 0.13em; text-transform: uppercase;
        padding: 3px 7px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: 2px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer;
        white-space: nowrap;
        user-select: none;
    }
    .arc-ch .tb:hover { color: hsl(var(--foreground, 35 34% 78%)); }
    .arc-ch .tb.on {
        color: hsl(var(--primary, 0 72% 42%));
        border-color: hsl(var(--primary, 0 72% 42%));
        background: rgba(147,25,24,0.12);
    }
    .arc-ch .tb .n { opacity: 0.6; margin-left: 4px; }

    .arc-ch .body {
        flex: 1; min-height: 0;
        overflow-y: auto;
        padding: 7px 9px 9px;
        font-size: 11px;
        line-height: 1.45;
        display: flex; flex-direction: column-reverse;   /* newest pinned to the bottom */
    }
    .arc-ch .ln { white-space: pre-wrap; word-break: break-word; }
    .arc-ch .ln .ch {
        font-size: 8px; letter-spacing: 0.1em; text-transform: uppercase;
        opacity: 0.75; margin-right: 5px;
    }

    /* channel colour by tab — static classes only */
    .arc-ch .c-chat  .ch { color: #d7c4a4; }
    .arc-ch .c-tells .ch { color: #e8c84c; }
    .arc-ch .c-clan  .ch { color: #7fbf7f; }
    .arc-ch .c-group .ch { color: #8a6bc0; }
    .arc-ch .c-trade .ch { color: #c9a227; }
    .arc-ch .c-info  .ch { color: #c0392f; }

    /* settings view */
    .arc-ch .set { padding: 8px 9px 10px; overflow-y: auto; flex: 1; min-height: 0; }
    .arc-ch .sec {
        font-size: 8px; letter-spacing: 0.18em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        margin: 10px 0 5px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
        padding-bottom: 4px;
    }
    .arc-ch .sec:first-child { margin-top: 0; }
    .arc-ch .row {
        display: flex; align-items: center; gap: 6px;
        padding: 3px 0;
        font-size: 10px;
    }
    .arc-ch .row .nm { flex: 1; min-width: 0; white-space: nowrap;
        overflow: hidden; text-overflow: ellipsis; }
    .arc-ch .row .pat {
        flex: 1; min-width: 0; white-space: nowrap; overflow: hidden;
        text-overflow: ellipsis;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        font-size: 9px;
    }
    .arc-ch .chip {
        font-size: 8px; letter-spacing: 0.1em; text-transform: uppercase;
        padding: 2px 6px; border-radius: 2px;
        border: 1px solid hsl(var(--border, 0 22% 17%));
        color: hsl(var(--muted-foreground, 35 14% 52%));
        cursor: pointer; white-space: nowrap; user-select: none;
    }
    .arc-ch .chip:hover { color: hsl(var(--foreground, 35 34% 78%)); }
    .arc-ch .chip.w { min-width: 52px; text-align: center; }
    .arc-ch .chip.on {
        color: hsl(var(--primary, 0 72% 42%));
        border-color: hsl(var(--primary, 0 72% 42%));
        background: rgba(147,25,24,0.14);
    }
    .arc-ch .chip.warn.on {
        color: #e8c84c; border-color: #e8c84c; background: rgba(232,200,76,0.12);
    }
    .arc-ch form { display: flex; gap: 5px; align-items: center; margin: 5px 0 2px; }
    /* the channel list is a form too, but its rows have to stack — without
       this it inherits the inline layout above and every row lands on one line */
    .arc-ch form.stack { display: block; }
    .arc-ch form.stack .row { display: flex; align-items: center; gap: 6px; }
    .arc-ch input[type=text] {
        flex: 1; min-width: 0;
        background: rgba(0,0,0,0.45);
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: 2px;
        color: hsl(var(--foreground, 35 34% 78%));
        font-family: inherit; font-size: 10px;
        padding: 3px 6px;
    }
    .arc-ch input[type=text]:focus {
        outline: none;
        border-color: hsl(var(--primary, 0 72% 42%));
    }
    .arc-ch button {
        font-family: inherit;
        font-size: 8px; letter-spacing: 0.12em; text-transform: uppercase;
        padding: 4px 9px;
        background: rgba(147,25,24,0.16);
        border: 1px solid hsl(var(--primary, 0 72% 42%));
        border-radius: 2px;
        color: hsl(var(--primary, 0 72% 42%));
        cursor: pointer;
    }
    .arc-ch button:hover { background: rgba(147,25,24,0.3); }

    .arc-ch .legend {
        font-size: 9px; line-height: 1.55; margin: 2px 0 8px;
        color: hsl(var(--muted-foreground, 35 14% 52%));
    }
    .arc-ch .legend b { color: hsl(var(--foreground, 35 34% 78%)); font-weight: normal; }
    /* header and rows share one grid so the columns cannot drift apart —
       they were laid out separately before and never lined up */
    .arc-ch .hdr, .arc-ch form.stack .row.chan {
        display: grid;
        grid-template-columns: 1fr 84px 38px 38px 38px;
        align-items: center;
        gap: 6px;
    }
    .arc-ch .hdr {
        font-size: 7px; letter-spacing: 0.14em; text-transform: uppercase;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        padding-bottom: 4px; margin-bottom: 3px;
        border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
        position: sticky; top: 0;
        background: hsl(var(--card, 0 12% 8%));
    }
    .arc-ch .cw { text-align: center; }
    .arc-ch .subhdr {
        font-size: 7px; letter-spacing: 0.14em; text-transform: uppercase;
        color: hsl(var(--primary, 0 72% 42%));
        margin: 8px 0 3px; padding-top: 6px;
        border-top: 1px solid hsl(var(--border, 0 22% 17%));
    }
    .arc-ch .row.chan {
        padding: 2px 0;
        border-bottom: 1px solid rgba(255,255,255,0.04);
    }
    .arc-ch label.row { cursor: default; }
    .arc-ch label.row:hover { background: rgba(255,255,255,0.05); }
    .arc-ch select {
        background: rgba(0,0,0,0.45);
        border: 1px solid hsl(var(--border, 0 22% 17%));
        border-radius: 2px;
        color: hsl(var(--foreground, 35 34% 78%));
        font-family: inherit; font-size: 9px;
        padding: 2px 4px; width: 78px; flex: none;
    }
    .arc-ch input[type=checkbox] {
        accent-color: #c0392f; cursor: pointer;
        width: 13px; height: 13px; margin: 0 auto; display: block;
    }
    .arc-ch form.stack select { width: 100%; }

    .arc-ch .hint {
        font-size: 9px; line-height: 1.5;
        color: hsl(var(--muted-foreground, 35 14% 52%));
        margin-top: 8px;
    }
    .arc-ch .hint code { color: hsl(var(--foreground, 35 34% 78%)); }

    .arc-ch .empty {
        color: hsl(var(--muted-foreground, 35 14% 52%));
        font-size: 10px;
        padding: 14px 0;
        text-align: center;
    }
</style>
]]

local function visible(l)
    --[[
        "All" means everything that hasn't opted out. A firehose channel like
        INFO is worth keeping in its own tab without letting it bury the
        conversation in the combined view.
    ]]
    if cfg.active == "All" then
        return chan_cfg(l.chan).noall ~= true
    end
    return string.lower(l.tab) == string.lower(cfg.active)
end

--[[
    Channels split by source: everything Aardwolf carries over GMCP first,
    then the regex captures. Interleaved alphabetically they were impossible
    to tell apart — 'info' sat between immtalk and ltalk looking like a
    built-in channel when it's actually a pattern the user can edit.
]]
local function gmcp_channels()
    local out = {}
    for name in pairs(CHANNEL_TAB) do
        if cfg.capture[name] == nil then table.insert(out, name) end
    end
    table.sort(out)
    return out
end

local function capture_channels()
    local out = {}
    for name in pairs(cfg.capture) do table.insert(out, name) end
    table.sort(out)
    return out
end

-- both, for anything that just needs to walk every channel
local function all_channels()
    local out = gmcp_channels()
    for _, name in ipairs(capture_channels()) do table.insert(out, name) end
    return out
end

local function chip(action, data, label, on, warn)
    return '<div class="chip' .. (warn and ' warn' or '') .. (on and ' on' or '') .. '"'
        .. ' data-mud-action="' .. action .. '" data-mud-data="' .. esc(data) .. '">'
        .. esc(label) .. '</div>'
end

local function render_settings()
    --[[
        The channel list is a single form with checkboxes, not a grid of
        click-to-toggle chips.

        Every click used to rebuild the whole widget, which threw the scroll
        position back to the top — unusable with forty-odd channels. A
        checkbox toggles in the browser with no round trip, and one Save
        applies the lot.
    ]]
    local body = '<div class="sec">Tabs</div><div class="row">'
    for _, t in ipairs(tabs()) do
        body = body .. '<div class="chip' .. (cfg.active == t and ' on' or '') .. '"'
            .. ' data-mud-action="tab" data-mud-data="' .. esc(t) .. '">' .. esc(t) .. '</div>'
    end
    body = body .. '</div>'

    body = body .. '<form>'
        .. '<input type="hidden" name="op" value="addtab">'
        .. '<input type="text" name="name" placeholder="New tab name" autocomplete="off">'
        .. '<button type="submit">Add tab</button>'
        .. '</form>'

    body = body .. '<div class="sec">Channels</div>'
        .. '<div class="legend">'
        .. '<b>Gag</b> hides it from the main game window &mdash; it still arrives here.<br>'
        .. '<b>Mute</b> stops capturing it here &mdash; it still shows in the game window.<br>'
        .. '<b>All</b> includes it in the combined tab.'

        .. '</div>'

    body = body .. '<form class="stack"><input type="hidden" name="op" value="channels">'
        .. '<div class="hdr"><span>channel</span><span>tab</span>'
        .. '<span class="cw">all</span><span class="cw">gag</span>'
        .. '<span class="cw">mute</span></div>'

    local rows = {}
    for _, name in ipairs(gmcp_channels()) do table.insert(rows, name) end

    local caps = capture_channels()
    if #caps > 0 then
        table.insert(rows, false)   -- divider marker
        for _, name in ipairs(caps) do table.insert(rows, name) end
    end

    for _, name in ipairs(rows) do
      if name == false then
        body = body .. '<div class="subhdr">custom &mdash; regex captures</div>'
      else
        local c   = chan_cfg(name)
        local cur = tab_of(name)

        local opts = ''
        for _, t in ipairs(tabs()) do
            if t ~= "All" then
                opts = opts .. '<option value="' .. esc(t) .. '"'
                    .. (string.lower(t) == string.lower(cur) and ' selected' or '') .. '>'
                    .. esc(t) .. '</option>'
            end
        end

        --[[
            'all' is checked when the channel appears in the combined view, so
            the box reads as an inclusion rather than a double negative. It is
            stored inverted (noall) because absent means included.
        ]]
        body = body .. '<label class="row chan">'
            .. '<span class="nm">' .. esc(name) .. '</span>'
            .. '<select name="tab:' .. esc(name) .. '">' .. opts .. '</select>'
            .. '<span class="cw"><input type="checkbox" name="all:' .. esc(name) .. '"'
            .. (c.noall ~= true and ' checked' or '') .. '></span>'
            .. '<span class="cw"><input type="checkbox" name="gag:' .. esc(name) .. '"'
            .. (c.gag == true and ' checked' or '') .. '></span>'
            .. '<span class="cw"><input type="checkbox" name="mute:' .. esc(name) .. '"'
            .. (c.off == true and ' checked' or '') .. '></span>'
            .. '</label>'
      end
    end

    body = body .. '<div class="row"><button type="submit">Save channels</button></div></form>'

    --[[
        Reuses the list from above rather than declaring another 'caps'. Lua
        allows shadowing a local in the same scope; the transpiler emits let
        and rejects it outright — "Cannot declare a let variable twice" fails
        the whole plugin load, not just that function.
    ]]
    if #caps > 0 then
        body = body .. '<div class="sec">Regex captures</div>'
        for _, capname in ipairs(caps) do
            local spec = cfg.capture[capname]
            body = body .. '<div class="row">'
                .. '<span class="nm">' .. esc(capname) .. '</span>'
                .. '<span class="pat">' .. esc(tostring(spec.pattern)) .. '</span>'
                .. chip("uncap", capname, "remove", false, true)
                .. '</div>'
        end
        body = body .. '<div class="legend">Captures route and gag from the channel '
            .. 'list above, same as any GMCP channel.</div>'
    end

    body = body .. '<div class="sec">Add a capture</div>'
        .. '<form>'
        .. '<input type="hidden" name="op" value="addcap">'
        .. '<input type="text" name="name" placeholder="name" autocomplete="off">'
        .. '<input type="text" name="tab" placeholder="tab" autocomplete="off">'
        .. '<input type="text" name="pattern" placeholder="regex" autocomplete="off">'
        .. '<button type="submit">Capture</button>'
        .. '</form>'

    return body
end

--[[
    Wall clock for the hover tooltip.

    os and io exist in the sandbox but are restricted implementations, so
    os.date gets probed once at load rather than trusted. Without it there is
    no timezone to work from — getCurrentTime is epoch milliseconds and nothing
    exposes the offset — so the fallback is elapsed time, which needs none.
    The panel re-renders on every message, so it stays close enough to honest.
]]
local STAMP_FMT = "%a %d %b %Y, %H:%M:%S"

local clockOk = false
do
    local ok, out = pcall(function() return os.date(STAMP_FMT) end)
    clockOk = ok and type(out) == "string" and out ~= ""
end

local function stamp(at)
    if type(at) ~= "number" then return "" end

    if clockOk then
        local ok, out = pcall(function() return os.date(STAMP_FMT, math.floor(at / 1000)) end)
        if ok and type(out) == "string" and out ~= "" then return out end
    end

    local secs = math.floor((getCurrentTime() - at) / 1000)
    if secs < 5  then return "just now" end
    if secs < 60 then return secs .. "s ago" end

    local mins = math.floor(secs / 60)
    if mins < 60 then return mins .. "m ago" end

    return math.floor(mins / 60) .. "h ago"
end

local function render()
    if not widget then return end

    --[[
        Counts per tab for the badges. All is counted with the same exclusion
        the list uses, not as a raw total — it read 51 while showing one line
        because every excluded INFO was still being tallied.
    ]]
    local counts, allCount = {}, 0
    for _, l in ipairs(lines) do
        counts[l.tab] = (counts[l.tab] or 0) + 1
        if chan_cfg(l.chan).noall ~= true then allCount = allCount + 1 end
    end

    local bar = ''
    for _, t in ipairs(tabs()) do
        local n = (t == "All") and allCount or (counts[t] or 0)
        bar = bar .. '<div class="tb' .. (cfg.active == t and ' on' or '') .. '"'
            .. ' data-mud-action="tab" data-mud-data="' .. esc(t) .. '">'
            .. esc(t) .. '<span class="n">' .. n .. '</span></div>'
    end

    --[[
        Newest first into a column-reverse flex body, so the view sits at the
        latest message without any scroll maths.
    ]]
    local body, shown = '', 0
    for i = #lines, 1, -1 do
        local l = lines[i]
        if visible(l) then
            -- title, not a CSS ::after tooltip: the body scrolls, and an
            -- absolutely positioned one gets clipped by the overflow
            local when = stamp(l.at)

            body = body .. '<div class="ln ' .. tab_class(l.tab)
                .. (l.gag and ' gagged' or '') .. '"'
                .. (when ~= "" and (' title="' .. esc(when) .. ' &middot; ' .. esc(l.chan) .. '"') or '')
                .. '>'
                .. '<span class="ch">' .. esc(l.chan) .. '</span>'
                .. esc(l.text) .. '</div>'
            shown = shown + 1
            if shown >= 200 then break end
        end
    end

    if shown == 0 then
        body = '<div class="empty">Nothing on ' .. esc(cfg.active) .. ' yet</div>'
    end

    local gear = '<div class="tb' .. (view == "settings" and ' on' or '') .. '"'
        .. ' data-mud-action="view" data-mud-data="'
        .. (view == "settings" and "chat" or "settings") .. '">'
        .. (view == "settings" and "&#9664; back" or "&#9881;") .. '</div>'

    if view == "settings" then
        setWidgetProperty(widget, "content", CSS
            .. '<div class="arc-ch">'
            .. '<div class="bar">' .. gear .. '</div>'
            .. '<div class="set">' .. render_settings() .. '</div>'
            .. '</div>')
        return
    end

    setWidgetProperty(widget, "content", CSS
        .. '<div class="arc-ch">'
        .. '<div class="bar">' .. bar .. gear .. '</div>'
        .. '<div class="body">' .. body .. '</div>'
        .. '</div>')
end

local function push(chan, text, who, gag)
    if type(text) ~= "string" then return end

    local clean = stripAnsiCodes(text)
    if type(clean) ~= "string" then clean = text end
    if clean == "" then return end

    table.insert(lines, {
        chan = chan,
        tab  = tab_of(chan),
        text = clean,
        who  = who,
        gag  = gag and true or false,
        at   = getCurrentTime(),
    })

    while #lines > MAX_LINES do table.remove(lines, 1) end
    render()
end

--[[
    A gagged channel's text still arrives in the terminal stream. Stash the
    stripped message when GMCP delivers it, then drop the matching line in
    onLine. Entries are consumed on match and aged out, so a message that
    never appears can't gag something unrelated later.
]]
local function arm_gag(text)
    if type(text) ~= "string" then return end

    local clean = stripAnsiCodes(text)
    if type(clean) ~= "string" then clean = text end
    if clean == "" then return end

    table.insert(pendingGag, { text = clean, at = getCurrentTime() })
    while #pendingGag > 40 do table.remove(pendingGag, 1) end
end

--[[
    Last message seen, to drop the duplicate.

    We subscribe under both comm.channel and Comm.Channel because the casing
    the client keys on isn't documented — but it fires BOTH handlers for one
    packet, so every message arrived twice. Same double-registration that had
    Core negotiating four times a login. Dropping one casing would work until
    a client keyed the other way, so instead the same channel and text inside
    a short window counts once. INFO was never doubled because a trigger is
    registered once.
]]
local lastMsg, lastAt = "", 0

local function on_channel(data)
    if type(data) ~= "table" then return end

    local chan = str(data.chan)
    local msg  = str(data.msg)
    if not chan or not msg then return end

    local key = chan .. "\0" .. msg
    local now = getCurrentTime()

    if key == lastMsg and (now - lastAt) < 300 then return end
    lastMsg, lastAt = key, now

    local c = chan_cfg(chan)
    if c.off == true then return end

    if c.gag == true then arm_gag(msg) end
    push(chan, msg, str(data.player), c.gag == true)
end

--[[
    Captures are matched in onLine now, not with a trigger, so this only
    tears down any trigger left over from an earlier version.

    omitFromOutput hides a line's text but keeps its row, so every gagged
    line left an empty gap — that was the whole source of the "blank lines"
    problem. /chat debug settled it: onLine fired 67 times and saw ZERO blank
    lines, with consecutive INFO lines and nothing between them. There was
    never a blank line in the stream to remove.

    Returning false from onLine drops the line outright, no gap. It also
    means a trigger can't do the capturing, because a discarded line fires no
    triggers — so onLine does both jobs: match, store, and decide whether the
    game window keeps it.
]]
local function arm_capture(name, spec)
    if custom[name] then
        removeTrigger(custom[name])
        custom[name] = nil
    end
end

local function arm_all_captures()
    for name, spec in pairs(cfg.capture) do
        arm_capture(name, spec)
    end
end

function init()
    --[[
        Declare the GMCP we need. Core owns Core.Supports.Set — it replaces
        the server's record rather than merging, so only one plugin may send
        it — and builds the union from these. Needs: comm.channel.
    ]]
    broadcastPlugin("aw-gmcp", "Comm")

    widget = createWidget({
        type     = "html",
        name     = "comms",
        title    = "Comms",
        position = { x = 1180, y = 120 },
        size     = { width = 420, height = 360 },
    })

    --[[
        The world variable is the fallback, and in practice the one that saves
        you: a remove-and-re-add — how every update here is installed — takes
        the plugin's saveTable rows with it, so on an update this is the only
        copy left.
    ]]
    local saved = loadTable("aw_chat")

    if type(saved) ~= "table" then
        local ok, raw = pcall(function() return getVariable(VAR) end)
        if ok and type(raw) == "string" and raw ~= "" then
            local dok, data = pcall(json.decode, raw)
            if dok and type(data) == "table" then
                saved = data
                utilprint(TAG .. "settings restored from the last install.")
            end
        end
    end

    if type(saved) == "table" then
        if type(saved.tabs) == "table" and #saved.tabs > 0 then cfg.tabs = saved.tabs end
        if str(saved.active) then cfg.active = saved.active end
        if type(saved.chan) == "table" then cfg.chan = saved.chan end
        if type(saved.capture) == "table" then cfg.capture = saved.capture end
        if saved.seeded == true then cfg.seeded = true end
    end

    --[[
        Seed the non-GMCP captures once, ever.

        This used to key off an empty capture table, which meant it re-ran on
        any load where the saved config didn't come back — and it force-set
        INFO's gag to true each time, silently undoing an unticked box. A
        one-way flag makes it a genuine first-run step; defaults are a
        starting point, not something reapplied behind the player's back.
    ]]
    -- the backup is only written on save, so a fresh install has none until
    -- you happen to change something. Write it once, now.
    save_cfg()
    if cfg.seeded ~= true then
        cfg.seeded = true

        for name, spec in pairs(DEFAULT_CAPTURES) do
            if cfg.capture[name] == nil then
                cfg.capture[name] = { pattern = spec.pattern, tab = spec.tab }
                CHANNEL_TAB[name] = spec.tab

                -- only when the player has expressed no opinion yet
                local c = chan_cfg(name)
                if c.gag ~= true and c.gag ~= false then
                    c.gag = spec.gag and true or false
                end
            end
        end

        save_cfg()
    end

    --[[
        Matches a line that is empty or only whitespace. Created disabled;
        a gag turns it on for one line, and it turns itself off again.
    ]]
    blankTrigger = addTrigger("^\\s*$", function()
        dbg.blankTrig = dbg.blankTrig + 1
        if blankTrigger then disableTrigger(blankTrigger) end
    end, { type = "regex", enabled = false, omitFromOutput = true, keepEvaluating = false })

    if blankTrigger then disableTrigger(blankTrigger) end

    onGMCPUpdate("comm.channel", on_channel)
    onGMCPUpdate("Comm.Channel", on_channel)

    registerWidgetEvent(widget, "action", function(data)
        if type(data) ~= "table" then return end

        local act = tostring(data.action or "")
        local arg = tostring(data.data or "")

        if act == "tab" then
            local t = has_tab(arg)
            if not t then return end
            cfg.active = t

        elseif act == "view" then
            view = (arg == "settings") and "settings" or "chat"

        elseif act == "cycle" then
            -- step the channel to the next tab, skipping All
            local list, cur, idx = tabs(), tab_of(arg), nil
            for i, t in ipairs(list) do
                if string.lower(t) == string.lower(cur) then idx = i end
            end

            local n = #list
            for step = 1, n do
                local cand = list[((idx or 1) + step - 1) % n + 1]
                if cand ~= "All" then
                    chan_cfg(arg).tab = cand
                    for _, l in ipairs(lines) do
                        if l.chan == arg then l.tab = cand end
                    end
                    break
                end
            end

        elseif act == "gag" then
            local c = chan_cfg(arg)
            c.gag = not c.gag

            -- the trigger bakes in omitFromOutput, so re-arm from cfg.chan
            local cap = cfg.capture[arg]
            if type(cap) == "table" then arm_capture(arg, cap) end

        elseif act == "mute" then
            local c = chan_cfg(arg)
            c.off = not c.off

        elseif act == "uncap" then
            if custom[arg] then
                removeTrigger(custom[arg])
                custom[arg] = nil
            end
            cfg.capture[arg] = nil

        else
            return
        end

        save_cfg()
        render()
    end)

    --[[
        Form submits carry every named field in formData, which is how text
        entry works without any JavaScript in the widget. The hidden 'op'
        field identifies which form fired.
    ]]
    registerWidgetEvent(widget, "submit", function(data)
        if type(data) ~= "table" then return end

        local f = data.formData
        if type(f) ~= "table" then return end

        local op = str(f.op)
        if not op then return end

        if op == "addtab" then
            local name = str(f.name)
            if not name then return end

            if has_tab(name) then
                utilprint(TAGR .. "'" .. name .. "' already exists.")
                return
            end

            local list = {}
            for _, t in ipairs(tabs()) do table.insert(list, t) end
            table.insert(list, name)

            cfg.tabs = list
            utilprint(TAG .. "added tab " .. name)

        elseif op == "channels" then
            --[[
                An unchecked checkbox is simply absent from formData, so
                presence is the value. Booleans are written as real true or
                false rather than left nil, because a nil that round-trips
                through storage comes back as JS undefined — which is truthy.
            ]]
            for _, name in ipairs(all_channels()) do
                local c = chan_cfg(name)

                c.gag   = (f["gag:"  .. name] ~= nil)
                c.off   = (f["mute:" .. name] ~= nil)
                c.noall   = (f["all:"    .. name] == nil)

                local t = str(f["tab:" .. name])
                if t and has_tab(t) then
                    c.tab = has_tab(t)
                    for _, l in ipairs(lines) do
                        if l.chan == name then l.tab = c.tab end
                    end
                end

                -- a capture bakes its gag into the trigger, so re-arm it
                local cap = cfg.capture[name]
                if type(cap) == "table" then arm_capture(name, cap) end
            end

            utilprint(TAG .. "channel settings saved.")

        elseif op == "addcap" then
            local name    = str(f.name)
            local tab     = str(f.tab)
            local pattern = str(f.pattern)

            if not name or not pattern then
                utilprint(TAGR .. "a capture needs a name and a regex.")
                return
            end

            local t = tab and has_tab(tab) or "Chat"
            if tab and not has_tab(tab) then
                utilprint(TAGR .. "no tab '" .. tab .. "' — filed under Chat.")
                t = "Chat"
            end

            local spec = { pattern = pattern, tab = t, gag = false }
            cfg.capture[string.lower(name)] = spec
            CHANNEL_TAB[string.lower(name)] = t
            arm_capture(string.lower(name), spec)

            utilprint(TAG .. "capturing '" .. pattern .. "' as " .. name .. " -> " .. t)
        else
            return
        end

        save_cfg()
        render()
    end)

    arm_all_captures()
    render()
end

--[[
    Drop terminal lines whose text GMCP already handed us on a gagged channel.
    Returning false discards the line entirely — no display, no triggers.
]]
function onLine(sessionId, rawLine, cleanLine)
    local line = cleanLine
    if type(line) ~= "string" then line = stripAnsiCodes(rawLine) end
    if type(line) ~= "string" then return end

    dbg.lines = dbg.lines + 1

    table.insert(dbg.last, string.sub(line, 1, 40))
    while #dbg.last > 8 do table.remove(dbg.last, 1) end

    local now = getCurrentTime()

    --[[
        Regex captures. Patterns are JavaScript regex here, same as trigger
        patterns, and a bad one from the user would otherwise throw on every
        single line — hence the pcall.
    ]]
    for name, spec in pairs(cfg.capture) do
        if type(spec) == "table" and str(spec.pattern) then
            local c = chan_cfg(name)

            if c.off ~= true then
                local ok, hit = pcall(string.match, line, spec.pattern)

                if ok and hit then
                    push(name, line, nil, c.gag == true)

                    if c.gag == true then
                        dbg.gagged = dbg.gagged + 1
                        -- arm for the blank that follows this line
                        if blankTrigger then enableTrigger(blankTrigger) end
                        return false
                    end

                    break
                end
            end
        end
    end

    if #pendingGag == 0 then return end

    for i = #pendingGag, 1, -1 do
        local p = pendingGag[i]

        if (now - p.at) > 4000 then
            table.remove(pendingGag, i)
        elseif p.text == line then
            table.remove(pendingGag, i)
            dbg.gagged = dbg.gagged + 1
            return false
        end
    end
end

local function report()
    utilprint(TAG .. "tabs: " .. table.concat(tabs(), ", ") .. "   active: " .. cfg.active)

    local gagged, off = {}, {}
    for name, c in pairs(cfg.chan) do
        if type(c) == "table" then
            if c.gag == true then table.insert(gagged, name) end
            if c.off == true then table.insert(off, name) end
        end
    end

    utilprint(TAG .. "gagged: " .. (#gagged > 0 and table.concat(gagged, ", ") or "none"))
    utilprint(TAG .. "muted:  " .. (#off > 0 and table.concat(off, ", ") or "none"))

    local caps = {}
    for name, spec in pairs(cfg.capture) do
        if type(spec) == "table" then
            table.insert(caps, name .. " -> " .. tostring(spec.tab or "Chat"))
        end
    end
    utilprint(TAG .. "captures: " .. (#caps > 0 and table.concat(caps, ", ") or "none"))
end

registerCommand("chat", function(args)
    local a   = argv(args)
    local sub = a[1] and string.lower(a[1]) or ""

    if sub == "" or sub == "show" then
        report()
        utilprint("$w  /chat tab add <name>          add a tab")
        utilprint("$w  /chat tab del <name>          remove a tab")
        utilprint("$w  /chat move <channel> <tab>    route a channel to a tab")
        utilprint("$w  /chat gag <channel> on|off    hide it from the main window")
        utilprint("$w  /chat mute <channel> on|off   stop capturing it entirely")
        utilprint("$w  /chat capture <name> <tab> <regex>   capture a non-GMCP channel")
        utilprint("$w  /chat uncapture <name>")
        utilprint("$w  /chat clear")
        utilprint("$w  /chat debug                    is onLine firing? is the gag landing?")
        return
    end

    if sub == "debug" then
        utilprint(TAG .. "onLine fired " .. dbg.lines .. " times"
            .. (dbg.lines == 0 and "  $R<- onLine is NOT being called$w" or ""))
        utilprint(TAG .. "gags dropped " .. dbg.gagged .. ", pending " .. #pendingGag)
        utilprint(TAG .. "blank trigger fired " .. dbg.blankTrig .. " times"
            .. (dbg.gagged > 0 and dbg.blankTrig == 0
                and "  $R<- triggers don't see blank lines either$w" or ""))
        utilprint(TAG .. "timestamps: " .. (clockOk and ("os.date, " .. stamp(getCurrentTime()))
            or "$Rno os.date — falling back to elapsed$w"))
    --[[
        Does the world variable actually round-trip? Everything surviving an
        update rests on it, and setVariable's behaviour here is unverified.
    ]]
    local vok, vraw = pcall(function() return getVariable(VAR) end)
    utilprint(TAG .. "settings backup: "
        .. ((vok and type(vraw) == "string" and vraw ~= "")
            and ("$Gstored, " .. string.len(vraw) .. " bytes$w")
            or "$Rnot stored — an update will reset these settings$w"))

        utilprint(TAG .. "last lines seen:")
        for _, l in ipairs(dbg.last) do utilprint("$w    " .. l) end
        return
    end

    if sub == "clear" then
        lines = {}
        render()
        utilprint(TAG .. "cleared.")
        return
    end

    if sub == "tab" then
        local op   = a[2] and string.lower(a[2]) or ""
        local name = a[3]

        if not str(name) then
            utilprint(TAGR .. "/chat tab add|del <name>")
            return
        end

        local list = {}
        for _, t in ipairs(tabs()) do table.insert(list, t) end

        if op == "add" then
            if has_tab(name) then
                utilprint(TAGR .. "'" .. name .. "' already exists.")
                return
            end
            table.insert(list, name)
        elseif op == "del" then
            if string.lower(name) == "all" then
                utilprint(TAGR .. "the All tab can't be removed.")
                return
            end

            local out = {}
            for _, t in ipairs(list) do
                if string.lower(t) ~= string.lower(name) then table.insert(out, t) end
            end
            list = out

            if cfg.active ~= "All" and string.lower(cfg.active) == string.lower(name) then
                cfg.active = "All"
            end
        else
            utilprint(TAGR .. "/chat tab add|del <name>")
            return
        end

        cfg.tabs = list
        save_cfg()
        render()
        utilprint(TAG .. "tabs: " .. table.concat(list, ", "))
        return
    end

    if sub == "move" then
        local chan, tab = a[2], a[3]
        if not str(chan) or not str(tab) then
            utilprint(TAGR .. "/chat move <channel> <tab>")
            return
        end

        local t = has_tab(tab)
        if not t then
            utilprint(TAGR .. "no tab called '" .. tab .. "'. Add it first.")
            return
        end

        chan_cfg(string.lower(chan)).tab = t

        -- retag anything already in the buffer so the move is visible at once
        for _, l in ipairs(lines) do
            if l.chan == string.lower(chan) then l.tab = t end
        end

        save_cfg()
        render()
        utilprint(TAG .. chan .. " -> " .. t)
        return
    end

    if sub == "gag" or sub == "mute" then
        local chan = a[2] and string.lower(a[2]) or ""
        local on   = a[3] and string.lower(a[3]) or "on"

        if chan == "" then
            utilprint(TAGR .. "/chat " .. sub .. " <channel> on|off")
            return
        end

        local val = (on ~= "off" and on ~= "false" and on ~= "0")
        local c   = chan_cfg(chan)

        if sub == "gag" then c.gag = val else c.off = val end

        --[[
            A capture owns its own trigger, so gagging it is omitFromOutput
            rather than the GMCP message-matching path — re-arm to apply it.
        ]]
        local cap = cfg.capture[chan]
        if type(cap) == "table" and sub == "gag" then arm_capture(chan, cap) end

        save_cfg()
        render()
        utilprint(TAG .. chan .. " " .. sub .. " " .. (val and "on" or "off"))
        return
    end

    if sub == "capture" then
        local name, tab = a[2], a[3]

        if not str(name) or not str(tab) or not a[4] then
            utilprint(TAGR .. "/chat capture <name> <tab> <regex>")
            return
        end

        local t = has_tab(tab)
        if not t then
            utilprint(TAGR .. "no tab called '" .. tab .. "'. Add it first.")
            return
        end

        -- everything past the tab is the pattern, spaces and all
        local parts = {}
        for i = 4, #a do table.insert(parts, a[i]) end

        local spec = { pattern = table.concat(parts, " "), tab = t, gag = false }
        cfg.capture[string.lower(name)] = spec
        CHANNEL_TAB[string.lower(name)] = t

        arm_capture(string.lower(name), spec)
        save_cfg()
        utilprint(TAG .. "capturing '" .. spec.pattern .. "' as " .. name .. " -> " .. t)
        return
    end

    if sub == "uncapture" then
        local name = a[2] and string.lower(a[2]) or ""

        if cfg.capture[name] == nil then
            utilprint(TAGR .. "no capture called '" .. name .. "'")
            return
        end

        if custom[name] then
            removeTrigger(custom[name])
            custom[name] = nil
        end

        cfg.capture[name] = nil
        save_cfg()
        utilprint(TAG .. "dropped capture " .. name)
        return
    end

    utilprint(TAGR .. "unknown option '" .. sub .. "' — /chat for help")
end, "Channel panel: tabs, routing, gagging and custom captures")
