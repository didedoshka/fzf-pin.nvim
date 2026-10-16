# fzf-pin.nvim

Machinery for pinning things to single chars and reaching them through one fzf-lua picker.
No built-in sources, no setup(), no keymaps: a consumer defines a *source* and maps a key to
`require("fzf-pin").pick(source)`.

## The picker

`pick(source)` opens an fzf-lua window listing every item from `source.list()`, pinned ones
rendered `[e] label`, unpinned ones indented. While the window is fresh, every lowercase char
except `i`, plus every verb char, is a live bind:

| key         | effect                                                                    |
| ----------- | ------------------------------------------------------------------------- |
| pinned char | `source.activate(item)`, the window closes                                |
| verb char   | runs `source.verbs[char]`, the window closes                              |
| free char   | `source.pin(char, highlighted item)`, the list reloads, the window stays  |
| `i`         | unbinds every char: from here it is a plain fuzzy picker, type to search  |
| `enter`     | `source.activate(selected item)`, the window closes                       |
| `ctrl-x`    | `source.unpin(selected item)`, the list reloads, the window stays         |
| `esc`       | one state back: search → chars over the matches → whole list → closed     |

Verb chars come in any case: uppercase ones leave the whole lowercase alphabet to pins.
Out of search, `esc` keeps the query: the chars act on the matches found, so a free char pins
the highlighted match. The next `esc` clears the query, the one after closes the window.

`pin` and `unpin` return what to tell the user, and the picker shows it in fzf's footer while
the window stays up -- a pin made, or why not (`i` and `esc` clear it). A source without `pin`
gets `nothing on <char>` there.

Activation and verbs run once the window has closed and, when the picker was opened from a
terminal's normal mode, once fzf-lua has put that mode back -- so a picker they open starts in
terminal mode and closes into normal mode.

Moving a pin is `ctrl-x` then re-pinning; there is no dedicated move.
A source with `preview` gets fzf-lua's file/buffer preview window for the highlighted item.
The picker opts out of fzf-lua's "hide" profile (`no_hide`): closing it really
closes, nothing lingers for resume.
Uppercase and digits that are not verbs are not bound and type into the query even before `i`
-- proper search starts with `i`.

## Source contract

```lua
---@class fzfpin.Source
---@field prompt string
---@field list fun(): fzfpin.Item[]        -- ordered; pinned items conventionally first
---@field activate fun(item)
---@field pin? fun(char, item): string?    -- pin the highlighted item (nil: none) to char
---@field unpin? fun(item): string?        -- ctrl-x; the list reloads in place afterwards
---@field verbs? table<string, fun()>      -- reserved chars (any case), never pinnable
---@field preview? fun(item): { path?: string, bufnr?: integer, line?: integer }
--                                         -- what the preview shows, centred on line
-- pin/unpin return the footer text (or nil for none)

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
