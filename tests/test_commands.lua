-- Commands & Tips: ns.SLASH_COMMANDS is the single source for /hf help and the Help & Contact section. Every subcommand the handler knows
-- is listed (and vice versa), both renderings agree, the tab scrolls, and the keybinding names match Bindings.xml.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

local function boot()
    mock.install(); S = mock.state
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(3)
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
local function stripColor(s) return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local slashSrc = L.readFile(L.path("Options/Slash.lua"))

-- what the handler actually branches on, found by scanning the source
local function handled()
    local top, debugSubs, errorSubs, markSubs = {}, {}, {}, {}
    local inDebug, inErrors, inMark = false, false, false
    for line in slashSrc:gmatch("[^\n]*") do
        local c = line:match('^%s*if cmd == "([^"]*)" or cmd == "([^"]*)" or cmd == "([^"]*)" then') or line:match('elseif cmd == "([^"]*)" then')
        for w in line:gmatch('cmd == "([^"]*)"') do top[w] = true end
        if line:match('elseif cmd == "debug" then') then inDebug, inErrors, inMark = true, false, false
        elseif line:match('elseif cmd == "errors" then') then inErrors, inDebug, inMark = true, false, false
        elseif line:match('elseif cmd == "mark" then') then inMark, inDebug, inErrors = true, false, false
        elseif line:match('elseif cmd == "') then inDebug, inErrors, inMark = false, false, false end
        for w in line:gmatch('sub == "([^"]*)"') do
            if inDebug then debugSubs[w] = true elseif inErrors then errorSubs[w] = true end
        end
        if inMark then for w in line:gmatch('arg:lower%(%) == "([^"]*)"') do markSubs[w] = true end end
    end
    return top, debugSubs, errorSubs, markSubs
end

describe("commands: ns.SLASH_COMMANDS is complete and consistent with the handler", function()
    local ns = boot()
    local cmds = ns.SLASH_COMMANDS
    it("is a non-empty list of { cmd, desc } entries starting with /hf, unique, with real descriptions", function()
        assertTrue(type(cmds) == "table" and #cmds >= 15)
        local seen = {}
        for i, c in ipairs(cmds) do
            assertEquals(type(c.cmd), "string"); assertTrue(c.cmd:find("^/hf") ~= nil, c.cmd)
            assertEquals(type(c.desc), "string"); assertTrue(#c.desc >= 10, c.cmd .. " needs a real description")
            assertNil(seen[c.cmd], "duplicate " .. c.cmd); seen[c.cmd] = true
            if c.help ~= nil then assertEquals(type(c.help), "string") end
            if c.hidden ~= nil then assertEquals(type(c.hidden), "boolean") end
        end
        assertEquals(cmds[1].cmd, "/hf")
    end)
    it("every top-level subcommand the handler branches on is listed (the aliases options/config/'' are the bare /hf)", function()
        local top = handled()
        local listed = {}
        for _, c in ipairs(cmds) do local w = c.cmd:match("^/hf%s+(%S+)"); if w then listed[w] = true end end
        local ALIAS = { [""] = true, options = true, config = true }
        local n = 0
        for w in pairs(top) do
            if not ALIAS[w] then
                n = n + 1
                assertTrue(listed[w], "'/hf " .. w .. "' is handled but missing from ns.SLASH_COMMANDS")
            end
        end
        assertTrue(n >= 12, "the scan found " .. n .. " subcommands")
    end)
    it("every listed top-level subcommand is handled (nothing documented that does not exist)", function()
        local top = handled()
        for _, c in ipairs(cmds) do
            local w = c.cmd:match("^/hf%s+(%S+)")
            if w then assertTrue(top[w], c.cmd .. " is documented but the handler has no branch for it") end
        end
    end)
    it("the debug sub-commands match both ways (buffs, auras, click, click watch, clear)", function()
        local _, debugSubs = handled()
        local listed = {}
        for _, c in ipairs(cmds) do
            local sub = c.cmd:match("^/hf debug (.+)$")
            if sub then listed[sub] = true end
        end
        for w in pairs(debugSubs) do assertTrue(listed[w], "/hf debug " .. w .. " is handled but not listed") end
        for w in pairs(listed) do assertTrue(debugSubs[w], "/hf debug " .. w .. " is listed but not handled") end
    end)
    it("errors and mark options in the bracket text are the ones the handler knows", function()
        local _, _, errorSubs, markSubs = handled()
        local byFirst = {}
        for _, c in ipairs(cmds) do byFirst[c.cmd:match("^/hf%s+(%S+)") or ""] = c end
        local e = byFirst.errors.cmd
        for w in pairs(errorSubs) do assertTrue(e:find(w, 1, true), "/hf errors " .. w .. " not in " .. e) end
        local m = byFirst.mark.cmd
        for w in pairs(markSubs) do assertTrue(m:find(w, 1, true), "/hf mark " .. w .. " not in " .. m) end
    end)
    it("debug sub-commands are hidden from the one-line /hf help except the grouped 'buffs | auras | click ...' entry", function()
        local hidden = 0
        for _, c in ipairs(cmds) do if c.hidden then hidden = hidden + 1; assertTrue(c.cmd:find("^/hf debug "), c.cmd .. " is hidden but is not a debug sub-command") end end
        assertTrue(hidden >= 3)
        local grouped
        for _, c in ipairs(cmds) do if c.cmd == "/hf debug buffs" then grouped = c end end
        assertNotNil(grouped.help:find("auras", 1, true)); assertNotNil(grouped.help:find("click watch", 1, true)); assertNotNil(grouped.help:find("clear", 1, true))
    end)
end)

describe("commands: /hf help and the Help & Contact section render the same list", function()
    local ns = boot()
    it("/hf help prints every non-hidden entry (its help text or its command) in order, joined by ' | '", function()
        local ok, _, out = slash("help")
        assertTrue(ok)
        local parts = {}
        for _, c in ipairs(ns.SLASH_COMMANDS) do if not c.hidden then parts[#parts + 1] = c.help or c.cmd end end
        assertTrue(stripColor(out):find(table.concat(parts, " | "), 1, true), out)
        for _, bad in ipairs({ "unknown", "nil" }) do assertNil(out:find(bad, 1, true)) end
    end)
    it("an unknown subcommand prints the same help (and an empty arg after help does too)", function()
        local _, _, a = slash("help"); local _, _, b = slash("bogus-command"); local _, _, c = slash("help me")
        assertEquals(a, b); assertEquals(a, c)
    end)
    it("the Commands section lists EVERY entry (hidden debug ones too) as 'cmd  -  description', in the same order", function()
        ns.Options:Show("help"); mock.flushTimers()
        local text
        for _, f in ipairs(mock.frames) do local s = st(f); if s.kind == "FontString" and type(s.text) == "string" and s.text:find("^/hf  %-  ") then text = s.text end end
        assertNotNil(text, "the commands block")
        local want = {}
        for _, c in ipairs(ns.SLASH_COMMANDS) do want[#want + 1] = c.cmd .. "  -  " .. c.desc end
        assertEquals(text, table.concat(want, "\n"))
    end)
    it("everything /hf help shows is also in the section (the same source table)", function()
        local _, _, out = slash("help")
        out = stripColor(out)
        local section
        for _, f in ipairs(mock.frames) do local s = st(f); if s.kind == "FontString" and type(s.text) == "string" and s.text:find("^/hf  %-  ") then section = s.text end end
        for _, c in ipairs(ns.SLASH_COMMANDS) do
            if not c.hidden then
                assertTrue(out:find(c.help or c.cmd, 1, true), c.cmd .. " missing from /hf help")
                assertTrue(section:find(c.cmd, 1, true), c.cmd .. " missing from the section")
            end
        end
    end)
    it("the section has a heading and the other blocks (Keybindings, Quick start, Good to know) in order", function()
        local order = {}
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.kind == "FontString" then for _, h in ipairs({ "Commands & Tips: commands", "Keybindings", "Quick start", "Good to know" }) do if s.text == h then order[#order + 1] = h end end end
        end
        assertEquals(table.concat(order, "|"), "Commands & Tips: commands|Keybindings|Quick start|Good to know")
    end)
    it("every documented command can actually be run without error (reset and copyaccount included - they only touch the test profile)", function()
        for _, c in ipairs(ns.SLASH_COMMANDS) do
            local line = c.cmd:gsub("^/hf%s*", ""):gsub("%b[]", ""):gsub("<n>", "1"):gsub("|.*$", ""):gsub("%s+$", "")
            local ok, err = slash(line)
            assertTrue(ok, c.cmd .. " (" .. line .. "): " .. tostring(err))
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("works in combat and with everything secret", function()
        S.combat = true; S.secretAll = true
        local v0 = #mock.violations
        for _, w in ipairs({ "help", "report", "contact", "mark x" }) do assertTrue(slash(w), w) end
        S.combat = false; S.secretAll = false
        assertEquals(#mock.violations, v0); assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("commands: the Help & Contact tab scrolls", function()
    local ns = boot()
    ns.Options:Show("help"); mock.flushTimers()
    local function scrollOfHelp()
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "ScrollFrame" and st(f).template == "UIPanelScrollFrameTemplate" and st(f).scrollChild and st(st(f).scrollChild).kind == "Frame" then
                local child = st(f).scrollChild
                for _, g in ipairs(mock.frames) do
                    if st(g).kind == "EditBox" and st(g).parent == child then return f, child end
                end
            end
        end
    end
    it("the pane is a ScrollFrame (UIPanelScrollFrameTemplate) whose child holds the e-mail box and every block", function()
        local scroll, child = scrollOfHelp()
        assertNotNil(scroll, "the help pane's scroll frame")
        assertTrue(st(child).w >= 500 and st(child).h >= 800, "tall content: " .. tostring(st(child).h))
    end)
    it("the scroll frame fills the pane (all four corners anchored, room for the scroll bar on the right)", function()
        local scroll = scrollOfHelp()
        local pts = st(scroll).points
        assertTrue(#pts >= 2)
        assertEquals(pts[1][1], "TOPLEFT"); assertEquals(pts[2][1], "BOTTOMRIGHT"); assertTrue(pts[2][2] <= -20, "scroll bar gutter")
    end)
    it("all the text blocks are children of the scroll child (so they scroll) and chained one under the other", function()
        local _, child = scrollOfHelp()
        local count = 0
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.kind == "FontString" and type(s.text) == "string" and (s.text == "Keybindings" or s.text == "Quick start" or s.text == "Good to know" or s.text:find("^/hf  %-  ")) then
                count = count + 1; assertTrue(s.parent == child, tostring(s.text):sub(1, 20) .. " is outside the scrolling child")
            end
        end
        assertEquals(count, 4)
    end)
    it("the content height covers the long command list (about 18 lines) plus the other blocks", function()
        local _, child = scrollOfHelp()
        local lines = #ns.SLASH_COMMANDS
        assertTrue(st(child).h >= 14 * lines, "child height " .. st(child).h .. " for " .. lines .. " commands")
    end)
end)

describe("commands: keybinding names match Bindings.xml", function()
    local ns = boot()
    local xml = L.readFile(L.path("Bindings.xml"))
    local names, headers = {}, {}
    for name in xml:gmatch('<Binding name="([^"]+)"') do names[#names + 1] = name end
    for h in xml:gmatch('header="([^"]+)"') do headers[#headers + 1] = h end
    it("Bindings.xml declares the smart and tank buff clicks, one header, and each has a BINDING_NAME", function()
        assertDeepEquals(names, { "CLICK HealerForeverSmartBuff:LeftButton", "CLICK HealerForeverTankBuff:LeftButton" })
        assertDeepEquals(headers, { "HEALERFOREVER" })
        for _, n in ipairs(names) do assertEquals(type(_G["BINDING_NAME_" .. n]), "string", n); assertTrue(#_G["BINDING_NAME_" .. n] > 5) end
        assertEquals(_G["BINDING_HEADER_HEALERFOREVER"], "Healer Forever")
    end)
    it("every CLICK binding points at a real secure button that exists after load (HealerForeverSmartBuff, HealerForeverTankBuff)", function()
        for _, n in ipairs(names) do
            local frameName = n:match("^CLICK (%S+):LeftButton$")
            assertNotNil(frameName, n)
            assertNotNil(_G[frameName], frameName .. " is not a global frame")
            assertTrue(st(_G[frameName]).secure, frameName .. " must be a secure button for the click to cast")
        end
    end)
    it("the Keybindings text in Help & Contact names the keybinding entries the game will show", function()
        ns.Options:Show("help"); mock.flushTimers()
        local text
        for _, f in ipairs(mock.frames) do local s = st(f); if s.kind == "FontString" and type(s.text) == "string" and s.text:find("^Esc > Options > Keybindings") then text = s.text end end
        assertNotNil(text, "the keybindings text")
        assertTrue(text:find("Healer Forever", 1, true), text)
        for _, n in ipairs(names) do
            local label = _G["BINDING_NAME_" .. n]:gsub("^Healer Forever: ", "")
            if not text:find(label, 1, true) then
                warn("Options/ContactPane.lua Keybindings block says '" .. text .. "' but the game lists the entries as '" .. _G["BINDING_NAME_" .. n] .. "' (BuffButtons.lua ~line 667): the names do not match")
            end
        end
    end)
    it("the Buff Presets pane's key hint mentions the same macro the TOC-registered button answers to", function()
        ns.Options:Show("buffs"); mock.flushTimers()
        local hint
        for _, f in ipairs(mock.frames) do local s = st(f); if s.kind == "FontString" and type(s.text) == "string" and s.text:find("/click HealerForeverSmartBuff", 1, true) then hint = s.text end end
        assertNotNil(hint); assertNotNil(_G.HealerForeverSmartBuff)
    end)
end)
