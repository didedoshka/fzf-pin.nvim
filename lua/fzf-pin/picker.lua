-- The one picker: an fzf-lua window listing items, some carrying a single-char
-- pin. While chars are bound, pressing a pinned char activates its item, a verb
-- char runs its verb, and a free char pins the current thing. `i` unbinds every
-- char and turns the window into a plain fuzzy picker from there on.
local M = {}

-- pinnable alphabet: lowercase minus `i`, which is reserved for entering search
M.chars = "abcdefghjklmnopqrstuvwxyz"

---@class fzfpin.Item
---@field label string display label, unique within the source
---@field char string|nil the char this item is pinned to
---@field data any

---@class fzfpin.Source
---@field prompt string
---@field list fun(): fzfpin.Item[] ordered; pinned items conventionally first
---@field activate fun(item: fzfpin.Item)
---@field pin? fun(char: string) pin the current thing; absent means free chars warn
---@field unpin? fun(item: fzfpin.Item): boolean? ctrl-x; truthy return reopens the picker
---@field verbs? table<string, fun()> chars reserved by the source, never pinnable

local function display(item)
    return (item.char and ("[%s] "):format(item.char) or "    ") .. item.label
end

-- Build everything fzf_exec needs, without touching fzf-lua: entries, the
-- actions table and the `i` unbind. Pure, so the offline spec can drive it.
---@param source fzfpin.Source
function M.build(source)
    local items = source.list()
    local by_char, by_display, entries = {}, {}, {}
    for _, item in ipairs(items) do
        local line = display(item)
        by_display[line] = item
        if item.char then
            by_char[item.char] = item
        end
        table.insert(entries, line)
    end

    local function on_char(c)
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
        ["ctrl-x"] = function(selected)
            local item = selected[1] and by_display[selected[1]]
            if not (item and source.unpin) then
                return
            end
            if source.unpin(item) then
                -- reopen so the list reflects the removal
                vim.schedule(function()
                    M.open(source)
                end)
            end
        end,
    }
    local unbind = { "i" }
    for c in M.chars:gmatch(".") do
        actions[c] = function()
            on_char(c)
        end
        table.insert(unbind, c)
    end

    return {
        entries = entries,
        actions = actions,
        -- `i` returns every char to ordinary typing; from here it is plain fzf
        unbind = ("unbind(%s)+change-header(type to search)"):format(table.concat(unbind, ",")),
    }
end

---@param source fzfpin.Source
function M.open(source)
    local built = M.build(source)
    require("fzf-lua").fzf_exec(built.entries, {
        prompt = source.prompt,
        actions = built.actions,
        keymap = { fzf = { i = built.unbind } },
        fzf_opts = {
            ["--no-multi"] = true,
            ["--header"] = "[i] search  [C-x] unpin",
        },
    })
end

return M
