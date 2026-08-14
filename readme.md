# fzf-pin.nvim

Machinery for pinning things to single chars and reaching them through one fzf-lua picker.
No built-in sources, no setup(), no keymaps: a consumer defines a *source* and maps a key to
`require("fzf-pin").pick(source)`.

## The picker

`pick(source)` opens an fzf-lua window listing every item from `source.list()`, pinned ones
rendered `[e] label`, unpinned ones indented. While the window is fresh, every lowercase char
except `i` is a live bind:

| key | effect |
| --- | --- |
| pinned char | `source.activate(item)` immediately |
| verb char (`source.verbs`) | runs the verb |
| free char | `source.pin(char)` -- pins "the current thing" (warns if the source has no `pin`) |
| `i` | unbinds every char: from here it is a plain fuzzy picker, type to search |
| `enter` | `source.activate(selected item)` |
| `ctrl-x` | `source.unpin(selected item)`, then the list reloads in place -- the window stays open |
| `esc` | after `i`: back to the bound-chars state, query cleared -- as if `i` was never pressed; otherwise close |

Moving a pin is `ctrl-x` then re-pinning; there is no dedicated move.
The picker opts out of fzf-lua's "hide" profile (`no_hide`): closing it really
closes, nothing lingers for resume.
Uppercase and digits are not bound and type into the query even before `i` -- proper search
starts with `i`.

## Source contract

```lua
---@class fzfpin.Source
---@field prompt string
---@field list fun(): fzfpin.Item[]        -- ordered; pinned items conventionally first
---@field activate fun(item)
---@field pin? fun(char)                   -- pin the current thing to char
---@field unpin? fun(item)                 -- ctrl-x; the list reloads in place afterwards
---@field verbs? table<string, fun()>      -- reserved chars, never pinnable

---@class fzfpin.Item
---@field label string                     -- display label, unique within the source
---@field char string|nil
---@field data any
```

## Store

`require("fzf-pin.store")` persists pin maps as JSON, one file per namespace under
`stdpath("state")/fzf-pin/`. `load(ns)` returns a table (empty when missing or corrupt),
`save(ns, tbl)` writes it back. The shape inside is the source's business.

## Verify

`tests/run.sh` -- `lua-language-server --check` (baseline 0 problems, run from the repo root)
plus the offline spec on `nvim --clean`. The picker's `open()` needs a real UI and fzf-lua;
the spec drives `build()` instead.
