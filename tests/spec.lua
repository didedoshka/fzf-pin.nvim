-- Offline spec on bare `nvim --clean -l`: drives picker.build() closures and
-- the store round-trip. fzf-lua is not involved -- open() is the only thing
-- that touches it and stays untested here (needs a real UI).
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
vim.opt.rtp:prepend(root)

local failed = 0
local function ok(cond, name)
    if cond then
        print("  ok    " .. name)
    else
        print("  FAIL  " .. name)
        failed = failed + 1
    end
end

-- --- store ------------------------------------------------------------------
local store = require("fzf-pin.store")
ok(vim.deep_equal(store.load("absent"), {}), "store: missing namespace loads empty")
store.save("spec", { ["/proj"] = { e = "/proj/main.c" } })
ok(store.load("spec")["/proj"].e == "/proj/main.c", "store: round-trip")
store.save("spec", {})
ok(vim.deep_equal(store.load("spec"), {}), "store: overwrite with empty")

-- namespaces may contain "/": one file per project lives in a subdirectory
store.save("nested/enc%oded", { e = "/x" })
ok(store.load("nested/enc%oded").e == "/x", "store: namespace with / round-trips")

local f = vim.fs.joinpath(vim.fn.stdpath("state"), "fzf-pin", "corrupt.json")
vim.fn.mkdir(vim.fs.dirname(f), "p")
vim.fn.writefile({ "{not json" }, f)
ok(vim.deep_equal(store.load("corrupt"), {}), "store: corrupt file loads empty")

-- --- picker.build -----------------------------------------------------------
local picker = require("fzf-pin.picker")
local log
local source = {
    prompt = "spec> ",
    list = function()
        return {
            { label = "alpha", char = "e", data = 1 },
            { label = "beta",  data = 2 },
        }
    end,
    activate = function(item)
        log = { "activate", item.data }
    end,
    pin = function(char)
        log = { "pin", char }
    end,
    unpin = function(item)
        log = { "unpin", item.data }
    end,
    verbs = {
        r = function()
            log = { "verb", "r" }
        end,
        R = function()
            log = { "verb", "R" }
        end,
    },
}

local built = picker.build(source)
ok(vim.deep_equal(built.entries(), { "[e] alpha", "    beta" }), "build: entry rendering")

built.actions.e()
ok(vim.deep_equal(log, { "activate", 1 }), "chars: taken char activates its item")
built.actions.r()
ok(vim.deep_equal(log, { "verb", "r" }), "chars: verb wins over pinning")
built.actions._verb_r()
ok(vim.deep_equal(log, { "verb", "R" }), "chars: a verb outside the alphabet runs via its raw bind")
ok(vim.deep_equal(built.raw_binds, { "--bind=R:print(_verb_r)+accept" }),
    "chars: the raw bind prints the lowercase action name fzf-lua keeps")
built.actions.a()
ok(vim.deep_equal(log, { "pin", "a" }), "chars: free char pins")

built.actions["enter"]({ "    beta" })
ok(vim.deep_equal(log, { "activate", 2 }), "enter: selected display resolves to item")
log = nil
built.actions["enter"]({})
ok(log == nil, "enter: empty selection is a no-op")

ok(built.actions["ctrl-x"].reload == true, "ctrl-x: reloads the list in place")
built.actions["ctrl-x"].fn({ "[e] alpha" })
ok(vim.deep_equal(log, { "unpin", 1 }), "ctrl-x: unpins the selected item")

-- a char pressed before fzf has pulled the list (typed in one chord with the
-- layer key) must still see the pins, not treat the char as free
local early = picker.build(source)
early.actions.e()
ok(vim.deep_equal(log, { "activate", 1 }), "chars: pinned char before any listing activates")
early.actions.a()
ok(vim.deep_equal(log, { "pin", "a" }), "chars: free char before any listing pins")

ok(not picker.chars:find("i", 1, true), "chars: i is never pinnable")
ok(built.keymap.i:match("^unbind%(i,a,b") ~= nil, "i: releases i and the alphabet")
ok(built.keymap.esc:match("rebind%(i,a,b") ~= nil, "esc: search mode rebinds the alphabet")
ok(built.keymap.i:match(",R%)") ~= nil and built.keymap.esc:match(",R%)") ~= nil,
    "i/esc: uppercase verbs are released and rebound with the alphabet")
ok(built.keymap.esc:match("abort") ~= nil, "esc: bound state still aborts")

-- source without pin(): free char warns instead of erroring
local nopin = { prompt = source.prompt, list = source.list, activate = source.activate }
local warned
vim.notify = function(msg, lvl)
    warned = { msg, lvl }
end
picker.build(nopin).actions.a()
ok(warned and warned[1]:find("nothing on a") ~= nil, "chars: pinless source warns on free char")

if failed > 0 then
    print(("%d failure(s)"):format(failed))
    os.exit(1)
end
print("spec: all passed")
