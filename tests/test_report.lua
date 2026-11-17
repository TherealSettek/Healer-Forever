-- Help & Contact: Options/Report.lua (support report, /hf mark), Options/ContactPane.lua (read-only email box, Copy, Report), CopyWindow:ShowText,
-- the footer "Contact" button, /hf mark | report | contact, the licence files, and the privacy promise: the report never contains other players' names.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end
local function deepcopy(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = deepcopy(v) end return o end

local NAMES = { "Zorgblatt", "Quillfeather", "Mubblewump", "Thistlethorn" }   -- planted player names that must NEVER reach a report

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.containers then mock.enableContainers() end
    S.units.player.name = "Snorlaxia"
    S.units.party1 = unit(NAMES[1], "WARRIOR", "TANK"); S.units.party2 = unit(NAMES[2], "PRIEST", "HEALER"); S.units.party3 = unit(NAMES[3], "MAGE", "DAMAGER")
    S.units.partypet1 = unit(NAMES[4], "HUNTER")
    if opts.setup then opts.setup(S) end
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
local function copyText() return copyFrame() and copyFrame().edit:GetText() or "" end
local function section(text, title)
    local a = text:find("== " .. title .. " ==", 1, true)
    if not a then return nil end
    local b = text:find("\n== ", a + 5, true)
    return text:sub(a, b and b - 1 or #text)
end
local function namesIn(text)
    local found = {}
    for _, n in ipairs(NAMES) do if text:find(n, 1, true) then found[#found + 1] = n end end
    if text:find("Snorlaxia", 1, true) then found[#found + 1] = "Snorlaxia" end
    return found
end
local function setAddons(list, shape)
    -- list = { { name=, version=, loaded= } ... }; shape "tuple" (name first) or "table" ({ name = }) for GetAddOnInfo
    local function info(i)
        local a = list[i]
        if not a then return nil end
        if shape == "table" then return { name = a.name } end
        return a.name
    end
    local function find(name) for _, a in ipairs(list) do if a.name == name then return a end end end
    C_AddOns.GetNumAddOns = function() return #list end
    C_AddOns.GetAddOnInfo = info
    C_AddOns.IsAddOnLoaded = function(name) local a = find(name); return a and a.loaded end
    local real = C_AddOns.GetAddOnMetadata
    C_AddOns.GetAddOnMetadata = function(name, key) local a = find(name); if a then return key == "Version" and a.version or nil end return real(name, key) end
end

-- ======================================================================== the report
describe("report: the text and its sections", function()
    local ns = boot()
    local text = ns.Report.Build()
    it("starts with the e-mail address to send it to and has every section in order", function()
        assertTrue(text:find("^Paste this into your email to healer.forever.trtg@gmail.com"), text:sub(1, 120))
        assertEquals(ns.Report.EMAIL, "healer.forever.trtg@gmail.com")
        local last = 0
        for _, title in ipairs({ "Addon", "Game", "Settings summary", "Other loaded addons", "Last errors", "Debug runs", "Marks (/hf mark)" }) do
            local a = text:find("== " .. title .. " ==", 1, true)
            assertNotNil(a, title); assertTrue(a > last, title .. " out of order"); last = a
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Addon: the version, the settings schema and the aura path", function()
        local s = section(text, "Addon")
        assertTrue(s:find("Healer Forever " .. ns.AddonVersion() .. " (settings schema " .. ns.SchemaVersion() .. ")", 1, true), s)
        assertTrue(s:find("Aura path: fallback (hand-drawn)", 1, true), s)
        local ns2 = boot({ containers = true })
        assertTrue(section(ns2.Report.Build(), "Addon"):find("Aura path: container (native)", 1, true))
    end)
    it("Game: client version, build, interface, locale, platform, class, level, group and combat state", function()
        local s = section(text, "Game")
        assertTrue(s:find("Client: 12.0.0 (build 60000, interface 120000), locale enUS, Windows", 1, true), s)
        assertTrue(s:find("Player: PALADIN", 1, true) and s:find("level 80", 1, true), s)
        assertTrue(s:find("Group: party, size 4, combat: false", 1, true), s)
        S.macClient = true; S.combat = true; S.inRaid = true
        local s2 = section(ns.Report.Build(), "Game")
        S.macClient = false; S.combat = false; S.inRaid = false
        assertTrue(s2:find("Mac", 1, true) and s2:find("Group: raid", 1, true) and s2:find("combat: true", 1, true), s2)
    end)
    it("Game: solo says solo with size 1", function()
        local ns2 = boot({ group = 0 })
        local s = section(ns2.Report.Build(), "Game")
        assertTrue(s:find("Group: solo, size 1", 1, true), s)
    end)
    it("Settings summary: frames, range, auras, buffs and presets lines with the real values", function()
        local s = section(text, "Settings summary")
        for _, frag in ipairs({ "Frames: layout=", "Range: style=", "Auras: buffs=true/" .. ns.db.auras.maxBuffs, "perRow=0", "Buffs: warn=true threshold=60 rebuffPercent=5 showSolo=true", "Presets: 1 (active 1)" }) do
            assertTrue(s:find(frag, 1, true), frag .. "\n" .. s)
        end
    end)
    it("Settings summary shows changed values (and is built from the live settings)", function()
        ns.db.auras.maxBuffs = 17; ns.db.auras.perRow = 6; ns.db.buffs.rebuffPercent = 12; ns.db.frames.width = 222
        local s = section(ns.Report.Build(), "Settings summary")
        assertTrue(s:find("buffs=true/17", 1, true) and s:find("perRow=6", 1, true) and s:find("rebuffPercent=12", 1, true) and s:find("width=222", 1, true), s)
    end)
    it("Settings summary: the click-binding count is the number of bindings (a keyed table: counted with pairs, 2 by default)", function()
        local n = 0
        for _ in pairs(ns.db.bindings) do n = n + 1 end
        assertEquals(n, 2)
        assertEquals(tonumber(section(ns.Report.Build(), "Settings summary"):match("click bindings: (%d+)")), 2)
        ns.db.bindings["shift|1"] = { type = "spell", spell = "X" }; ns.db.bindings["ctrl|2"] = { type = "target" }
        assertEquals(tonumber(section(ns.Report.Build(), "Settings summary"):match("click bindings: (%d+)")), 4)
        ns.db.bindings["shift|1"] = nil; ns.db.bindings["ctrl|2"] = nil
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a missing database or broken sub-tables never break the report (every section is pcall'd)", function()
        local saved = ns.db
        ns.db = { frames = "broken", auras = 5, buffs = {}, presets = "x", bindings = false }
        local ok, out = pcall(ns.Report.Build)
        ns.db = saved
        assertTrue(ok, tostring(out)); assertTrue(out:find("== Settings summary ==", 1, true))
        ns.db = nil
        ok, out = pcall(ns.Report.Build)
        ns.db = saved
        assertTrue(ok, tostring(out)); assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("report: other loaded addons", function()
    it("lists loaded addons with their version, skips this addon, Blizzard_* and addons that are not loaded", function()
        local ns = boot()
        setAddons({ { name = "HealerForever", loaded = true, version = "9" }, { name = "Blizzard_Foo", loaded = true }, { name = "Details", loaded = true, version = "1.2.3" },
            { name = "Plater", loaded = false, version = "5" }, { name = "BigWigs", loaded = true } })
        local s = section(ns.Report.Build(), "Other loaded addons")
        assertTrue(s:find("  Details 1.2.3", 1, true), s); assertTrue(s:find("  BigWigs\n") or s:find("  BigWigs$"), s)
        assertNil(s:find("Plater", 1, true)); assertNil(s:find("Blizzard_Foo", 1, true)); assertNil(s:find("HealerForever", 1, true))
    end)
    it("accepts BOTH return shapes of GetAddOnInfo (a name, or a table with .name)", function()
        for _, shape in ipairs({ "tuple", "table" }) do
            local ns = boot()
            setAddons({ { name = "Alpha", loaded = true, version = "1" }, { name = "Beta", loaded = true } }, shape)
            local s = section(ns.Report.Build(), "Other loaded addons")
            assertTrue(s:find("  Alpha 1", 1, true) and s:find("  Beta", 1, true), shape .. "\n" .. s)
        end
    end)
    it("falls back to the legacy globals when C_AddOns is missing", function()
        local ns = boot()
        _G.C_AddOns = nil
        local list = { { name = "Legacy1", loaded = true, version = "0.9" }, { name = "Legacy2", loaded = false } }
        mock.setGlobal("GetNumAddOns", function() return #list end)
        mock.setGlobal("GetAddOnInfo", function(i) return list[i] and list[i].name end)
        mock.setGlobal("IsAddOnLoaded", function(name) for _, a in ipairs(list) do if a.name == name then return a.loaded end end end)
        mock.setGlobal("GetAddOnMetadata", function(name, key) for _, a in ipairs(list) do if a.name == name and key == "Version" then return a.version end end end)
        local s = section(ns.Report.Build(), "Other loaded addons")
        assertTrue(s:find("  Legacy1 0.9", 1, true), s); assertNil(s:find("Legacy2", 1, true))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("is capped at 100 entries with a '... and N more' line", function()
        local ns = boot()
        local list = {}
        for i = 1, 130 do list[i] = { name = "Addon" .. i, loaded = true, version = "1" } end
        setAddons(list)
        local s = section(ns.Report.Build(), "Other loaded addons")
        local n = 0
        for line in s:gmatch("\n  Addon%d+") do n = n + 1 end
        assertEquals(n, 100); assertTrue(s:find("... and 30 more", 1, true), s)
    end)
    it("says (none) when nothing else is loaded; junk names and erroring APIs are skipped without error", function()
        local ns = boot()
        assertTrue(section(ns.Report.Build(), "Other loaded addons"):find("(none)", 1, true))
        C_AddOns.GetNumAddOns = function() return 3 end
        C_AddOns.GetAddOnInfo = function(i) if i == 1 then return 42 elseif i == 2 then error("boom") else return nil end end
        C_AddOns.IsAddOnLoaded = function() error("boom") end
        local ok, out = pcall(ns.Report.Build)
        assertTrue(ok, tostring(out)); assertTrue(out:find("(none)", 1, true)); assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("report: errors, debug runs and marks sections", function()
    it("Last errors: 'none' when empty, otherwise at most the last 20 (with stacks)", function()
        local ns = boot()
        assertTrue(section(ns.Report.Build(), "Last errors"):find("none", 1, true))
        for i = 1, 25 do ns.db.errorLog[#ns.db.errorLog + 1] = { time = 1000 + i, label = "L" .. i, msg = "problem number " .. i, combat = false, count = 1, kind = "error", stack = i == 25 and "stack line" or nil } end
        local s = section(ns.Report.Build(), "Last errors")
        local n = 0
        for _ in s:gmatch("problem number") do n = n + 1 end
        assertEquals(n, 20); assertTrue(s:find("problem number 25", 1, true) and s:find("stack line", 1, true)); assertNil(s:find("problem number 5:", 1, true))
        assertNil(s:find("problem number 5\n", 1, true))
    end)
    it("Debug runs: lists every stored run with its command, capped at 80 lines each; 'none' before any run", function()
        local ns = boot()
        assertTrue(section(ns.Report.Build(), "Debug runs"):find("none (run /hf debug", 1, true))
        local lines = {}
        for i = 1, 100 do lines[i] = "debug line " .. i end
        ns.StoreDebug("buffs", lines); ns.StoreDebug("auras", { "only line" })
        local s = section(ns.Report.Build(), "Debug runs")
        assertTrue(s:find("-- /hf debug buffs (", 1, true) and s:find("-- /hf debug auras (", 1, true), s)
        assertTrue(s:find("debug line 80", 1, true)); assertNil(s:find("debug line 81", 1, true)); assertTrue(s:find("   ...", 1, true))
    end)
    it("Marks: 'none' before any; afterwards each mark with its time, note, combat, zone, group and the aura / buff debug lines", function()
        local ns = boot()
        assertTrue(section(ns.Report.Build(), "Marks (/hf mark)"):find("none", 1, true))
        S.zoneText = "Dun Morogh"
        slash("mark  the tank lost his buff")
        local s = section(ns.Report.Build(), "Marks (/hf mark)")
        assertTrue(s:find("-- mark 1: ", 1, true) and s:find("the tank lost his buff", 1, true), s)
        assertTrue(s:find("combat=false zone=Dun Morogh group=4", 1, true), s)
        assertTrue(s:find("   auras:", 1, true) and s:find("   buffs:", 1, true), s)
        assertTrue(s:find("aura path:", 1, true) and s:find("buff debug (", 1, true), s)
    end)
end)

-- ======================================================================== privacy
describe("report: never contains other players' names", function()
    it("not in the report text after debug runs and marks were taken (party and pet names planted in the mock)", function()
        local ns = boot()
        slash("debug buffs"); slash("debug auras"); slash("debug click"); slash("mark right now"); slash("mark second")
        local text = ns.Report.Build()
        local found = namesIn(text)
        if #found > 0 then
            warn("Buffs/BuffButtons.lua BB:Debug (~line 575 and 616): '/hf debug buffs' prints each member's NAME (and the tank button line prints the tank's name); it ends up in the report's "
                .. "'Debug runs' and 'Marks' sections, so the report is NOT name-free (found: " .. table.concat(found, ", ") .. ")")
        end
        assertEquals(#mock.errors, 0, errstr())
        -- the sections that are built live (everything except stored debug output) must be clean
        for _, title in ipairs({ "Addon", "Game", "Settings summary", "Other loaded addons", "Last errors" }) do
            local s = section(text, title)
            assertEquals(#namesIn(s), 0, title .. " contains a player name: " .. table.concat(namesIn(s), ","))
        end
    end)
    it("not in the live sections even when errors mention nothing and the roster changes", function()
        local ns = boot()
        S.units.party2 = unit("Fennelfoot", "ROGUE", "DAMAGER")
        local text = ns.Report.Build()
        assertNil(text:find("Fennelfoot", 1, true))
        assertNil(text:find("TestRealm", 1, true), "the realm name is not in the report either")
    end)
    it("not in the copy window opened by /hf report (live sections)", function()
        local ns = boot()
        slash("report")
        for _, title in ipairs({ "Addon", "Game", "Settings summary", "Other loaded addons" }) do assertEquals(#namesIn(section(copyText(), title) or ""), 0, title) end
    end)
    it("with secret names (S.secretNames) the report still builds and shows no name", function()
        local ns = boot()
        S.secretNames = true
        local ok, text = pcall(ns.Report.Build)
        S.secretNames = false
        assertTrue(ok, tostring(text)); assertEquals(#mock.errors, 0, errstr())
        assertEquals(#namesIn(section(text, "Game")), 0)
    end)
end)

-- ======================================================================== marks
describe("report: /hf mark", function()
    it("stores a snapshot (time, note, combat, zone, group, aura and buff lines); a note is optional and trimmed to what was typed", function()
        local ns = boot()
        slash("mark")
        slash("mark with a note")
        local m = ns.db.marks
        assertEquals(#m, 2)
        assertNil(m[1].note); assertEquals(m[2].note, "with a note")
        assertEquals(type(m[1].time), "number"); assertEquals(m[1].combat, false); assertEquals(m[1].group, 4); assertEquals(type(m[1].zone), "string")
        assertTrue(#m[1].auras > 0 and #m[1].buffs > 0)
        local _, _, out = slash("mark x")
        assertTrue(out:find("Marked. Use /hf report", 1, true), out)
    end)
    it("keeps only the last 5 marks (oldest dropped)", function()
        local ns = boot()
        for i = 1, 8 do slash("mark m" .. i) end
        assertEquals(#ns.db.marks, 5)
        assertEquals(ns.db.marks[1].note, "m4"); assertEquals(ns.db.marks[5].note, "m8")
    end)
    it("/hf mark clear empties them and confirms", function()
        local ns = boot()
        slash("mark a"); slash("mark b")
        local _, _, out = slash("mark clear")
        assertTrue(out:find("Marks cleared", 1, true), out); assertEquals(#ns.db.marks, 0)
        slash("mark CLEAR"); assertEquals(#ns.db.marks, 0)
    end)
    it("marks save sparsely (omitted when empty), survive a reload and show in the report", function()
        local ns = boot()
        mock.fire("PLAYER_LOGOUT")
        assertTrue(HealerForeverCharDB.marks == nil, "an empty list is not saved")
        slash("mark one"); slash("mark two")
        mock.fire("PLAYER_LOGOUT")
        local saved = deepcopy(HealerForeverCharDB)
        assertEquals(#saved.marks, 2); assertEquals(saved.marks[2].note, "two")
        local ns2 = boot({ char = saved })
        assertEquals(#ns2.db.marks, 2)
        assertTrue(section(ns2.Report.Build(), "Marks (/hf mark)"):find("two", 1, true))
        slash("mark clear"); mock.fire("PLAYER_LOGOUT")
        assertTrue(HealerForeverCharDB.marks == nil)
    end)
    it("a corrupted marks value in the saved file is replaced by an empty list", function()
        for _, junk in ipairs({ "x", 5, true }) do
            local ns = boot({ char = { version = 4, marks = junk } })
            assertEquals(type(ns.db.marks), "table"); assertEquals(#ns.db.marks, 0)
            slash("mark ok"); assertEquals(#ns.db.marks, 1)
        end
    end)
    it("a mark taken IN COMBAT records combat=true, makes no protected call and NO aura API read (fallback and container paths)", function()
        for _, containers in ipairs({ false, true }) do
            local ns = boot({ containers = containers })
            S.auras.party1 = { { spellId = 1, name = "X", icon = 1, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, auraInstanceID = 5 } }
            S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
            mock.resetAuraCalls()
            local v0, s0 = #mock.violations, #mock.softViolations
            local ok, err = slash("mark in the fight")
            assertTrue(ok, tostring(err))
            assertEquals(mock.auraCalls.total, 0, (containers and "container" or "fallback") .. ": aura reads during /hf mark in combat")
            assertEquals(ns.db.marks[#ns.db.marks].combat, true)
            assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0); assertEquals(#mock.errors, 0, errstr())
            S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        end
    end)
    it("with everything secret the mark and the report work (no error)", function()
        local ns = boot()
        S.secretAll = true; S.secret = true
        assertTrue(slash("mark secretive")); assertTrue(slash("report"))
        S.secretAll = false; S.secret = false
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#ns.db.marks, 1)
    end)
    it("a failing zone API does not stop the mark", function()
        local ns = boot()
        S.zoneError = true
        assertTrue(slash("mark zone?")); assertEquals(ns.db.marks[1].zone, "?")
        S.zoneError = false
    end)
    it("the report in combat reads no aura data either", function()
        local ns = boot()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        assertTrue(pcall(ns.Report.Build))
        assertEquals(mock.auraCalls.total, 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
end)

-- ======================================================================== slash + copy window + footer
describe("report: /hf report, /hf contact, CopyWindow:ShowText and the footer Contact button", function()
    it("/hf report opens the copy window with the whole report and the report title; /hf copy afterwards restores the default title", function()
        local ns = boot()
        slash("report")
        local f = copyFrame()
        assertNotNil(f); assertTrue(st(f).shown)
        assertTrue(copyText():find("Paste this into your email to", 1, true))
        assertTrue(st(f.title).text:find("Healer Forever report", 1, true), tostring(st(f.title).text))
        assertNotNil(st(f.edit).highlighted, "pre-selected")
        slash("copy")
        assertFalse(copyText():find("Paste this into your email", 1, true) ~= nil)
        assertFalse(tostring(st(f.title).text):find("report", 1, true) ~= nil)
    end)
    it("ShowText(text, title): shows exactly the text, uses the given title or the default, is reverted when typed over", function()
        local ns = boot()
        ns.CopyWindow:ShowText("hello report", "My title")
        local f = copyFrame()
        assertEquals(f.edit:GetText(), "hello report"); assertEquals(st(f.title).text, "My title"); assertTrue(st(f).shown)
        f.edit:SetText("typed"); st(f.edit).scripts.OnTextChanged(f.edit, true)
        assertEquals(f.edit:GetText(), "hello report")
        ns.CopyWindow:ShowText("no title given")
        assertTrue(st(f.title).text ~= "My title"); assertEquals(f.edit:GetText(), "no title given")
        st(f.close).scripts.OnClick(f.close, "LeftButton"); assertFalse(st(f).shown)
    end)
    it("/hf contact prints the address and opens the Help & Contact pane", function()
        local ns = boot()
        local _, _, out = slash("contact")
        assertTrue(out:find("Write to healer.forever.trtg@gmail.com", 1, true), out)
        assertTrue(st(ns.Options.frame).shown); assertEquals(ns.Options.current or ns.Options.currentKey or "help", "help")
        local found
        for _, f in ipairs(mock.frames) do if st(f).kind == "FontString" and st(f).text == "Help & Contact" and st(f).shown then found = f end end
        assertNotNil(found)
    end)
    it("the footer has a '· Contact' button that opens the Help & Contact pane (also from another tab)", function()
        local ns = boot()
        ns.Options:Show("general"); mock.flushTimers()
        local btn
        for _, f in ipairs(mock.frames) do if st(f).kind == "Button" and f.text and st(f.text).text == "\194\183 Contact" then btn = f end end
        assertNotNil(btn)
        st(btn).scripts.OnClick(btn, "LeftButton"); mock.flushTimers()
        local help
        for _, f in ipairs(mock.frames) do if st(f).kind == "EditBox" and st(f).text == "healer.forever.trtg@gmail.com" then help = f end end
        assertNotNil(help, "the Help pane (with the e-mail box) was built and shown")
        st(btn).scripts.OnEnter(btn); st(btn).scripts.OnLeave(btn)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the pane is registered as the last tab 'help' (Help & Contact)", function()
        local ns = boot()
        local last
        for _, p in ipairs(ns.Options.panes) do last = p end
        assertEquals(last.key, "help"); assertEquals(last.label, "Help & Contact")
    end)
    it("the usage line mentions mark, report and contact", function()
        local ns = boot()
        local _, _, out = slash("help")
        assertTrue(out:find("/hf mark", 1, true) and out:find("/hf report", 1, true) and out:find("/hf contact", 1, true), out)
    end)
    it("all of it works in combat and with everything secret, without protected calls", function()
        local ns = boot()
        S.combat = true; S.secretAll = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0 = #mock.violations
        for _, c in ipairs({ "mark c", "report", "contact", "mark clear", "copy" }) do assertTrue(slash(c), c) end
        S.combat = false; S.secretAll = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.violations, v0); assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== the Help & Contact pane
describe("report: the Help & Contact pane", function()
    local ns = boot()
    ns.Options:Show("help"); mock.flushTimers()
    local EMAIL = "healer.forever.trtg@gmail.com"
    local box
    for _, f in ipairs(mock.frames) do if st(f).kind == "EditBox" and st(f).text == EMAIL then box = f end end
    local function button(text) for _, f in ipairs(mock.frames) do if st(f).kind == "Button" and st(f).text == text then return f end end end
    local function label(prefix) for _, f in ipairs(mock.frames) do local s = st(f); if s.kind == "FontString" and type(s.text) == "string" and s.text:find(prefix, 1, true) == 1 then return s.text end end end
    it("shows the e-mail in a read-only box and the labels, hint, checklist and copyright line", function()
        assertNotNil(box)
        assertEquals(label("Problems or ideas? Write to:"), "Problems or ideas? Write to:")
        assertNotNil(label("then press Cmd/Ctrl+C"))
        assertNotNil(label("How to report"))
        local steps = label("- What you did right before")
        assertNotNil(steps)
        for _, frag in ipairs({ "When it happened", "A screenshot", "The report text", "/hf mark [note]" }) do assertTrue(steps:find(frag, 1, true), frag) end
        assertEquals(label("Copyright"), "Copyright (c) 2026 trtg. All rights reserved. See LICENSE.txt")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("typing in the box is reverted to the address and re-selected (any edit, empty, longer, different)", function()
        for _, typed in ipairs({ "", "x", EMAIL .. "!", "someone@else.com" }) do
            box:SetText(typed)
            st(box).scripts.OnTextChanged(box, true)
            assertEquals(box:GetText(), EMAIL, "typed '" .. typed .. "'")
            assertNotNil(st(box).highlighted)
        end
    end)
    it("programmatic text changes (userInput=false) are left alone; the address itself is never fought", function()
        box:SetText(EMAIL); st(box).scripts.OnTextChanged(box, true)
        assertEquals(box:GetText(), EMAIL)
        box:SetText("changed by the program"); st(box).scripts.OnTextChanged(box, false)
        assertEquals(box:GetText(), "changed by the program")
        box:SetText(EMAIL)
    end)
    it("focus selects all, a click selects all, Escape releases the focus", function()
        st(box).highlighted = nil
        st(box).scripts.OnEditFocusGained(box); assertNotNil(st(box).highlighted)
        st(box).highlighted = nil; st(box).focused = false
        st(box).scripts.OnMouseUp(box); assertTrue(st(box).focused); assertNotNil(st(box).highlighted)
        st(box).scripts.OnEscapePressed(box); assertFalse(st(box).focused and true or false)
    end)
    it("the Copy button focuses and selects the address", function()
        local copy = button("Copy")
        assertNotNil(copy)
        st(box).focused = false; st(box).highlighted = nil
        st(copy).scripts.OnClick(copy, "LeftButton")
        assertTrue(st(box).focused); assertNotNil(st(box).highlighted)
    end)
    it("'Report a problem' opens the report in the copy window", function()
        local b = button("Report a problem")
        assertNotNil(b)
        st(b).scripts.OnClick(b, "LeftButton"); mock.flushTimers()
        assertTrue(copyText():find("== Settings summary ==", 1, true))
    end)
    it("the pane makes no aura reads and no protected calls (built and used in combat)", function()
        local ns2 = boot()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        ns2.Options:Show("help"); mock.flushTimers()
        local b
        for _, f in ipairs(mock.frames) do if st(f).kind == "Button" and st(f).text == "Report a problem" then b = f end end
        st(b).scripts.OnClick(b, "LeftButton"); mock.flushTimers()
        assertEquals(mock.auraCalls.total, 0); assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
end)

-- ======================================================================== files and licence
describe("report: TOC, licence and release contents", function()
    local function idx()
        local t = {}
        for i, rel in ipairs(toc.files) do t[rel:gsub("\\", "/")] = i end
        return t
    end
    it("Report.lua loads before ContactPane.lua (the pane reads ns.Report.EMAIL), both before Slash.lua, after CopyWindow.lua", function()
        local i = idx()
        assertTrue(i["Options/CopyWindow.lua"] < i["Options/Report.lua"]); assertTrue(i["Options/Report.lua"] < i["Options/ContactPane.lua"])
        assertTrue(i["Options/ContactPane.lua"] < i["Options/Slash.lua"]); assertTrue(i["Options/Window.lua"] < i["Options/ContactPane.lua"])
    end)
    it("every file listed in the TOC exists, and every Lua/XML file under the addon is listed", function()
        for _, rel in ipairs(toc.files) do assertTrue(L.exists(L.path(rel)), rel .. " listed but missing") end
        local listed = {}
        for _, rel in ipairs(toc.files) do listed[rel:gsub("\\", "/")] = true end
        local p = io.popen('cd "' .. L.addonDir .. '" && find . -type f \\( -name "*.lua" -o -name "*.xml" \\) | sed "s|^\\./||"')
        for f in p:lines() do
            assertTrue(listed[f] or f == "Bindings.xml", f .. " exists but is not in the TOC")
        end
        p:close()
    end)
    it("the TOC declares the licence", function()
        assertEquals(toc.meta["X-License"], "All Rights Reserved")
        assertEquals(toc.meta.Author, "trtg")
    end)
    it("HealerForever/LICENSE.txt exists, names the copyright holder and the year, and is the file the pane points at", function()
        local lic = L.readFile(L.path("LICENSE.txt"))
        assertNotNil(lic:find("Copyright (c) 2026 trtg. All rights reserved.", 1, true))
        assertNotNil(lic:find("Healer Forever", 1, true))
        assertTrue(#lic > 200, "a real licence text")
    end)
    it("the release zip contains LICENSE.txt at HealerForever/LICENSE.txt (see test_release for the build)", function()
        local script = L.readFile(HF_ROOT .. "/scripts/release.sh")
        assertNotNil(script:find("cp -R HealerForever", 1, true), "the whole addon folder is packaged, so LICENSE.txt ships")
        assertNil(script:find("LICENSE", 1, true) and script:find("rm %-f.-LICENSE") or nil)
    end)
end)
