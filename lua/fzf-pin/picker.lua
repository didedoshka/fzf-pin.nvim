-- The one picker: an fzf-lua window listing items, some carrying a single-char
-- pin. While chars are bound, pressing a pinned char activates its item, a verb
-- char runs its verb, and a free char pins the highlighted item -- the window
-- stays up and the list reloads with the new pin. `i` unbinds every char and
-- turns the window into a plain fuzzy picker; `esc` steps back one state at a
-- time: search -> bound chars over the matches -> the whole list -> closed.
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
---@field pin? fun(char: string, item: fzfpin.Item|nil): string|nil pin the highlighted item
---(nil when nothing is highlighted); returns what the footer says. Absent: free chars refuse
---@field unpin? fun(item: fzfpin.Item): string|nil ctrl-x; the list reloads in place
---afterwards; returns what the footer says
---@field verbs? table<string, fun()> chars reserved by the source, never pinnable
---@field preview? fun(item: fzfpin.Item): { path?: string, bufnr?: integer, line?: integer }|nil
---what the preview window shows for an item, centred on line; absent means no preview window

local function display(item)
    return (item.char and ("[%s] "):format(item.char) or "    ") .. item.label
end

-- Build everything fzf_exec needs, without touching fzf-lua: the entries
-- function, the actions table, what the keys that keep the window up do
-- when pressed, and the `i`/`esc` binds. Pure, so the offline spec can
-- drive it.
---@param source fzfpin.Source
function M.build(source)
    local by_char, by_display = {}, {}

    -- re-lists on every call: fzf's reload after a pin or ctrl-x re-runs
    -- this, so the lookup maps always match what the window shows
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

    -- The keys that act with the window up -- a pinnable char, ctrl-x -- run
    -- at press time, since what a char means changes as pins come and go.
    -- press() says what fzf does next: "accept" for a pinned char (fzf
    -- closes, then `_char_<c>` activates the item), "reload" once a pin or
    -- unpin has landed (the list re-renders in place), nil when nothing
    -- happened -- and second, what the footer should say
    local function press(key, line)
        -- a char typed in one chord with the layer key reaches fzf before it
        -- has pulled the list: with the maps still empty a pinned char would
        -- pass for free and pin over it (measured under a pty, `sa` at once)
        if not listed then
            entries()
        end
        local item = line and by_display[line]
        if key == "ctrl-x" then
            if item and source.unpin then
                return "reload", source.unpin(item)
            end
            return nil
        end
        if by_char[key] then
            return "accept"
        end
        if not source.pin then
            return nil, "nothing on " .. key
        end
        return "reload", source.pin(key, item)
    end

    local actions = {
        ["enter"] = function(selected)
            local item = selected[1] and by_display[selected[1]]
            if item then
                source.activate(item)
            end
        end,
    }
    local verbs = source.verbs or {}
    local bound, pressed = { "i" }, { "ctrl-x" }
    for c in M.chars:gmatch(".") do
        if verbs[c] then
            actions[c] = function()
                verbs[c]()
            end
        else
            table.insert(pressed, c)
            actions["_char_" .. c] = function()
                if by_char[c] then
                    source.activate(by_char[c])
                end
            end
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
    end, vim.tbl_keys(verbs))
    table.sort(extra)
    local raw_binds = {}
    for _, k in ipairs(extra) do
        local name = "_verb_" .. k:lower()
        actions[name] = function()
            verbs[k]()
        end
        table.insert(raw_binds, ("--bind=%s:print(%s)+accept"):format(k, name))
        table.insert(bound, k)
    end
    local keys = table.concat(bound, ",")

    -- `i` returns every char to ordinary typing; the prompt swap is also the
    -- mode flag `esc` reads back through $FZF_PROMPT. Switching modes drops
    -- the footer: it answers the last pin or unpin, not the mode
    local search = ("unbind(%s)+change-prompt(%s)+change-header(type to search  [esc] back)"
        .. "+change-footer()"):format(keys, search_prompt)
    local restore = ("change-prompt(%s)+change-header(%s)+change-footer()+rebind(%s)")
        :format(source.prompt, M.header, keys)
    -- esc steps back: out of search the query stays, so the chars act on
    -- the matches; then it clears the query; only the whole list closes.
    -- fzf-lua starts fzf with SHELL=sh, so this runs under sh
    local esc = ('transform:if [ "$FZF_PROMPT" = "%s" ]; then echo "%s"; '
        .. 'elif [ -n "$FZF_QUERY" ]; then echo clear-query; else echo abort; fi')
        :format(search_prompt, restore)

    return {
        entries = entries,
        item = function(line)
            return by_display[line]
        end,
        press = press,
        pressed = pressed, -- the keys bound through press()
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

-- Closing a picker opened from a terminal's normal mode, fzf-lua restores
-- that mode with :stopinsert, which only lands after the action has run: a
-- picker the action opens (liter's value picker) started in normal mode and
-- closed into terminal mode (measured). So an action that closes the window
-- waits for the switch, the way fzf-lua's own run_builtin does.
local function after_mode_restored(action)
    return function(...)
        local args = { ... }
        -- fzf-lua's global, set only while that :stopinsert is pending
        local wait = rawget(_G, "fzf_lua_stopinsert_hack")
        if not wait then
            return action(...)
        end
        wait(function()
            action(unpack(args))
        end)
    end
end

---@param source fzfpin.Source
function M.open(source)
    local built = M.build(source)
    local actions = {}
    for key, action in pairs(built.actions) do
        actions[key] = after_mode_restored(action)
    end
    -- a pressed key is an fzf transform: fzf-lua turns the function into a
    -- command calling back into this nvim, and what it prints is fzf's next
    -- action. $FZF_KEY is the key, {} the highlighted line. The footer's
    -- colon form takes the rest of the line, parens and all, so it goes last
    local list_cmd -- the list's command, the one fzf-lua's own reloads run
    local press = require("fzf-lua.shell").stringify_data(function(selected, _, _, ctx)
        local key = ctx.env.FZF_KEY
        local next, say = built.press(key, selected[1])
        if next == "accept" then
            return ("print(_char_%s)+accept"):format(key)
        end
        local footer = say and ("change-footer:" .. say) or "change-footer()"
        if next == "reload" then
            return ("reload(%s)+%s"):format(list_cmd, footer)
        end
        return footer
    end, {}, "{}")
    local keymap = vim.deepcopy(built.keymap)
    for _, key in ipairs(built.pressed) do
        keymap[key] = "transform:" .. press
    end
    local _
    _, list_cmd = require("fzf-lua").fzf_exec(function(fzf_cb)
        for _, line in ipairs(built.entries()) do
            fzf_cb(line)
        end
        fzf_cb()
    end, {
        prompt = source.prompt,
        actions = actions,
        previewer = source.preview and previewer(source, built) or nil,
        keymap = { fzf = keymap },
        -- raw args are not escaped by fzf-lua, unlike fzf_opts
        fzf_args = vim.tbl_map(require("fzf-lua.libuv").shellescape, built.raw_binds),
        -- a modal menu, not a resumable search: opt out of fzf-lua's "hide"
        -- profile, whose enrich would replace the esc bind (killing the
        -- esc transform) and keep dead fzf processes around
        no_hide = true,
        fzf_opts = {
            ["--no-multi"] = true,
            ["--header"] = M.header,
        },
    })
end

return M
