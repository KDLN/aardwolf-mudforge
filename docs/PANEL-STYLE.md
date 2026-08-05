# Panel style

Every panel in this set should look like it came from the same hand. This is
what that means concretely, written down because it had already drifted twice
by the ninth plugin — Shop shipped with native `<button>` elements sitting
next to Players' outlined ones, and `.tb` had two different letter-spacings
depending on which file you copied from.

Read this alongside **[MUDFORGE-API-GUIDE.md](MUDFORGE-API-GUIDE.md)**, which
is the authority on what the client can do. This file is only about what we
choose to do with it.

---

## Never use a native control

No `<button>`, no `<input>`, no `<select>`. They render with the browser's own
chrome — big, pale, square — and nothing else on the panel looks like that.

They also can't be read without a `<form>`, and a form can't tell you which
control was pressed: **every submit button's value comes back on every
submit**, so a footer button arrives carrying a row button's value. That cost
the Shop a redesign. Use `data-mud-action` divs, which each own exactly one
action and can't be confused for one another.

Text entry is the one exception, because there is no other way to type into a
panel — Players' search box is a real `<input>` inside a real `<form>`. Style
it explicitly when you do.

---

## The shared vocabulary

Prefix every class with the panel's own root (`.arc-w`, `.arc-snd`, `.arc-ch`,
`.arc-port`, `.arc-v`, `.arc-gr`) so two panels can't collide.

### `.tb` — a control in a bar

Toggles, view switches, actions that live in the header or a settings row.

```css
.arc-X .tb {
    font-size: 8px; letter-spacing: 0.13em; text-transform: uppercase;
    padding: 3px 7px; border-radius: 2px;
    border: 1px solid hsl(var(--border, 0 22% 17%));
    color: hsl(var(--muted-foreground, 35 14% 52%));
    cursor: pointer; user-select: none; white-space: nowrap;
}
.arc-X .tb:hover { color: hsl(var(--foreground, 35 34% 78%)); }
.arc-X .tb.on {
    color: hsl(var(--primary, 0 72% 42%));
    border-color: hsl(var(--primary, 0 72% 42%));
    background: rgba(147,25,24,0.12);
}
```

`.on` means *currently true*, not *currently hovered*. A toggle showing its
state uses it; a plain action never does.

### `.go` — an action attached to a row

`WHOIS` beside a name, `HUNT` beside a target. Smaller than `.tb`, and drawn
in the primary colour because it does something rather than sets something.

```css
.arc-X .go {
    font-size: 7px; letter-spacing: 0.13em; text-transform: uppercase;
    padding: 1px 6px; border-radius: 2px; line-height: 1.4;
    border: 1px solid hsl(var(--primary, 0 72% 42%));
    color: hsl(var(--primary, 0 72% 42%));
    cursor: pointer; user-select: none; white-space: nowrap;
}
.arc-X .go:hover { background: rgba(147,25,24,0.25); }
```

### `.chip` — a label, not a control

No `cursor: pointer`, no hover. If it isn't clickable it must not look
clickable.

### `.sec` — a settings heading

```css
.arc-X .sec {
    font-size: 8px; letter-spacing: 0.18em; text-transform: uppercase;
    color: hsl(var(--primary, 0 72% 42%));
    margin: 10px 0 5px; padding-bottom: 4px;
    border-bottom: 1px solid hsl(var(--border, 0 22% 17%));
}
```

### `.note` — explanatory text under a setting

9px, muted. Say what the setting does and why you'd want it, not what it is.

---

## Colour

Themeable first, with a fallback for when the variable isn't there:

| use | value |
|---|---|
| body text | `hsl(var(--foreground, 35 34% 78%))` |
| secondary text | `hsl(var(--muted-foreground, 35 14% 52%))` |
| accent, active, actions | `hsl(var(--primary, 0 72% 42%))` |
| borders | `hsl(var(--border, 0 22% 17%))` |
| panel fill | `hsl(var(--card, 0 12% 8%))` |
| accent wash | `rgba(147,25,24,0.12)` — `0.25` on hover |

Literal hex is for things that mean something in the game and shouldn't follow
the theme: `#86c48f` for a level, the item colours Shop reads off the line.

**Inline colour is stripped by the sanitiser.** Vary colour with a class, and
generate the rules into the one `<style>` element if the palette is dynamic —
that's how Shop paints item names.

---

## Settings live behind the gear

`&#9881;` to go in, `&#9664; back` to come out, top-right of the panel's own
bar, styled as `.tb` with `.on` while open.

```lua
.. '<div class="tb' .. (view ~= "list" and " on" or "")
.. '" data-mud-action="view" title="settings">'
.. (view ~= "list" and "&#9664; back" or "&#9881;") .. '</div>'
```

Anything that isn't the main view goes *back to the main view* — a panel with
three views whose gear only knows two will strand you on the third.

---

## Chrome

Declare the client's title bar off at creation. Every panel draws its own
header, so the client's is a second title saying the same thing:

```lua
appearance = {
    showTitleBar        = false,
    autoHideSettingsCog = true,
},
```

This is a plugin *default*, not a lock — the user can turn it back on in the
cog, and `autoHideSettingsCog` keeps that cog reachable on hover. With the bar
hidden you drag the panel by its top edge.

A panel that hides itself needs its own way back into view, labelled as a
word rather than a glyph, because with no title bar it is the only one.

---

## Don't repaint to change a number

A full `setWidgetProperty` rebuild resets scroll position. Anything that
updates faster than the user interacts — a count, a total, a timer — gets
`data-mud-bind="key"` and `setBoundValue(widget, key, text)` instead. Shop's
quantities and total work this way; without it, pressing `+` on the fortieth
row throws you back to the first.
