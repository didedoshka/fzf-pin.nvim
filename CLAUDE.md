# fzf-pin.nvim -- session rules

Shared pin-to-char picker machinery; personal project, single user, loaded from this
checkout via lazy.nvim. Consumers: the config's bookmarks source (`s`), litre's task
layer (`x`), no-tmux's server picker (`<CR>`).

- **`readme.md` is the spec** -- it documents shipped behaviour precisely and any
  behaviour change is incomplete until it matches.
- This plugin is machinery only: no sources, no keymaps, no setup(), no opinions about
  what gets pinned. Features live in the consumers; resist pulling them in here.
- `picker.build()` is pure (no fzf-lua) so the spec can drive it offline; only `open()`
  may touch fzf-lua. Keep that split.

## Verify

`tests/run.sh` (offline, ~1s): `lua-language-server --check` from the repo root
(baseline **0 problems**) + the spec on `nvim --clean -l` (the only Lua runtime on this
box). Real picker interaction needs a live UI -- say so when a change is verified only
by the suite.

## Style

4-space indent, double quotes, ~100 cols; formatting via lua_ls/EmmyLuaCodeStyle from
`.luarc.json` -- no stylua. Comments explain *why*, never the next line. Commit each
verified change without asking (`area: lowercase summary`,
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`). Never rewrite history -- no
amend, rebase, or reset past a commit; fix forward with a new commit.
