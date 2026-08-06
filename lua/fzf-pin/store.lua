-- Persistent pin maps: one JSON file per namespace under stdpath("state").
-- The shape inside is the source's business (bookmarks nests per project,
-- servers is flat); this module only loads and saves whole tables.
local M = {}

local function path(ns)
    return vim.fs.joinpath(vim.fn.stdpath("state"), "fzf-pin", ns .. ".json")
end

---@return table
function M.load(ns)
    local f = io.open(path(ns), "r")
    if not f then
        return {}
    end
    local ok, decoded = pcall(vim.json.decode, f:read("*a"))
    f:close()
    return ok and type(decoded) == "table" and decoded or {}
end

function M.save(ns, tbl)
    vim.fn.mkdir(vim.fs.dirname(path(ns)), "p")
    local f = assert(io.open(path(ns), "w"))
    f:write(vim.json.encode(tbl))
    f:close()
end

return M
