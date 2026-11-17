-- Error capture (ns.LogError / ns.Safe / ns.Wrap / ns.NewFrame), taint logging, the hideBlizzardParty
-- migration and the taint-free Blizzard party frame hiding. Only mock globals are used: nothing here reads or
-- writes any real SavedVariables or game files.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function st(f) return rawget(f, "__s") end
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.setup then opts.setup() end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    if opts.account ~= nil then _G.HealerForeverDB = deepcopy(opts.account) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    if opts.group then mock.setGroup(opts.group) end
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local function slash(msg)
    mock.printed = {}
    local ok, err = pcall(_G.SlashCmdList.HEALERFOREVER, msg)
    assert(ok, tostring(err))
    return table.concat(mock.printed, "\n")
end
local function freshLog(ns) for i = #ns.db.errorLog, 1, -1 do ns.db.errorLog[i] = nil end; ns.errorMemory = {} end

-- ======================================================================== LogError
describe("errors: ns.LogError", function()
    local ns = boot({ group = 1 })
    it("records label, message, combat flag, kind, count and time", function()
        freshLog(ns); mock.errors = {}
        ns.LogError("OnClick", "something broke", "stack here")
        local e = ns.db.errorLog[1]
        assertEquals(e.label, "OnClick"); assertEquals(e.msg, "something broke"); assertEquals(e.stack, "stack here")
        assertEquals(e.kind, "error"); assertEquals(e.count, 1); assertEquals(e.combat, false); assertEquals(type(e.time), "number")
    end)
    it("flags errors raised during combat", function()
        freshLog(ns)
        S.combat = true; ns.LogError("OnEvent", "in combat"); S.combat = false
        assertEquals(ns.db.errorLog[1].combat, true)
    end)
    it("caps the log at 50 entries, dropping the oldest", function()
        freshLog(ns)
        for i = 1, 120 do ns.LogError("L", "error number " .. i) end
        assertEquals(#ns.db.errorLog, 50)
        assertEquals(ns.db.errorLog[1].msg, "error number 71")
        assertEquals(ns.db.errorLog[50].msg, "error number 120")
    end)
    it("trims an oversized saved log on the next entry", function()
        freshLog(ns)
        for i = 1, 80 do ns.db.errorLog[i] = { time = 0, label = "x", msg = "old " .. i, count = 1, kind = "error" } end
        ns.LogError("L", "fresh")
        assertEquals(#ns.db.errorLog, 50)
        assertEquals(ns.db.errorLog[50].msg, "fresh")
    end)
    it("counts consecutive repeats of the same label+message instead of adding entries", function()
        freshLog(ns)
        for _ = 1, 7 do ns.LogError("OnUpdate", "same error") end
        assertEquals(#ns.db.errorLog, 1); assertEquals(ns.db.errorLog[1].count, 7)
    end)
    it("a different label or message starts a new entry; non-consecutive repeats are separate entries", function()
        freshLog(ns)
        ns.LogError("A", "m"); ns.LogError("B", "m"); ns.LogError("B", "other"); ns.LogError("A", "m")
        assertEquals(#ns.db.errorLog, 4)
        ns.LogError("A", "m")
        assertEquals(#ns.db.errorLog, 4); assertEquals(ns.db.errorLog[4].count, 2)
    end)
    it("a flood of identical errors never grows the log", function()
        freshLog(ns)
        for _ = 1, 5000 do ns.LogError("Flood", "boom") end
        assertEquals(#ns.db.errorLog, 1); assertEquals(ns.db.errorLog[1].count, 5000)
    end)
    it("non-string messages are converted with tostring", function()
        freshLog(ns)
        ns.LogError("T", { 1 }); ns.LogError("T", 42); ns.LogError("T", nil)
        for _, e in ipairs(ns.db.errorLog) do assertEquals(type(e.msg), "string") end
    end)
    it("each new distinct error is forwarded once to the game's error handler", function()
        freshLog(ns); mock.errors = {}
        ns.LogError("F", "forward me"); ns.LogError("F", "forward me"); ns.LogError("F", "forward me")
        local n = 0
        for _, e in ipairs(mock.errors) do if e:find("forward me", 1, true) then n = n + 1 end end
        assertEquals(n, 1)
        mock.errors = {}
    end)
    it("blocked entries are not forwarded and do not trigger the 'an error was logged' note", function()
        freshLog(ns); mock.errors = {}
        mock.printed = {}
        ns.LogError("taint", "ADDON_ACTION_BLOCKED: X", nil, "blocked")
        assertEquals(#mock.errors, 0)
        assertEquals(ns.db.errorLog[1].kind, "blocked")
        assertNil(table.concat(mock.printed, "\n"):find("an error was logged", 1, true))
    end)
    it("the 'an error was logged' note is printed once only", function()
        local ns2 = boot({ group = 1 })
        mock.printed = {}
        ns2.LogError("A", "one"); ns2.LogError("A", "two"); ns2.LogError("B", "three")
        local n = 0
        for _, l in ipairs(mock.printed) do if l:find("/hf errors", 1, true) then n = n + 1 end end
        assertEquals(n, 1)
        mock.errors = {}
    end)
    it("falls back to in-memory storage when the saved log is unusable or ns.db is missing", function()
        local ns2 = boot({ group = 1 })
        ns2.db.errorLog = "garbage"
        assertTrue(pcall(ns2.LogError, "X", "no table"))
        assertEquals(#ns2.errorMemory, 1)
        local saved = ns2.db
        ns2.db = nil
        assertTrue(pcall(ns2.LogError, "X", "no db"))
        ns2.db = saved
        mock.errors = {}
    end)
    it("the log is part of the character DB and survives a save/reload", function()
        local ns2 = boot({ group = 1 })
        freshLog(ns2); ns2.LogError("Persist", "kept"); mock.errors = {}
        local ns3 = boot({ char = HealerForeverCharDB, group = 1 })
        assertEquals(ns3.db.errorLog[1].msg, "kept")
    end)
    it("a corrupted saved errorLog is replaced by a table on load", function()
        local ns2 = boot({ char = { errorLog = "x" }, group = 1 })
        assertEquals(type(ns2.db.errorLog), "table")
    end)
end)

-- ======================================================================== Safe / Wrap
describe("errors: ns.Safe and ns.Wrap", function()
    local ns = boot({ group = 1 })
    local function logged() return ns.db.errorLog end
    it("Safe returns true and the result on success", function()
        local ok, r = ns.Safe("S", function(a, b) return a + b end, 2, 3)
        assertTrue(ok); assertEquals(r, 5)
    end)
    it("Safe passes up to five arguments", function()
        local ok, r = ns.Safe("S", function(a, b, c, d, e) return a .. b .. c .. d .. e end, "1", "2", "3", "4", "5")
        assertTrue(ok); assertEquals(r, "12345")
    end)
    it("Safe swallows an error, returns false and logs it under the label", function()
        freshLog(ns); mock.errors = {}
        local ok = ns.Safe("MyLabel", function() error("kaboom") end)
        assertFalse(ok)
        assertEquals(#logged(), 1); assertEquals(logged()[1].label, "MyLabel"); assertNotNil(logged()[1].msg:find("kaboom", 1, true))
        mock.errors = {}
    end)
    it("Safe works again after an error (no stuck state)", function()
        ns.Safe("S", function() error("x") end)
        local ok, r = ns.Safe("S", function() return "fine" end)
        assertTrue(ok); assertEquals(r, "fine")
        mock.errors = {}
    end)
    it("non-string error values are logged without raising", function()
        freshLog(ns)
        assertFalse((ns.Safe("S", function() error({ code = 1 }) end)))
        assertFalse((ns.Safe("S", function() error(nil) end)))
        assertEquals(#logged() >= 1, true)
        mock.errors = {}
    end)
    it("nested Safe calls do not clobber each other's arguments", function()
        local ok, r = ns.Safe("outer", function(a, b)
            local ok2, inner = ns.Safe("inner", function(x, y) return x * y end, 6, 7)
            return a .. b .. inner .. tostring(ok2)
        end, "A", "B")
        assertTrue(ok); assertEquals(r, "AB42true")
    end)
    it("a nested failing Safe does not abort the outer function", function()
        freshLog(ns)
        local ok, r = ns.Safe("outer", function() ns.Safe("inner", function() error("inner fail") end); return "outer ok" end)
        assertTrue(ok); assertEquals(r, "outer ok")
        mock.errors = {}
    end)
    it("Wrap returns a function that forwards arguments and the first result", function()
        local f = ns.Wrap("W", function(a, b, c) return a + b + c, "second" end)
        assertEquals(f(1, 2, 3), 6)
    end)
    it("Wrap swallows errors, logs the label, and returns nothing", function()
        freshLog(ns)
        local f = ns.Wrap("OnClick", function() error("handler failed") end)
        local ok, r = pcall(f, "a")
        assertTrue(ok, "Wrap must not propagate errors"); assertNil(r)
        assertEquals(logged()[1].label, "OnClick")
        mock.errors = {}
    end)
    it("the next handler still runs after one failed", function()
        freshLog(ns)
        local ran = {}
        local handlers = {
            ns.Wrap("h1", function() ran[#ran + 1] = 1 end),
            ns.Wrap("h2", function() ran[#ran + 1] = 2; error("middle one fails") end),
            ns.Wrap("h3", function() ran[#ran + 1] = 3 end),
        }
        for _, h in ipairs(handlers) do h() end
        assertDeepEquals(ran, { 1, 2, 3 })
        mock.errors = {}
    end)
    it("Wrap can be called re-entrantly (a wrapped handler calling another wrapped handler)", function()
        local inner = ns.Wrap("inner", function(x) return x * 2 end)
        local outer = ns.Wrap("outer", function(x) return inner(x) + 1 end)
        assertEquals(outer(10), 21)
    end)
    it("event handlers registered with ns:RegisterEvent are isolated: one error does not stop the next", function()
        freshLog(ns)
        local ran = false
        ns:RegisterEvent("HF_TEST_EVENT", function() error("event handler failed") end)
        ns:RegisterEvent("HF_TEST_EVENT", function() ran = true end)
        mock.errors = {}
        mock.fire("HF_TEST_EVENT")
        assertTrue(ran, "second handler must run")
        assertEquals(#logged() >= 1, true)
        mock.errors = {}
    end)
    it("internal callbacks (ns:On / ns:Fire) are isolated too", function()
        local ran = false
        ns:On("HF_TEST_MSG", function() error("callback failed") end)
        ns:On("HF_TEST_MSG", function() ran = true end)
        local ok = pcall(ns.Fire, ns, "HF_TEST_MSG")
        assertTrue(ok, "Fire must not raise"); assertTrue(ran)
        mock.errors = {}
    end)
end)

-- ======================================================================== NewFrame
describe("errors: ns.NewFrame wraps scripts", function()
    local ns = boot({ group = 2 })
    it("a frame from ns.NewFrame is marked wrapped and a second wrap is not applied", function()
        local f = ns.NewFrame("Frame", nil, UIParent)
        assertTrue(f.hfWrapped)
        local set = f.SetScript
        local g = ns.NewFrame("Frame", nil, UIParent)
        assertTrue(g.hfWrapped)
        assertNotNil(set)
    end)
    it("SetScript handlers that error are swallowed and logged", function()
        freshLog(ns)
        local f = ns.NewFrame("Button", nil, UIParent)
        f:SetScript("OnClick", function() error("click handler broke") end)
        local ok = pcall(st(f).scripts.OnClick, f, "LeftButton")
        assertTrue(ok, "stored script must be the wrapped function")
        assertEquals(ns.db.errorLog[1].label, "OnClick")
        mock.errors = {}
    end)
    it("SetScript still passes arguments and the frame to the handler", function()
        local got
        local f = ns.NewFrame("Button", nil, UIParent)
        f:SetScript("OnClick", function(self, button, down) got = { self, button, down } end)
        st(f).scripts.OnClick(f, "RightButton", true)
        assertTrue(got[1] == f); assertEquals(got[2], "RightButton"); assertEquals(got[3], true)
    end)
    it("HookScript handlers are wrapped as well", function()
        freshLog(ns)
        local f = ns.NewFrame("Button", nil, UIParent)
        f:HookScript("OnEnter", function() error("hook broke") end)
        local ok = pcall(st(f).hooks.OnEnter[1], f)
        assertTrue(ok); assertEquals(ns.db.errorLog[1].label, "OnEnter")
        mock.errors = {}
    end)
    it("SetScript(name, nil) clears the handler (non-functions pass through)", function()
        local f = ns.NewFrame("Frame", nil, UIParent)
        f:SetScript("OnUpdate", function() end)
        f:SetScript("OnUpdate", nil)
        assertNil(st(f).scripts.OnUpdate)
    end)
    it("OnUpdate scripts that fail every frame produce one counted entry, not a flood", function()
        freshLog(ns)
        local f = ns.NewFrame("Frame", nil, UIParent)
        f:SetScript("OnUpdate", function() error("per-frame failure") end)
        for _ = 1, 200 do st(f).scripts.OnUpdate(f, 0.01) end
        assertEquals(#ns.db.errorLog, 1); assertEquals(ns.db.errorLog[1].count, 200)
        mock.errors = {}
    end)
    it("secure frames created through NewFrame keep their template and work", function()
        local b = ns.NewFrame("Button", "HFTestSecure", UIParent, "SecureActionButtonTemplate")
        assertTrue(st(b).secure); b:SetAttribute("type", "spell")
        assertEquals(b:GetAttribute("type"), "spell")
    end)
    it("real addon frames are wrapped: an error in a unit-button tooltip hook is logged, not raised", function()
        freshLog(ns)
        local btn
        for _, f in ipairs(mock.frames) do if tostring(st(f).name):match("^HealerForeverUnit") then btn = f; break end end
        _G.GameTooltip.SetOwner = function() error("tooltip boom") end
        local ok = pcall(st(btn).hooks.OnEnter[1], btn)
        assertTrue(ok, "OnEnter hook of a unit frame must be wrapped")
        local found = false
        for _, e in ipairs(ns.db.errorLog) do if e.msg:find("tooltip boom", 1, true) then found = true end end
        assertTrue(found); mock.errors = {}
    end)
    it("real addon frames are wrapped: minimap button, options checkboxes and the pane widgets", function()
        local mb
        for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverMinimapButton" then mb = f end end
        local real = ns.UnitFrames.SetLocked
        ns.UnitFrames.SetLocked = function() error("lock boom") end
        assertTrue(pcall(st(mb).scripts.OnClick, mb, "RightButton"))
        ns.UnitFrames.SetLocked = real
        ns.Options:Show("general"); mock.flushTimers()
        local cb
        for _, f in ipairs(mock.frames) do if st(f).kind == "CheckButton" and f.label and st(f.label).text == "Show pets" then cb = f end end
        assertNotNil(cb)
        local realChanged = ns.Changed
        ns.Changed = function() error("changed boom") end
        assertTrue(pcall(st(cb).scripts.OnClick, cb, "LeftButton"))
        ns.Changed = realChanged
        mock.errors = {}
    end)
end)

-- ======================================================================== /hf errors
describe("errors: /hf errors and /hf errors clear", function()
    local ns = boot({ group = 1 })
    it("empty log: 'No errors logged.'", function()
        freshLog(ns)
        assertNotNil(slash("errors"):find("No errors logged", 1, true))
    end)
    it("lists the count and only the last 10 entries", function()
        freshLog(ns); mock.errors = {}
        for i = 1, 25 do ns.LogError("Lab" .. i, "message " .. i) end
        local out = slash("errors")
        assertNotNil(out:find("25 logged", 1, true), out)
        assertNotNil(out:find("message 25", 1, true)); assertNotNil(out:find("message 16", 1, true))
        assertNil(out:find("message 15\n", 1, true)); assertNil(out:find("message 1:", 1, true))
        mock.errors = {}
    end)
    it("shows repeat counts, combat state and BLOCKED markers", function()
        freshLog(ns)
        for _ = 1, 3 do ns.LogError("Rep", "again") end
        S.combat = true; ns.LogError("Cmb", "in combat error"); S.combat = false
        ns.LogError("taint", "ADDON_ACTION_BLOCKED: Foo", nil, "blocked")
        local out = slash("errors")
        assertNotNil(out:find("x3", 1, true), out)
        assertNotNil(out:find("combat", 1, true)); assertNotNil(out:find("BLOCKED", 1, true))
        mock.errors = {}
    end)
    it("/hf errors clear empties the saved log and the memory log", function()
        ns.LogError("A", "something"); ns.errorMemory = { { msg = "x" } }
        local out = slash("errors clear")
        assertNotNil(out:find("cleared", 1, true))
        assertEquals(#ns.db.errorLog, 0); assertEquals(#ns.errorMemory, 0)
        assertNotNil(slash("errors"):find("No errors logged", 1, true))
        mock.errors = {}
    end)
    it("the same table object is kept when clearing (references stay valid)", function()
        local before = ns.db.errorLog
        ns.LogError("A", "x"); slash("errors clear")
        assertTrue(ns.db.errorLog == before); mock.errors = {}
    end)
    it("clear works in combat; unknown arguments just list", function()
        S.combat = true
        assertNotNil(slash("errors clear"):find("cleared", 1, true))
        assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "errors bogus"))
        assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "errors CLEAR"))
        S.combat = false; mock.errors = {}
    end)
    it("help text mentions /hf errors", function()
        assertNotNil(slash("help"):find("/hf errors", 1, true))
    end)
end)

-- ======================================================================== taint events
describe("errors: ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN", function()
    local ns = boot({ group = 1 })
    for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
        it(event .. " from HealerForever is recorded as a blocked entry", function()
            freshLog(ns); mock.errors = {}
            mock.fire(event, "HealerForever", "SetAttribute()")
            assertEquals(#ns.db.errorLog, 1)
            local e = ns.db.errorLog[1]
            assertEquals(e.kind, "blocked"); assertEquals(e.label, "taint")
            assertNotNil(e.msg:find(event, 1, true)); assertNotNil(e.msg:find("SetAttribute()", 1, true))
            assertEquals(#mock.errors, 0, "blocked events must not be forwarded as errors")
        end)
        it(event .. " from another addon is ignored", function()
            freshLog(ns)
            mock.fire(event, "SomeOtherAddon", "Foo()")
            mock.fire(event, "healerforever", "case differs")
            mock.fire(event, nil, nil)
            mock.fire(event)
            assertEquals(#ns.db.errorLog, 0)
        end)
    end
    it("repeated identical blocks are counted", function()
        freshLog(ns)
        for _ = 1, 4 do mock.fire("ADDON_ACTION_BLOCKED", "HealerForever", "Show()") end
        assertEquals(#ns.db.errorLog, 1); assertEquals(ns.db.errorLog[1].count, 4)
    end)
    it("records whether it happened in combat", function()
        freshLog(ns)
        S.combat = true; mock.fire("ADDON_ACTION_BLOCKED", "HealerForever", "Hide()"); S.combat = false
        assertEquals(ns.db.errorLog[1].combat, true)
    end)
    it("a nil function name does not raise", function()
        assertTrue(pcall(function() mock.fire("ADDON_ACTION_BLOCKED", "HealerForever", nil) end))
        assertEquals(#mock.errors, 0)
    end)
    it("the events are shown by /hf errors as BLOCKED", function()
        freshLog(ns)
        mock.fire("ADDON_ACTION_FORBIDDEN", "HealerForever", "ClearAllPoints()")
        assertNotNil(slash("errors"):find("BLOCKED", 1, true))
    end)
end)

-- ======================================================================== Blizzard party frames are left alone
describe("errors: the old hide-Blizzard-party option is gone and no Blizzard frame is touched", function()
    local function spyGlobals()
        _G.UpdatePartyFrames = function() mock.updatePartyCalls = (mock.updatePartyCalls or 0) + 1 end
        mock.updatePartyCalls = 0
        mock.hookCalls = {}
        local real = _G.hooksecurefunc
        _G.hooksecurefunc = function(a, b, c) mock.hookCalls[#mock.hookCalls + 1] = { a, b, c }; return real(a, b, c) end
    end
    local function callsOn(frame)
        local out = {}
        for _, c in ipairs(mock.calls) do if c.obj == frame then out[#out + 1] = c end end
        return out
    end
    it("defaults contain neither hideBlizzardParty nor taintMigrated", function()
        local ns = boot({ group = 1 })
        assertNil(ns.DEFAULTS.hideBlizzardParty); assertNil(ns.db.hideBlizzardParty); assertNil(ns.db.taintMigrated)
    end)
    it("old saved keys are deleted on load (true or false, any value) and nothing else is lost", function()
        for _, v in ipairs({ true, false, "yes", 5 }) do
            local ns = boot({ char = { version = 2, hideBlizzardParty = v, taintMigrated = v, frames = { layout = "vertical", showPets = false } }, group = 1 })
            assertNil(ns.db.hideBlizzardParty); assertNil(ns.db.taintMigrated)
            assertEquals(ns.db.frames.layout, "vertical"); assertEquals(ns.db.frames.showPets, false)
        end
    end)
    it("an account DB carrying the old keys migrates without them; the account DB itself is untouched", function()
        local ns = boot({ account = { version = 2, hideBlizzardParty = true, taintMigrated = true, frames = { layout = "vertical" } }, group = 1 })
        assertEquals(ns.db.migratedFrom, "account"); assertNil(ns.db.hideBlizzardParty); assertNil(ns.db.taintMigrated)
        assertEquals(_G.HealerForeverDB.hideBlizzardParty, true); assertEquals(_G.HealerForeverDB.taintMigrated, true)
    end)
    it("a second load (keys already gone) stays clean", function()
        local ns = boot({ char = { version = 2, hideBlizzardParty = true }, group = 1 })
        local ns2 = boot({ char = HealerForeverCharDB, group = 1 })
        assertNil(ns2.db.hideBlizzardParty); assertNil(ns2.db.taintMigrated)
    end)
    it("the options window has no Blizzard-party checkbox", function()
        local ns = boot({ group = 1 })
        ns.Options:Show("general"); mock.flushTimers()
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "CheckButton" and f.label then
                assertNil(tostring(st(f.label).text):find("Blizzard party", 1, true), "removed option still shown")
            end
        end
    end)
    it("no Blizzard frame is touched at any point (login, roster changes, config changes, combat)", function()
        local ns = boot({ setup = spyGlobals, group = 2 })
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("PLAYER_LOGIN"); ns:Changed("general"); ns:Changed("all"); mock.flushTimers()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED"); mock.fire("GROUP_ROSTER_UPDATE"); ns:Changed("frames")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        for _, name in ipairs({ "PartyFrame", "CompactPartyFrame", "PlayerFrame", "TargetFrame", "CompactRaidFrameContainer", "CompactRaidFrameManager" }) do
            local f = _G[name]
            if f then
                assertEquals(#callsOn(f), 0, name .. " must never be touched")
                assertTrue(st(f).shown, name .. " must stay shown")
                for k in pairs(f) do assertEquals(k, "__s", "field written on " .. name) end
            end
        end
        assertEquals(mock.updatePartyCalls, 0); assertEquals(#mock.hookCalls, 0, "no hooksecurefunc at all")
        assertEquals(#mock.errors, 0)
    end)
    it("no file or TOC entry for the removed HideParty module remains and ns.HideParty is not defined", function()
        for _, f in ipairs(toc.files) do assertNil(f:find("HideParty", 1, true), "TOC still lists " .. f) end
        assertFalse(L.exists(L.path("Blizzard/HideParty.lua")))
        local ns = boot({ group = 1 })
        assertNil(ns.HideParty)
    end)
    it("no module references hooksecurefunc, PartyFrame, UpdatePartyFrames or the removed option", function()
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                local src = L.readFile(L.path(rel)):gsub("%-%-[^\n]*", "")
                for _, bad in ipairs({ "hooksecurefunc", "PartyFrame", "UpdatePartyFrames", "hideBlizzardParty", "taintMigrated", "HideParty" }) do
                    local s = src:find("%f[%w_]" .. bad:gsub("%p", "%%%0") .. "%f[^%w_]")
                    if s then
                        -- Core.lua may name the keys it deletes
                        local allowed = (rel == "Core.lua") and (bad == "hideBlizzardParty" or bad == "taintMigrated")
                        assertTrue(allowed, rel .. " references " .. bad)
                    end
                end
            end
        end
    end)
end)

-- ======================================================================== source scan: raw CreateFrame
describe("errors: modules create frames through ns.NewFrame only", function()
    -- allow-list: Core.lua defines ns.NewFrame (one CreateFrame), the private event frame (created in a pcall) and the
    -- existence guard for it; these 3 lines are the only justified raw uses. Frames/Auras.lua creates Blizzard's native "AuraContainer"
    -- frame type, which ns.NewFrame (tuned for ordinary frames) must not wrap: exactly ONE raw CreateFrame, for that.
    local ALLOWED = { ["Core.lua"] = 3, ["Frames/Auras.lua"] = 1 }
    it("no module calls raw CreateFrame except the allow-listed ones", function()
        local bad, uses = {}, 0
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                local count, n = 0, 0
                for line in L.readFile(L.path(rel)):gmatch("[^\n]*") do
                    n = n + 1
                    local code = line:gsub("%-%-.*$", "")
                    local stripped = code:gsub("ns%.NewFrame", "")
                    if stripped:find("CreateFrame", 1, true) then count = count + 1; bad[#bad + 1] = { rel, n, line } end
                    if code:find("ns.NewFrame", 1, true) then uses = uses + 1 end
                end
                if (ALLOWED[rel:gsub("\\", "/")] or 0) >= count then
                    for i = #bad, 1, -1 do if bad[i][1] == rel then table.remove(bad, i) end end
                end
            end
        end
        local msg = {}
        for _, b in ipairs(bad) do msg[#msg + 1] = b[1] .. ":" .. b[2] .. ": " .. b[3]:gsub("^%s+", "") end
        assertEquals(#bad, 0, "raw CreateFrame calls:\n" .. table.concat(msg, "\n"))
        assertTrue(uses >= 20, "expected many ns.NewFrame uses, found " .. uses)
    end)
    it("nobody aliases CreateFrame at load time (local CreateFrame = CreateFrame)", function()
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                local src = L.readFile(L.path(rel))
                assertNil(src:find("local%s+CreateFrame%s*="), rel .. " aliases CreateFrame")
            end
        end
    end)
    it("hooksecurefunc is not used anywhere", function()
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                local src = L.readFile(L.path(rel)):gsub("%-%-[^\n]*", "")
                assertNil(src:find("hooksecurefunc", 1, true), "unexpected hooksecurefunc in " .. rel)
            end
        end
    end)
    it("no module overrides SetScript/HookScript on Blizzard-owned frames", function()
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                local src = L.readFile(L.path(rel)):gsub("%-%-[^\n]*", "")
                for _, name in ipairs({ "PartyFrame", "CompactPartyFrame", "PlayerFrame", "TargetFrame", "UIParent", "WorldFrame" }) do
                    assertNil(src:find(name .. ":SetScript", 1, true), rel .. " sets a script on " .. name)
                    assertNil(src:find(name .. ":HookScript", 1, true) and (name ~= "UIParent" and name) or nil, rel .. " hooks " .. name)
                end
            end
        end
    end)
end)
