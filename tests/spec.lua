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
    pin = function(char, item)
        log = { "pin", char, item and item.data }
        return "pinned to " .. char
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

ok(built.press("e") == "accept", "chars: a pinned char closes the picker")
built.actions._char_e()
ok(vim.deep_equal(log, { "activate", 1 }), "chars: ...then activates its item")
built.actions.r()
ok(vim.deep_equal(log, { "verb", "r" }), "chars: a verb char runs its verb")
ok(vim.deep_equal(built.pressed,
        vim.list_extend({ "ctrl-x" }, vim.split("abcdefghjklmnopqstuvwxyz", ""))),
    "press: ctrl-x and every char but i and the verbs")
built.actions._verb_r()
ok(vim.deep_equal(log, { "verb", "R" }), "chars: a verb outside the alphabet runs via its raw bind")
ok(vim.deep_equal(built.raw_binds, { "--bind=R:print(_verb_r)+accept" }),
    "chars: the raw bind prints the lowercase action name fzf-lua keeps")
local next, say = built.press("a")
ok(next == "reload", "chars: a free char reloads the list in place")
ok(vim.deep_equal(log, { "pin", "a" }), "chars: free char pins")
ok(say == "pinned to a", "chars: ...and the footer says what pin() returned")
built.press("a", "    beta")
ok(vim.deep_equal(log, { "pin", "a", 2 }), "chars: free char pins the highlighted item")
ok(built.item("[e] alpha").data == 1, "item: display line resolves to its item")

built.actions["enter"]({ "    beta" })
ok(vim.deep_equal(log, { "activate", 2 }), "enter: selected display resolves to item")
log = nil
built.actions["enter"]({})
ok(log == nil, "enter: empty selection is a no-op")

ok(built.press("ctrl-x", "[e] alpha") == "reload", "ctrl-x: reloads the list in place")
ok(vim.deep_equal(log, { "unpin", 1 }), "ctrl-x: unpins the highlighted item")
log = nil
ok(built.press("ctrl-x", "") == nil and log == nil, "ctrl-x: nothing highlighted is a no-op")

-- a char pressed before fzf has pulled the list (typed in one chord with the
-- layer key) must still see the pins, not treat the char as free
local early = picker.build(source)
ok(early.press("e") == "accept", "chars: pinned char before any listing closes the picker")
early.actions._char_e()
ok(vim.deep_equal(log, { "activate", 1 }), "chars: ...then activates its item")
early = picker.build(source)
early.press("a")
ok(vim.deep_equal(log, { "pin", "a" }), "chars: free char before any listing pins")

ok(not picker.chars:find("i", 1, true), "chars: i is never pinnable")
ok(built.keymap.i:match("^unbind%(i,a,b") ~= nil, "i: releases i and the alphabet")
ok(built.keymap.i:match(",R%)") ~= nil, "i: uppercase verbs are released with the alphabet")

-- the esc transform is a sh script: run it the way fzf does, once per state
local function esc_in(prompt, query)
    local script = built.keymap.esc:gsub("^transform:", "")
    local r = vim.system({ "sh", "-c", script },
        { env = { FZF_PROMPT = prompt, FZF_QUERY = query } }):wait()
    return vim.trim(r.stdout)
end
local back = esc_in("search> ", "be")
ok(vim.startswith(back, "change-prompt(spec> )") and back:match("rebind%(i,a,b.*,R%)") ~= nil,
    "esc: search goes back to the bound chars, uppercase verbs included")
ok(not back:find("clear-query", 1, true), "esc: ...and keeps the query, the matches stay")
ok(esc_in("spec> ", "be") == "clear-query", "esc: a kept query is cleared next")
ok(esc_in("spec> ", "") == "abort", "esc: the whole list closes")

-- source without pin(): free char says so instead of erroring
local nopin = { prompt = source.prompt, list = source.list, activate = source.activate }
next, say = picker.build(nopin).press("a")
ok(next == nil, "chars: pinless source does nothing on a free char")
ok(say == "nothing on a", "chars: ...but the footer says so")

if failed > 0 then
    print(("%d failure(s)"):format(failed))
    os.exit(1)
end
print("spec: all passed")
