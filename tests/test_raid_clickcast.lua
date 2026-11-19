-- Click-casting on the raid buttons (ClickCast.lua: ApplyToButtons / ApplyRaidNow / ApplyRaid): strict @raidN macros
-- (<= 255 characters, no bare clause, never another unit), the hfdead state driver with the raid token, the Cmd swap
-- entries, @player only on the player's own button ("Always raid" solo), disarming when the party layout is active,
-- and no restricted closure ever called from inside the addon's xpcall.
local mock = require("wow_mock")
local H = require("raid_helpers")
local L = require("loader")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local st, errstr = H.st, H.errstr

local function clean(label)
    assertEquals(#mock.errors, 0, (label or "") .. " errors:\n" .. errstr())
    assertEquals(H.violations(), "", (label or "") .. " protected calls in combat")
end

local function assertStrict(btn, token, label)
    local macros, bad = H.macrosOf(btn)
    assertEquals(#bad, 0, label .. ": " .. table.concat(bad, ", "))
    for _, m in ipairs(macros) do
        local p = H.macroProblems(m.text, token)
        assertEquals(#p, 0, label .. " [" .. m.name .. "] " .. tostring(m.text) .. "\n" .. table.concat(p, "\n"))
    end
    return #macros
end

describe("raid click-casting: strict macros", function()
    it("every raid button's macros name only its own @raidN, are <= 255 chars and have no bare clause", function()
        local ns = H.boot({ group = 4, raid = 40 })
        clean()
        for i, b in ipairs(ns.RaidFrames.buttons) do
            local n = assertStrict(b, "raid" .. i, "raid" .. i)
            assertTrue(n >= 10, "raid" .. i .. " has the example bindings (" .. n .. " macros)")
            assertEquals(st(b).attrs["type1"], "macro")
        end
    end)
    it("the raid button gets the same bindings as the party button (same slots, token swapped)", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local party = ns.UnitFrames.byUnit.player
        local raid = ns.RaidFrames.buttons[2]
        local pm = {}
        for k, v in pairs(st(party).attrs) do if tostring(k):find("macrotext", 1, true) then pm[k] = v end end
        local n = 0
        for k, v in pairs(pm) do
            n = n + 1
            assertEquals(st(raid).attrs[k], (v:gsub("@player", "@raid2")), k)
        end
        assertTrue(n >= 10)
        clean()
    end)
    it("Cmd bindings: hfmeta state driver and swap entries carry the raid token", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local b = ns.RaidFrames.buttons[7]
        assertEquals((st(b).stateDrivers or {}).hfmeta, "[mod:meta] meta; none")
        local mn = st(b).attrs["hf-mn"]
        assertTrue(type(mn) == "number" and mn >= 1, "Cmd swap entries")
        for i = 1, mn do
            local text = st(b).attrs["hf-mtext" .. i]
            assertTrue(text:find("@raid7", 1, true) ~= nil, text)
            assertEquals(#H.macroProblems(text, "raid7"), 0)
        end
        assertTrue((st(b).attrs["hf-nbinds"] or 0) >= 1, "override slots for Cmd / extra buttons")
        assertNotNil(st(b).attrs._onenter, "hover snippet")
        assertNotNil(st(b).attrs["_onstate-hfmeta"])
        clean()
    end)
    it("menu on plain Right with a res spell: hfdead state driver watches the raid token", function()
        local ns = H.boot({ group = 4, raid = 10, seed = false })
        local b = ns.RaidFrames.buttons[4]
        assertEquals((st(b).stateDrivers or {}).hfdead, "[@raid4,dead] dead; alive")
        local dtext = st(b).attrs["hf-dtext1"]
        assertNotNil(dtext)
        assertEquals(#H.macroProblems(dtext, "raid4"), 0, dtext)
        clean()
    end)
    it("Always raid solo / in a party: button 1 casts @player, buttons 2-5 @party1..4", function()
        local ns = H.boot({ group = 4, afterLoad = function(n) n.db.raid.layoutMode = "raid" end })
        local RF = ns.RaidFrames
        assertStrict(RF.buttons[1], "player", "button 1")
        assertTrue(st(RF.buttons[1]).attrs.macrotext1:find("@player", 1, true) ~= nil)
        for i = 2, 5 do assertStrict(RF.buttons[i], "party" .. (i - 1), "button " .. i) end
        -- joining a raid out of combat: tokens change and the macros are re-applied with raid tokens
        H.roster(10)
        for i = 1, 10 do assertStrict(RF.buttons[i], "raid" .. i, "after join " .. i) end
        clean()
    end)
    it("a token change during combat waits: macros keep the old (still correct) tokens until combat ends", function()
        local ns = H.boot({ group = 4, afterLoad = function(n) n.db.raid.layoutMode = "raid" end })
        local RF = ns.RaidFrames
        H.enterCombat()
        H.roster(10)
        clean("in combat")
        assertEquals(st(RF.buttons[2]).attrs.unit, "party1")
        assertStrict(RF.buttons[2], "party1", "in combat")
        H.leaveCombat()
        assertStrict(RF.buttons[2], "raid2", "after combat")
        clean()
    end)
    it("a binding change while the raid layout is active re-applies to the raid buttons", function()
        local ns = H.boot({ group = 4, raid = 10 })
        ns.db.bindings["|1"] = { type = "spell", spell = "Holy Shock" }
        ns:Changed("bindings"); mock.flushTimers()
        assertEquals(st(ns.RaidFrames.buttons[3]).attrs.macrotext1, "/cast [@raid3,dead] Redemption; [@raid3,help,nodead] Holy Shock")
        clean()
    end)
end)

describe("raid click-casting: disarmed in party mode", function()
    it("switching to party clears the click attributes, override bindings and state drivers of every raid button", function()
        local ns = H.boot({ group = 4, raid = 10, seed = false })
        local RF = ns.RaidFrames
        local b = RF.buttons[4]
        assertTrue(#H.clickAttrs(b) > 0); assertNotNil((st(b).stateDrivers or {}).hfdead)
        mock.calls = {}
        H.roster(0)
        clean()
        assertEquals(RF.active, "party")
        for i, btn in ipairs(RF.buttons) do
            assertDeepEquals(H.clickAttrs(btn), {}, "raid" .. i .. " still armed")
            assertNil(next(st(btn).stateDrivers or {}), "raid" .. i .. " keeps a state driver")
            assertNil(st(btn).attrs["state-hfmeta"]); assertNil(st(btn).attrs["state-hfdead"])
            local cleared = mock.callsTo("ClearOverrideBindings", function(c) return c.args[1] == btn end)
            assertTrue(#cleared >= 1, "override bindings of raid" .. i .. " cleared")
        end
    end)
    it("Always party in a raid: the raid buttons are never armed (no attributes, no drivers)", function()
        local ns = H.boot({ group = 4, raid = 25, afterLoad = function(n) n.db.raid.layoutMode = "party" end })
        for _, btn in ipairs(ns.RaidFrames.buttons) do
            assertDeepEquals(H.clickAttrs(btn), {})
            assertNil(next(st(btn).stateDrivers or {}))
        end
        ns:Changed("bindings"); mock.flushTimers()
        for _, btn in ipairs(ns.RaidFrames.buttons) do assertDeepEquals(H.clickAttrs(btn), {}, "a binding change does not arm idle raid buttons") end
        clean()
    end)
    it("switching to party in combat: nothing is cleared in combat, everything after", function()
        local ns = H.boot({ group = 4, raid = 10 })
        H.enterCombat()
        H.slash("raid party")
        clean("in combat")
        assertTrue(#H.clickAttrs(ns.RaidFrames.buttons[1]) > 0, "still armed in combat")
        H.leaveCombat()
        assertDeepEquals(H.clickAttrs(ns.RaidFrames.buttons[1]), {})
        clean()
    end)
end)

describe("raid click-casting: restricted closures", function()
    it("each raid button's OnHide is the unwrapped restricted closure, installed once, safe at top level", function()
        local ns = H.boot({ group = 4, raid = 10 })
        H.roster(0); H.roster(10)   -- re-armed: still one wrap
        for i, b in ipairs(ns.RaidFrames.buttons) do
            local fn = st(b).scripts.OnHide
            assertTrue(mock.restricted[fn] == true, "raid" .. i .. ": OnHide must be the restricted closure itself")
            local wraps = 0
            for _, c in ipairs(mock.calls) do if c.method == "SecureHandlerWrapScript" and c.args[1] == b then wraps = wraps + 1 end end
            assertEquals(wraps, 1, "raid" .. i .. " wrapped once")
        end
        -- the game runs OnHide natively (unit watch hides the button): no "Cannot call restricted closure" error
        H.roster(3)
        clean()
    end)
    it("no restricted closure runs inside the addon's xpcall during a full join / leave / combat cycle", function()
        local ns = H.boot({ group = 4 })
        local n0 = #ns.db.errorLog
        H.roster(12); H.enterCombat(); H.roster(14); H.leaveCombat(); H.roster(0); H.roster(8)
        mock.runOnUpdate(5, 0.2)
        clean()
        for _, e in ipairs(ns.db.errorLog) do
            assertNil(tostring(e.msg or e.message or e[1]):find("restricted closure", 1, true), "restricted closure error logged")
        end
        assertEquals(#ns.db.errorLog, n0, "no error logged")
    end)
end)
