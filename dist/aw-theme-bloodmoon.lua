--[[
    aw-theme-bloodmoon.lua
    Sean Stoves (Solao) — 2026-08-03

    Dark theme built from Aardwolf's own branding rather than a borrowed one.

    Pulled off aardwolf.com: their site runs on brick red #931918 (by far the
    dominant colour) over parchment tans #D7C4A4 / #DDC9AE, and the masthead is
    a howling wolf medallion against a blood-red sky with a pale moon, wrapped
    in black tribal filigree. That's where the name comes from and where every
    colour below traces back to.
]]

plugin = {
    id          = "aw-theme-bloodmoon",
    name        = "Blood Moon",
    version     = "1.0.4",
    author      = "Solao",
    description = "Dark Aardwolf theme in the MUD's own brick red, parchment and steel.",
    settings    = { saveState = true },
}

-- @category themes

--[[
    Every diagnostic line carries the running version. Chasing a bug that
    was already fixed on disk cost several rounds — the output has to say
    which build is actually answering.
]]
local TAG  = "$Y[Blood Moon v" .. plugin.version .. "]$w "
local TAGR = "$R[Blood Moon v" .. plugin.version .. "]$w "

local THEME_ID = "bloodmoon"

--[[
    Colours are bare "H S% L%" triples — MudForge stores them as shadcn CSS
    custom properties and wraps them in hsl() itself. Anything left out falls
    back to the built-in dark theme.
]]
local theme = {
    id   = THEME_ID,
    name = "Blood Moon",

    colors = {
        -- near-black, warmed very slightly so it sits under the reds
        background          = "0 14% 5%",
        foreground          = "35 34% 78%",   -- parchment #D7C4A4, dimmed for a dark bg

        card                = "0 12% 8%",
        cardForeground      = "35 34% 78%",
        popover             = "0 14% 6%",
        popoverForeground   = "35 34% 78%",

        -- Aardwolf brick red #931918, lifted a little so small text stays legible
        primary             = "0 72% 42%",
        primaryForeground   = "35 40% 88%",

        secondary           = "0 10% 14%",
        secondaryForeground = "35 28% 72%",

        muted               = "0 8% 12%",
        mutedForeground     = "35 14% 52%",

        -- pale moon off the masthead — the one cool note in the set
        accent              = "40 34% 72%",
        accentForeground    = "0 14% 8%",

        destructive         = "0 72% 45%",
        destructiveForeground = "35 40% 90%",

        border              = "0 22% 17%",
        input               = "0 10% 13%",
        ring                = "0 72% 42%",
    },

    terminalBackground = "#0a0707",
    terminalColors = {
        foreground          = "#d7c4a4",   -- Aardwolf parchment, straight off the site
        cursor              = "#c0392f",
        selectionBackground = "#3a1a18",

        black         = "#0a0707",
        red           = "#931918",         -- the brand red itself
        green         = "#6f8f4a",
        yellow        = "#c8963c",
        blue          = "#4a6c96",
        magenta       = "#8a5a78",
        cyan          = "#4f8f8a",
        white         = "#d7c4a4",

        brightBlack   = "#5c4a42",
        brightRed     = "#c0392f",
        brightGreen   = "#9dc26a",
        brightYellow  = "#e8bf5c",
        brightBlue    = "#6f9bd1",
        brightMagenta = "#c07f9e",
        brightCyan    = "#78c4bd",
        brightWhite   = "#f2e7d2",
    },

    glassmorphism = {
        enabled         = true,
        blur            = "14px",
        cardOpacity     = 0.86,
        borderOpacity   = 0.22,
        shadowIntensity = "0 4px 30px rgba(0, 0, 0, 0.7)",
        radius          = "4px",
        glowColor       = "rgba(147, 25, 24, 0.20)",
        frostedHeader   = true,
    },
}

local function apply()
    local id = registerTheme(theme)
    if not id then
        utilprint(TAGR .. "theme rejected by the client — check the log for the validator message.")
        return false
    end

    setTheme(id)
    return true
end

function init()
    if apply() then
        utilprint(TAG .. "applied.")
    end
end

-- Handy while tuning colours with the file watcher running.
registerCommand("bloodmoon", function()
    apply()
end, "Re-apply the Blood Moon theme")
