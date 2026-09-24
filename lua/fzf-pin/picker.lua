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
---@field pin? fun(char: string) pin the current thing; absent means free chars warn
---@field unpin? fun(item: fzfpin.Item) ctrl-x; the list reloads in place afterwards
---@field verbs? table<string, fun()> chars reserved by the source, never pinnable

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

    local function on_char(c)
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
            source.pin(c)
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
        actions[c] = function()
            on_char(c)
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
        actions = actions,
        keymap = { i = search, esc = esc },
        raw_binds = raw_binds, -- unescaped fzf arguments, one per bind
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
