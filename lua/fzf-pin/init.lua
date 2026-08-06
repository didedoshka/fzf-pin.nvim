-- Public surface: pick(source) opens the picker, store persists pin maps.
-- No setup(), no config -- sources carry all the behaviour.
local M = {}

---@param source fzfpin.Source
function M.pick(source)
    require("fzf-pin.picker").open(source)
end

M.chars = require("fzf-pin.picker").chars

return M
