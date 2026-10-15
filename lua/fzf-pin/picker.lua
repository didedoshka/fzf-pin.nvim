-- The one picker: an fzf-lua window listing items, some carrying a single-char
-- pin. While chars are bound, pressing a pinned char activates its item, a verb
-- char runs its verb, and a free char pins the current thing. `i` unbinds every
-- char and turns the window into a plain fuzzy picker; `esc` undoes `i` (back
-- to bound chars, query cleared), and only closes from the bound state.
local M = {}

-- pinnable alphabet: lowercase minus `i`, which is reserved for entering search
M.chars = "abcdefghjklmnopqrstuvwxyz"

M.header = "[i] search  [C-x] unpin"
local search_prompt = "search> "

---@class fzfpin.Item
---@field label string display label, unique within the source
---@field char string|nil the char this item is pinned to
---@field data any

---@class fzfpin.Source
---@field prompt string
---@field list fun(): fzfpin.Item[] ordered; pinned items conventionally first
---@field activate fun(item: fzfpin.Item)
---@field pin? fun(char: string, item: fzfpin.Item|nil) pin the current thing, or the
---highlighted item for a source with no "current"; absent means free chars warn
---@field unpin? fun(item: fzfpin.Item) ctrl-x; the list reloads in place afterwards
---@field verbs? table<string, fun()> chars reserved by the source, never pinnable
---@field preview? fun(item: fzfpin.Item): { path?: string, bufnr?: integer, line?: integer }|nil
---what the preview window shows for an item, centred on line; absent means no preview window

local function display(item)
    return (item.char and ("[%s] "):format(item.char) or "    ") .. item.label
end

-- Build everything fzf_exec needs, without touching fzf-lua: the entries
-- function, the actions table and the `i`/`esc` binds. Pure, so the offline
-- spec can drive it.
---@param source fzfpin.Source
function M.build(source)
    local by_char, by_display = {}, {}

    -- re-lists on every call: fzf's reload after ctrl-x re-runs this, so the
    -- lookup maps always match what the window shows
    local listed = false
    local function entries()
        listed = true
        by_char, by_display = {}, {}
        local lines = {}
        for _, item in ipairs(source.list()) do
            local line = display(item)
            by_display[line] = item
            if item.char then
                by_char[item.char] = item
            end
            table.insert(lines, line)
        end
        return lines
    end

    local function on_char(c, selected)
        -- a char typed in one chord with the layer key reaches fzf before it
        -- has pulled the list: with the maps still empty a pinned char would
        -- pass for free and pin over it (measured under a pty, `sa` at once)
        if not listed then
            entries()
        end
        if source.verbs and source.verbs[c] then
            source.verbs[c]()
        elseif by_char[c] then
            source.activate(by_char[c])
        elseif source.pin then
            source.pin(c, selected and selected[1] and by_display[selected[1]])
        else
            vim.notify(source.prompt .. "nothing on " .. c, vim.log.levels.WARN)
        end
    end

    local actions = {
        ["enter"] = function(selected)
            local item = selected[1] and by_display[selected[1]]
            if item then
                source.activate(item)
            end
        end,
        -- reload instead of close-and-reopen: the window stays up and fzf
        -- re-runs `entries` once the unpin has been applied
        ["ctrl-x"] = {
            fn = function(selected)
                local item = selected[1] and by_display[selected[1]]
                if item and source.unpin then
                    source.unpin(item)
                end
            end,
            reload = true,
        },
    }
    local bound = { "i" }
    for c in M.chars:gmatch(".") do
        actions[c] = function(selected)
            on_char(c, selected)
        end
        table.insert(bound, c)
    end
    -- verbs outside the alphabet (uppercase, say) get their own binds, so a
    -- source can keep every lowercase char free for pins. fzf-lua lowercases
    -- every key in `actions` and `keymap` (its #654), so these go to fzf raw
    -- through `fzf_args`, printing an underscore action name: fzf-lua never
    -- binds those itself but still dispatches them on exit (measured)
    local extra = vim.tbl_filter(function(k)
        return not actions[k]
    end, vim.tbl_keys(source.verbs or {}))
    table.sort(extra)
    local raw_binds = {}
    for _, k in ipairs(extra) do
        local name = "_verb_" .. k:lower()
        actions[name] = function()
            on_char(k)
        end
        table.insert(raw_binds, ("--bind=%s:print(%s)+accept"):format(k, name))
        table.insert(bound, k)
    end
    local keys = table.concat(bound, ",")

    -- `i` returns every char to ordinary typing; the prompt swap is also the
    -- mode flag `esc` reads back through $FZF_PROMPT
    local search = ("unbind(%s)+change-prompt(%s)+change-header(type to search  [esc] back)")
        :format(keys, search_prompt)
    local restore = ("clear-query+change-prompt(%s)+change-header(%s)+rebind(%s)")
        :format(source.prompt, M.header, keys)
    -- esc undoes `i` while searching and only aborts from the bound state;
    -- the test is POSIX-sh and fish compatible (fzf runs it with $SHELL -c)
    local esc = ('transform:[ "$FZF_PROMPT" = "%s" ] && echo "%s" || echo "abort"')
        :format(search_prompt, restore)

    return {
        entries = entries,
        item = function(line)
            return by_display[line]
        end,
        actions = actions,
        keymap = { i = search, esc = esc },
        raw_binds = raw_binds, -- unescaped fzf arguments, one per bind
    }
end

-- fzf-lua's file/buffer previewer, fed from source.preview instead of
-- parsing the display line (which carries the pin column, not a path).
-- Handed over as `_ctor`: fzf-lua deep-merges a previewer table with its
-- defaults, which drops a class's metatable and with it this parse_entry
-- (measured: the stock parser ran on "    readme.md")
local function previewer(source, built)
    local Previewer = require("fzf-lua.previewer.builtin").buffer_or_file:extend()
    function Previewer:parse_entry(line)
        local item = built.item(line)
        local entry = item and source.preview(item) or {}
        if entry.bufnr and not entry.path then
            entry.path = vim.api.nvim_buf_get_name(entry.bufnr)
        end
        return entry
    end
    return {
        _ctor = function()
            return Previewer
        end,
    }
end

---@param source fzfpin.Source
function M.open(source)
    local built = M.build(source)
    require("fzf-lua").fzf_exec(function(fzf_cb)
        for _, line in ipairs(built.entries()) do
            fzf_cb(line)
        end
        fzf_cb()
    end, {
        prompt = source.prompt,
        actions = built.actions,
        previewer = source.preview and previewer(source, built) or nil,
        keymap = { fzf = built.keymap },
        -- raw args are not escaped by fzf-lua, unlike fzf_opts
        fzf_args = vim.tbl_map(require("fzf-lua.libuv").shellescape, built.raw_binds),
        -- a modal menu, not a resumable search: opt out of fzf-lua's "hide"
        -- profile, whose enrich would replace the esc bind (killing the
        -- esc-undoes-`i` transform) and keep dead fzf processes around
        no_hide = true,
        fzf_opts = {
            ["--no-multi"] = true,
            ["--header"] = M.header,
        },
    })
end

return M
