-- Debug capture (HealerForeverCharDB.debugLog), /hf debug clear, the copy window (Options/CopyWindow.lua), /hf copy and the
-- "copy" slash arguments, the shared error formatter, and the TOC listing.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function deepcopy(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = deepcopy(v) end return o end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    return ns
end
local function slash(msg)
    mock.printed = {}
    local ok, err = pcall(_G.SlashCmdList.HEALERFOREVER, msg)
    mock.flushTimers()
    return ok, err, table.concat(mock.printed, "\n")
end
local function copyFrame() return _G.HealerForeverCopyFrame end
local function lastRun(ns) local l = ns.db.debugLog; return l[#l] end
local function addError(ns, msg, stack)
    ns.db.errorLog[#ns.db.errorLog + 1] = { time = 1000, label = "UNIT_AURA", msg = msg, stack = stack, combat = false, count = 1, kind = "error" }
end

-- ======================================================================== TOC / files
describe("debug log: files", function()
    it("Options/CopyWindow.lua exists, is listed in the TOC once, before Options/Slash.lua and after the widgets", function()
        local idx = {}
        for i, rel in ipairs(toc.files) do idx[rel:gsub("\\", "/")] = i end
        assertNotNil(idx["Options/CopyWindow.lua"], "listed")
        assertNotNil(idx["Options/Slash.lua"])
        assertTrue(idx["Options/CopyWindow.lua"] < idx["Options/Slash.lua"], "loaded before the slash handler")
        assertTrue(idx["Options/CopyWindow.lua"] > idx["Core.lua"] and idx["Options/CopyWindow.lua"] > idx["Options/Widgets.lua"], "after Core and Widgets")
        assertTrue(L.exists(L.path("Options/CopyWindow.lua")))
        local n = 0
        for _, rel in ipairs(toc.files) do if rel:gsub("\\", "/") == "Options/CopyWindow.lua" then n = n + 1 end end
        assertEquals(n, 1)
    end)
    it("every file in Options/ is in the TOC (nothing forgotten)", function()
        local p = io.popen('ls "' .. L.addonDir .. '/Options"')
        local listed = {}
        for _, rel in ipairs(toc.files) do listed[rel:gsub("\\", "/")] = true end
        for f in p:lines() do if f:match("%.lua$") then assertTrue(listed["Options/" .. f], f .. " missing from the TOC") end end
        p:close()
    end)
    it("the ns API exists after load", function()
        local ns = boot()
        for _, f in ipairs({ "StoreDebug", "RunDebug", "ClearDebug", "FormatErrors", "CopyText" }) do assertEquals(type(ns[f]), "function", f) end
        assertEquals(type(ns.CopyWindow.Show), "function"); assertEquals(type(ns.CopyWindow.SetText), "function")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== capture
describe("debug log: capture", function()
    local ns = boot()
    it("starts empty", function() assertEquals(#ns.db.debugLog, 0) end)
    for _, cmd in ipairs({ "buffs", "auras", "click" }) do
        it("/hf debug " .. cmd .. " stores {time, cmd, lines} and still prints the lines", function()
            local before = #ns.db.debugLog
            local ok, err, out = slash("debug " .. cmd)
            assertTrue(ok, tostring(err))
            assertEquals(#ns.db.debugLog, before + 1)
            local run = lastRun(ns)
            assertEquals(run.cmd, cmd); assertEquals(type(run.time), "number"); assertEquals(type(run.lines), "table")
            assertTrue(#run.lines > 0, "captured lines")
            for _, line in ipairs(run.lines) do assertEquals(type(line), "string") end
            for _, line in ipairs(run.lines) do assertTrue(out:find(line, 1, true), "still printed: " .. line) end
            assertTrue(out:find("Output stored. /hf copy opens a window", 1, true), out)
            for _, line in ipairs(run.lines) do assertNil(line:find("Output stored", 1, true), "the status line is not part of the capture") end
            assertEquals(#mock.errors, 0, errstr())
        end)
    end
    it("a debug run that raises is captured as a 'failed:' line, and ns.Print is restored", function()
        local realPrint = ns.Print
        local lines = ns.RunDebug("boom", function() ns:Print("before"); error("kaboom") end)
        assertTrue(ns.Print == realPrint, "Print restored")
        assertEquals(lines[1], "before"); assertTrue(lines[2]:find("failed: ", 1, true) and lines[2]:find("kaboom", 1, true), lines[2])
        assertEquals(lastRun(ns).cmd, "boom")
    end)
    it("nested prints outside a run are not captured", function()
        local n = #lastRun(ns).lines
        ns:Print("stray")
        assertEquals(#lastRun(ns).lines, n)
    end)
    it("the click-watch toggle stores one run per modifier change while ON, nothing when OFF", function()
        local before = #ns.db.debugLog
        local _, _, out = slash("debug click watch")
        assertTrue(out:find("click watch ON", 1, true), out)
        assertTrue(ns.UnitFrames.debugClickWatch)
        assertEquals(#ns.db.debugLog, before, "toggling is not a run")
        mock.fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1)
        assertEquals(#ns.db.debugLog, before + 1)
        assertEquals(lastRun(ns).cmd, "click watch"); assertTrue(#lastRun(ns).lines > 0)
        mock.fire("MODIFIER_STATE_CHANGED", "LSHIFT", 0)
        assertEquals(#ns.db.debugLog, before + 2)
        local _, _, out2 = slash("debug click watch")
        assertTrue(out2:find("click watch off", 1, true), out2)
        mock.fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1)
        assertEquals(#ns.db.debugLog, before + 2, "off: nothing stored")
    end)
    it("unknown debug sub-commands print the usage (with clear and copy) and store nothing", function()
        local before = #ns.db.debugLog
        local _, _, out = slash("debug bogus")
        assertTrue(out:find("click watch", 1, true) and out:find("clear", 1, true) and out:find("copy", 1, true), out)
        assertEquals(#ns.db.debugLog, before)
    end)
end)

-- ======================================================================== cap + clear
describe("debug log: the last 10 runs are kept; /hf debug clear empties it", function()
    local ns = boot()
    it("13 runs keep the newest 10 in order", function()
        for i = 1, 13 do ns.StoreDebug("run" .. i, { "line" .. i }) end
        local log = ns.db.debugLog
        assertEquals(#log, 10)
        assertEquals(log[1].cmd, "run4"); assertEquals(log[10].cmd, "run13")
        for i = 1, 10 do assertEquals(log[i].lines[1], "line" .. (i + 3)) end
    end)
    it("exactly 10 are all kept; the 11th drops only the oldest", function()
        ns.ClearDebug()
        for i = 1, 10 do ns.StoreDebug("r" .. i, {}) end
        assertEquals(#ns.db.debugLog, 10); assertEquals(ns.db.debugLog[1].cmd, "r1")
        ns.StoreDebug("r11", {})
        assertEquals(#ns.db.debugLog, 10); assertEquals(ns.db.debugLog[1].cmd, "r2")
    end)
    it("real /hf debug runs obey the cap too", function()
        for _ = 1, 14 do slash("debug buffs") end
        assertEquals(#ns.db.debugLog, 10)
    end)
    it("an oversized or corrupted loaded log is repaired on the next store", function()
        local big = {}
        for i = 1, 25 do big[i] = { time = i, cmd = "old" .. i, lines = { "x" } } end
        local ns2 = boot({ char = { version = 3, debugLog = big } })
        ns2.StoreDebug("new", { "y" })
        assertTrue(#ns2.db.debugLog <= 10)
        assertEquals(ns2.db.debugLog[#ns2.db.debugLog].cmd, "new")
        local ns3 = boot({ char = { version = 3, debugLog = "garbage" } })
        assertTrue(pcall(ns3.StoreDebug, "z", { "a" }))
        assertEquals(type(ns3.db.debugLog), "table"); assertEquals(ns3.db.debugLog[#ns3.db.debugLog].cmd, "z")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("/hf debug clear empties the log, prints a confirmation and stores nothing itself", function()
        local ns3 = boot()
        slash("debug buffs"); slash("debug auras")
        assertEquals(#ns3.db.debugLog, 2)
        local ok, _, out = slash("debug clear")
        assertTrue(ok); assertTrue(out:find("Debug log cleared", 1, true), out)
        assertEquals(#ns3.db.debugLog, 0)
        assertNil(out:find("Output stored", 1, true))
    end)
    it("clear then copy shows the 'no debug output yet' text", function()
        local ns3 = boot()
        slash("debug buffs"); slash("debug clear"); slash("copy")
        assertTrue(copyFrame().edit:GetText():find("no debug output yet", 1, true))
    end)
    it("StoreDebug repairs a log that became a non-table at runtime", function()
        local ns3 = boot()
        ns3.db.debugLog = 5
        assertTrue(pcall(ns3.StoreDebug, "fix", { "a" }))
        assertEquals(type(ns3.db.debugLog), "table"); assertEquals(#ns3.db.debugLog, 1)
    end)
    it("ClearDebug without a database does not raise", function()
        local ns3 = boot(); local db = ns3.db; ns3.db = nil
        assertTrue(pcall(ns3.ClearDebug)); assertTrue(pcall(ns3.StoreDebug, "x", {}))
        ns3.db = db
    end)
end)

-- ======================================================================== saving
describe("debug log: sparse save and reload", function()
    it("an empty log is not written", function()
        local ns = boot()
        mock.fire("PLAYER_LOGOUT")
        assertNil(HealerForeverCharDB.debugLog)
    end)
    it("a non-empty log is saved and comes back after a reload", function()
        local ns = boot()
        slash("debug buffs"); slash("debug click")
        local buffs, click = deepcopy(ns.db.debugLog[1]), deepcopy(ns.db.debugLog[2])
        mock.fire("PLAYER_LOGOUT")
        local saved = deepcopy(HealerForeverCharDB)
        assertEquals(#saved.debugLog, 2)
        local ns2 = boot({ char = saved })
        assertEquals(#ns2.db.debugLog, 2)
        assertEquals(ns2.db.debugLog[1].cmd, "buffs"); assertEquals(ns2.db.debugLog[2].cmd, "click")
        assertEquals(#ns2.db.debugLog[1].lines, #buffs.lines); assertEquals(ns2.db.debugLog[2].lines[1], click.lines[1])
        assertEquals(ns2.db.debugLog[1].time, buffs.time)
        slash("copy")
        assertTrue(copyFrame().edit:GetText():find("== /hf debug click (", 1, true))
    end)
    it("clearing and saving removes it from the profile again", function()
        local ns = boot()
        slash("debug buffs"); mock.fire("PLAYER_LOGOUT"); assertNotNil(HealerForeverCharDB.debugLog)
        slash("debug clear"); mock.fire("PLAYER_LOGOUT")
        assertNil(HealerForeverCharDB.debugLog)
    end)
    it("the log never leaks into the account-wide DB or the defaults", function()
        local ns = boot()
        slash("debug buffs")
        assertEquals(#ns.DEFAULTS.debugLog, 0, "defaults stay empty")
        mock.fire("PLAYER_LOGOUT")
        assertTrue(_G.HealerForeverDB == nil or _G.HealerForeverDB.debugLog == nil)
    end)
    it("a reset to defaults empties the debug log", function()
        local ns = boot()
        slash("debug buffs"); ns:ResetDB()
        assertEquals(#ns.db.debugLog, 0)
    end)
end)

-- ======================================================================== error formatting
describe("debug log: /hf errors uses the shared formatter (stacks included)", function()
    local ns = boot()
    addError(ns, "bad thing", "stack line 1\nstack line 2")
    addError(ns, "other", nil)
    it("FormatErrors returns header lines and indented stack lines", function()
        local lines = ns.FormatErrors(10)
        assertEquals(#lines, 3)
        assertTrue(lines[1]:find("UNIT_AURA", 1, true) and lines[1]:find("bad thing", 1, true), lines[1])
        assertTrue(lines[2]:find("^    stack line 1"), lines[2]); assertTrue(lines[2]:find("\n    stack line 2", 1, true), lines[2])
        assertNil(lines[3]:find("^    "))
    end)
    it("limit and repeat counts", function()
        assertEquals(#ns.FormatErrors(1), 1)
        ns.db.errorLog[1].count = 3
        assertTrue(ns.FormatErrors(10)[1]:find("x3", 1, true))
        ns.db.errorLog[1].kind = "blocked"
        assertTrue(ns.FormatErrors(10)[1]:find("BLOCKED", 1, true))
    end)
    it("/hf errors prints the formatted lines including the stack", function()
        local _, _, out = slash("errors")
        assertTrue(out:find("bad thing", 1, true) and out:find("stack line 1", 1, true), out)
        assertTrue(out:find("/hf copy opens a copyable window", 1, true), out)
    end)
    it("junk entries in the log are skipped", function()
        ns.db.errorLog[#ns.db.errorLog + 1] = "junk"; ns.db.errorLog[#ns.db.errorLog + 1] = 5
        assertTrue(pcall(ns.FormatErrors, 20))
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== copy window
describe("debug log: the copy window", function()
    local ns = boot()
    slash("debug buffs")
    addError(ns, "bad thing", "stack here")
    it("/hf copy opens a non-secure window with an EditBox holding the last run and the error log", function()
        slash("copy")
        local f = copyFrame()
        assertNotNil(f); assertTrue(st(f).shown); assertFalse(st(f).secure and true or false)
        assertEquals(st(f.edit).kind, "EditBox")
        local text = f.edit:GetText()
        assertEquals(text, ns.CopyText())
        assertTrue(text:find("== /hf debug buffs (", 1, true), text)
        for _, line in ipairs(lastRun(ns).lines) do assertTrue(text:find(line, 1, true), line) end
        assertTrue(text:find("== /hf errors (2 lines) ==", 1, true), text)
        assertTrue(text:find("bad thing", 1, true) and text:find("stack here", 1, true), text)
    end)
    it("it is multi-line, scrollable (ScrollFrame child) and pre-selected; focus is set after OnShow", function()
        local f = copyFrame()
        assertEquals(st(f.scroll).kind, "ScrollFrame"); assertEquals(st(f.scroll).scrollChild, f.edit)
        assertNotNil(st(f.edit).highlighted, "text is selected")
        st(f.edit).focused = false; st(f.edit).highlighted = nil
        mock.runFrameScript(f, "OnShow"); mock.flushTimers()    -- the mock's Show() does not fire OnShow itself
        assertTrue(st(f.edit).focused, "focused after the OnShow timer")
        assertNotNil(st(f.edit).highlighted, "selected after the OnShow timer")
    end)
    it("showing again refreshes the text with the newest run and re-selects it", function()
        slash("debug auras")
        local f = copyFrame()
        f:Hide(); slash("copy")
        assertTrue(f.edit:GetText():find("== /hf debug auras (", 1, true))
        assertNotNil(st(f.edit).highlighted)
    end)
    it("is the same frame every time (one window)", function()
        local f = copyFrame()
        slash("copy"); slash("copy")
        assertTrue(copyFrame() == f)
        local n = 0
        for _, fr in ipairs(mock.frames) do if st(fr).name == "HealerForeverCopyFrame" then n = n + 1 end end
        assertEquals(n, 1)
    end)
    it("the X closes it", function()
        local f = copyFrame(); slash("copy"); assertTrue(st(f).shown)
        local cb = f.close
        assertNotNil(cb); st(cb).scripts.OnClick(cb, "LeftButton")
        assertFalse(st(f).shown)
    end)
    it("ESC closes it: registered once in UISpecialFrames, and Escape in the EditBox hides it", function()
        local n = 0
        for _, name in ipairs(_G.UISpecialFrames) do if name == "HealerForeverCopyFrame" then n = n + 1 end end
        assertEquals(n, 1)
        local f = copyFrame(); slash("copy"); assertTrue(st(f).shown)
        st(f.edit).scripts.OnEscapePressed(f.edit)
        assertFalse(st(f).shown)
        slash("copy"); assertTrue(st(f).shown)
        for _, name in ipairs(_G.UISpecialFrames) do local fr = _G[name]; if fr and st(fr).shown then fr:Hide() end end
        assertFalse(st(f).shown, "UISpecialFrames-style ESC")
    end)
    it("typed edits are reverted to the original text and the text is re-selected", function()
        local f = copyFrame(); slash("copy")
        local original = f.edit:GetText()
        f.edit:SetText("I typed something")
        st(f.edit).scripts.OnTextChanged(f.edit, true)
        assertEquals(f.edit:GetText(), original)
        assertNotNil(st(f.edit).highlighted)
        f.edit:SetText("")
        st(f.edit).scripts.OnTextChanged(f.edit, true)
        assertEquals(f.edit:GetText(), original)
    end)
    it("programmatic text changes (userInput=false) are not reverted", function()
        local f = copyFrame()
        ns.CopyWindow:SetText("fresh text")
        st(f.edit).scripts.OnTextChanged(f.edit, false)
        assertEquals(f.edit:GetText(), "fresh text")
        assertEquals(f.text, "fresh text")
        f.edit:SetText("changed by the program")
        st(f.edit).scripts.OnTextChanged(f.edit, false)
        assertEquals(f.edit:GetText(), "changed by the program", "only typed input is reverted")
    end)
    it("a long text (many debug lines) fits without error", function()
        local lines = {}
        for i = 1, 2000 do lines[i] = "line " .. i end
        ns.StoreDebug("big", lines)
        slash("copy")
        assertTrue(#copyFrame().edit:GetText() > 10000)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("window is draggable and clamped, in the DIALOG strata, and does not take part in click-casting", function()
        local f = copyFrame()
        assertEquals(st(f).strata, "DIALOG")
        assertEquals(type(st(f).scripts.OnDragStart), "function")
        assertFalse(st(f).secure and true or false)
    end)
end)

-- ======================================================================== slash args
describe("debug log: slash arguments that open the copy window", function()
    local function opens(msg, wantCmd)
        local ns = boot()
        if copyFrame() then copyFrame():Hide() end
        local ok, err = slash(msg)
        assertTrue(ok, msg .. ": " .. tostring(err))
        assertNotNil(copyFrame(), msg); assertTrue(st(copyFrame()).shown, msg .. " opens the window")
        if wantCmd then assertTrue(copyFrame().edit:GetText():find("== /hf debug " .. wantCmd .. " (", 1, true), msg .. ": " .. copyFrame().edit:GetText()) end
        assertEquals(#mock.errors, 0, errstr())
        return ns
    end
    it("/hf copy", function() opens("copy") end)
    it("/hf errors copy", function() opens("errors copy") end)
    it("/hf debug buffs copy", function() opens("debug buffs copy", "buffs") end)
    it("/hf debug auras copy", function() opens("debug auras copy", "auras") end)
    it("/hf debug click copy", function() opens("debug click copy", "click") end)
    it("the arguments are case-insensitive", function() opens("DEBUG Buffs COPY", "buffs") end)
    it("without 'copy' the window is NOT opened", function()
        local ns = boot()
        slash("debug buffs"); slash("debug auras"); slash("debug click"); slash("errors")
        assertTrue(copyFrame() == nil or not st(copyFrame()).shown)
    end)
    it("'debug clear' and 'debug click watch' never open the window", function()
        local ns = boot()
        slash("debug clear"); slash("debug click watch"); slash("debug click watch")
        assertTrue(copyFrame() == nil or not st(copyFrame()).shown)
    end)
    it("'/hf errors copy' works with an empty error log", function()
        local ns = boot()
        slash("errors copy")
        assertTrue(copyFrame().edit:GetText():find("== /hf errors (0 lines) ==", 1, true))
    end)
    it("the usage text mentions copy and the help line lists copy", function()
        local ns = boot()
        local _, _, out = slash("debug")
        assertTrue(out:find("copy", 1, true), out)
        local _, _, help = slash("help")
        assertTrue(help:find("/hf copy", 1, true), help)
    end)
end)

-- ======================================================================== combat + secrets
describe("debug log: combat and everything-secret", function()
    it("in combat the debug commands, the log and the copy window make no protected calls and raise nothing", function()
        local ns = boot()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0 = #mock.violations, #mock.softViolations
        for _, c in ipairs({ "debug buffs", "debug auras", "debug click", "debug click copy", "debug clear", "copy", "errors copy", "errors" }) do
            local ok, err = slash(c); assertTrue(ok, c .. ": " .. tostring(err))
        end
        local f = copyFrame(); assertTrue(st(f).shown)
        st(f.close).scripts.OnClick(f.close, "LeftButton"); assertFalse(st(f).shown)
        slash("debug click watch"); mock.fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1); slash("debug click watch")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0); assertEquals(#mock.errors, 0, errstr())
    end)
    it("with every value secret the runs, storing, copy text and the window all work", function()
        local ns = boot()
        S.secretAll = true; S.secret = true; S.secretTable = true
        S.auras.party1 = { { spellId = 1, name = "A", icon = 1, duration = 10, expirationTime = S.now + 5, isHarmful = true, isHelpful = false, auraInstanceID = 5 } }
        mock.fire("UNIT_AURA", "party1")
        for _, c in ipairs({ "debug buffs", "debug auras", "debug click", "debug auras copy", "copy", "errors copy" }) do
            local ok, err = slash(c); assertTrue(ok, c .. ": " .. tostring(err))
        end
        assertEquals(type(copyFrame().edit:GetText()), "string")
        for _, run in ipairs(ns.db.debugLog) do for _, line in ipairs(run.lines) do assertEquals(type(line), "string") end end
        mock.fire("PLAYER_LOGOUT")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secret error messages in the log do not break the formatter or the window", function()
        local ns = boot()
        ns.db.errorLog[1] = { time = 1, label = "x", msg = "m", combat = true, count = 1, kind = "error" }
        S.secretAll = true
        assertTrue(pcall(ns.CopyText)); assertTrue(pcall(ns.FormatErrors, 5))
        assertTrue(slash("copy"))
        assertEquals(#mock.errors, 0, errstr())
    end)
end)
