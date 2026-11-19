-- Raid layout switching details (Frames/RaidFrames.lua + UF:SetSuspended): the "soft" suspend in Auto inside a raid
-- (party buttons keep their unit watch under a party anchor hidden by the secure driver "[group:raid] hide; show", the
-- raid anchor on "[group:raid] show; hide", so the party bars come back at once when the raid ends mid-combat), soft
-- drivers only in that case, unregistered on the switch to party, never touched in combat, the quiet queue when leaving
-- in combat, Always raid -> Auto re-registering the party unit watch; coalescing (RF:RequestEvaluate 0.1 s, 0.3 s in
-- combat; immediate outside a raid; no re-style while RF.StyleKey is unchanged; in combat only changed GUIDs through
-- RF:UpdateChanged); RF:SyncGuid dropping buff data; the "Offline" tooltip line (party + raid); /hf raid <mode> applying
-- at once. The game running the visibility drivers is simulated by mock.applyStateDrivers (via H.roster / leaveCombat).
local mock = require("wow_mock")
local H = require("raid_helpers")
local L = require("loader")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local st, errstr = H.st, H.errstr

local function clean(label)
    assertEquals(#mock.errors, 0, (label or "") .. " errors:\n" .. errstr())
    assertEquals(H.violations(), "", (label or "") .. " protected calls in combat")
end

-- counts calls of RF / RS methods (patched on the module tables, which the addon looks up at call time)
local function counter(tbl, name)
    local orig = tbl[name]
    local c = { n = 0, args = {} }
    tbl[name] = function(...)
        c.n = c.n + 1
        c.args[#c.args + 1] = { ... }
        return orig(...)
    end
    c.restore = function() tbl[name] = orig end
    return c
end

-- every (Un)RegisterStateDriver call on the two anchors, with the combat flag
local function watchDrivers(ns)
    local log = {}
    for _, g in ipairs({ "RegisterStateDriver", "UnregisterStateDriver" }) do
        local orig = _G[g]
        mock.setGlobal(g, function(frame, name, ...)
            if frame == ns.UnitFrames.anchor or frame == ns.RaidFrames.anchor then
                log[#log + 1] = { fn = g, frame = frame == ns.UnitFrames.anchor and "party" or "raid", name = name, combat = mock.state.combat }
            end
            return orig(frame, name, ...)
        end)
    end
    return log
end

local function layoutLines()
    local out = {}
    for _, p in ipairs(mock.printed) do if p:find("layout: switching after combat", 1, true) then out[#out + 1] = p end end
    return out
end

describe("raid switching: soft drivers (Auto inside a raid)", function()
    it("Auto in a raid: party buttons stay watched under the driver-hidden party anchor; raid anchor on its own driver", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF, UF = ns.RaidFrames, ns.UnitFrames
        clean("boot")
        assertEquals(RF.active, "raid")
        assertTrue(RF.softDriver, "RF.softDriver set")
        assertTrue(UF.softSuspended, "UF.softSuspended set")
        assertEquals(H.driver(UF.anchor), H.PARTY_SOFT_DRIVER)
        assertEquals(H.driver(RF.anchor), H.RAID_SOFT_DRIVER)
        for _, b in ipairs(UF.buttons) do
            if not b.isPet then assertTrue(st(b).unitWatch == true, st(b).name .. " keeps its unit watch") end
        end
        assertEquals(#H.visiblePartyButtons(ns), 0)
        assertTrue(mock.isVisible(RF.buttons[1]), "raid bars visible")
        clean()
    end)

    it("no soft driver in party mode, Always raid, or Always party in a 25-man raid", function()
        local cases = {
            { label = "party mode (solo party)", opts = { group = 4 } },
            { label = "Always raid", opts = { group = 4, raid = 10, afterLoad = function(n) n.db.raid.layoutMode = "raid" end } },
            { label = "Always raid solo", opts = { group = 4, afterLoad = function(n) n.db.raid.layoutMode = "raid" end } },
            { label = "Always party, 25-man", opts = { group = 4, raid = 25, afterLoad = function(n) n.db.raid.layoutMode = "party" end } },
            { label = "Auto, 5-man raid in one group", opts = { group = 4, raid = 5, raidOpts = { party = true } } },
        }
        for _, case in ipairs(cases) do
            local ns = H.boot(case.opts)
            local RF, UF = ns.RaidFrames, ns.UnitFrames
            assertNil(H.driver(UF.anchor), case.label .. ": party anchor driver")
            assertNil(H.driver(RF.anchor), case.label .. ": raid anchor driver")
            assertFalse(RF.softDriver and true or false, case.label)
            assertFalse(UF.softSuspended and true or false, case.label)
            clean(case.label)
        end
        -- Always raid: the party buttons are hard-suspended (no unit watch at all)
        local ns = H.boot({ group = 4, raid = 10, afterLoad = function(n) n.db.raid.layoutMode = "raid" end })
        for _, b in ipairs(ns.UnitFrames.buttons) do assertFalse(st(b).unitWatch == true, "Always raid: " .. st(b).name .. " unwatched") end
        assertEquals(#H.visiblePartyButtons(ns), 0)
    end)

    it("switching to party (raid ends out of combat) unregisters both drivers and shows the party frames", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF, UF = ns.RaidFrames, ns.UnitFrames
        local log = watchDrivers(ns)
        H.roster(0)
        assertEquals(RF.active, "party")
        assertNil(H.driver(UF.anchor)); assertNil(H.driver(RF.anchor))
        assertNil(RF.softDriver); assertNil(UF.softSuspended)
        local unreg = {}
        for _, e in ipairs(log) do if e.fn == "UnregisterStateDriver" then unreg[e.frame] = true end end
        assertTrue(unreg.party and unreg.raid, "both anchors' drivers unregistered")
        assertTrue(st(UF.anchor).shown); assertFalse(st(RF.anchor).shown)
        assertEquals(#H.visiblePartyButtons(ns), 5)
        -- Always party while in the raid also drops them
        local ns2 = H.boot({ group = 4, raid = 10 })
        ns2.db.raid.layoutMode = "party"; ns2:Changed("raid"); mock.flushTimers(); mock.applyUnitWatch()
        assertEquals(ns2.RaidFrames.active, "party")
        assertNil(H.driver(ns2.UnitFrames.anchor)); assertNil(H.driver(ns2.RaidFrames.anchor))
        assertEquals(#H.visiblePartyButtons(ns2), 5)
        clean()
    end)

    it("the raid ends MID-COMBAT: the game's drivers show the party bars at once; no driver call, no chat line, switch after combat", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF, UF = ns.RaidFrames, ns.UnitFrames
        local log = watchDrivers(ns)
        H.enterCombat()
        mock.printed = {}
        mock.setRaid(0)
        mock.fire("GROUP_ROSTER_UPDATE")
        mock.advance(0.5)
        mock.applyUnitWatch()   -- the game runs the visibility drivers and unit watches (also in combat)
        clean("in combat")
        assertTrue(st(UF.anchor).shown, "party anchor shown by its driver")
        assertFalse(st(RF.anchor).shown, "raid anchor hidden by its driver")
        assertEquals(#H.visiblePartyButtons(ns), 5, "party bars visible in combat (they kept their unit watch)")
        -- and they are click-castable right away: their strict macros were never cleared while soft-suspended
        local macros = H.macrosOf(UF.byUnit.party1)
        assertTrue(#macros > 0, "party1 has its click-casting macros")
        for _, m in ipairs(macros) do assertDeepEquals(H.macroProblems(m.text, "party1"), {}, m.name) end
        assertEquals(#layoutLines(), 0, "quiet: no 'switching after combat' line: " .. table.concat(mock.printed, " | "))
        assertEquals(RF.active, "raid", "the addon switches only after combat")
        for _, e in ipairs(log) do assertFalse(e.combat, e.fn .. " on the " .. e.frame .. " anchor in combat") end
        H.leaveCombat()
        clean("after combat")
        assertEquals(RF.active, "party")
        assertNil(H.driver(UF.anchor)); assertNil(H.driver(RF.anchor))
        assertEquals(#H.visiblePartyButtons(ns), 5)
    end)

    it("joining a raid in Auto during combat: drivers are only registered after combat (one chat line)", function()
        local ns = H.boot({ group = 4 })
        local log = watchDrivers(ns)
        H.enterCombat()
        mock.printed = {}
        H.roster(10)
        mock.advance(0.5)
        clean("in combat")
        assertEquals(#layoutLines(), 1)
        assertEquals(#log, 0, "no driver calls in combat")
        H.leaveCombat()
        assertEquals(ns.RaidFrames.active, "raid")
        assertEquals(H.driver(ns.UnitFrames.anchor), H.PARTY_SOFT_DRIVER)
        for _, e in ipairs(log) do assertFalse(e.combat) end
        clean()
    end)

    it("Always raid -> Auto inside a raid: the party unit watches come back (hard -> soft), drivers registered", function()
        local ns = H.boot({ group = 4, raid = 10, afterLoad = function(n) n.db.raid.layoutMode = "raid" end })
        local UF = ns.UnitFrames
        for _, b in ipairs(UF.buttons) do assertFalse(st(b).unitWatch == true) end
        ns.db.raid.layoutMode = "auto"; ns:Changed("raid"); mock.flushTimers(); mock.applyUnitWatch()
        assertEquals(ns.RaidFrames.active, "raid")
        for _, b in ipairs(UF.buttons) do
            if not b.isPet then assertTrue(st(b).unitWatch == true, st(b).name .. " watched again") end
        end
        assertEquals(H.driver(UF.anchor), H.PARTY_SOFT_DRIVER)
        assertEquals(H.driver(ns.RaidFrames.anchor), H.RAID_SOFT_DRIVER)
        assertEquals(#H.visiblePartyButtons(ns), 0, "still hidden while in the raid")
        -- and back: Auto -> Always raid hard-suspends again and drops the drivers
        ns.db.raid.layoutMode = "raid"; ns:Changed("raid"); mock.flushTimers(); mock.applyUnitWatch()
        assertNil(H.driver(UF.anchor)); assertNil(H.driver(ns.RaidFrames.anchor))
        for _, b in ipairs(UF.buttons) do assertFalse(st(b).unitWatch == true) end
        assertTrue(st(ns.RaidFrames.anchor).shown, "Always raid: the addon shows the raid anchor itself")
        clean()
    end)
end)

describe("raid switching: coalescing", function()
    it("a burst of roster events in a raid -> ONE Evaluate 0.1 s after the first request", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF = ns.RaidFrames
        assertEquals(RF.EVAL_DELAY, 0.1); assertEquals(RF.EVAL_DELAY_COMBAT, 0.3)
        local ev = counter(RF, "Evaluate")
        for _ = 1, 12 do mock.fire("GROUP_ROSTER_UPDATE") end
        assertEquals(ev.n, 0, "nothing runs at once inside a raid")
        mock.advance(0.05)
        assertEquals(ev.n, 0)
        mock.advance(0.1)
        assertEquals(ev.n, 1, "one Evaluate for the burst")
        mock.advance(1)
        assertEquals(ev.n, 1)
        ev.restore()
        clean()
    end)

    it("in combat the delay is 0.3 s, still one Evaluate", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF = ns.RaidFrames
        H.enterCombat()
        local ev = counter(RF, "Evaluate")
        for _ = 1, 8 do mock.fire("GROUP_ROSTER_UPDATE") end
        mock.advance(0.2)
        assertEquals(ev.n, 0, "not yet at 0.2 s")
        mock.advance(0.15)
        assertEquals(ev.n, 1)
        ev.restore()
        H.leaveCombat()
        clean()
    end)

    it("not in a raid and on the party layout: Evaluate runs at once (no timer)", function()
        local ns = H.boot({ group = 4 })
        local ev = counter(ns.RaidFrames, "Evaluate")
        mock.fire("GROUP_ROSTER_UPDATE")
        assertEquals(ev.n, 1, "immediate")
        ns.db.raid.width = 80; ns:Changed("raid")
        assertEquals(ev.n, 2, "a raid option outside a raid: immediate too")
        ev.restore()
        clean()
    end)

    it("a slider burst (20 raid option changes) -> ONE Layout; the bars are re-styled once", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF, RS = ns.RaidFrames, ns.RaidStyle
        local lay, apply = counter(RF, "Layout"), counter(RS, "Apply")
        for w = 61, 80 do ns.db.raid.width = w; ns:Changed("raid") end
        assertEquals(lay.n, 0)
        mock.advance(0.2)
        assertEquals(lay.n, 1, "one Layout for the burst")
        assertEquals(apply.n, 40, "every bar re-styled once")
        assertEquals(st(RF.buttons[1]).w, 80)
        lay.restore(); apply.restore()
        clean()
    end)

    it("no re-style when RF.StyleKey is unchanged (roster change, moving the frame); any raid setting changes the key", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF, RS = ns.RaidFrames, ns.RaidStyle
        local k0 = RF.StyleKey(ns.db.raid)
        local apply = counter(RS, "Apply")
        H.roster(12); mock.advance(0.2)
        assertEquals(apply.n, 0, "a roster change does not re-style")
        ns.db.raid.point = { point = "CENTER", relativePoint = "CENTER", x = 5, y = 5 }; ns:Changed("raid"); mock.advance(0.2)
        assertEquals(apply.n, 0, "moving the frame does not re-style")
        assertEquals(RF.StyleKey(ns.db.raid), k0, "the point is not part of the key")
        ns.db.raid.buffs.size = 12
        assertTrue(RF.StyleKey(ns.db.raid) ~= k0, "a nested option changes the key")
        ns.db.raid.buffs.size = 10
        assertEquals(RF.StyleKey(ns.db.raid), k0)
        RF.glowSupported = false
        assertTrue(RF.StyleKey(ns.db.raid) ~= k0, "the debuff display in use is part of the key")
        RF.glowSupported = true
        ns.db.raid.nameSize = 8; ns:Changed("raid"); mock.advance(0.2)
        assertEquals(apply.n, 40)
        apply.restore()
        clean()
    end)

    it("in combat a roster change refreshes only the bars whose player changed (RF:UpdateChanged), nothing protected", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF = ns.RaidFrames
        H.enterCombat()
        local all = counter(RF, "UpdateAll")
        mock.state.guids = { raid3 = "Player-1-somebody-new" }
        mock.fire("GROUP_ROSTER_UPDATE")
        mock.advance(0.4)
        clean("in combat")
        assertEquals(all.n, 1, "only the changed bar")
        assertTrue(all.args[1][2] == RF.buttons[3])
        all.restore()
        H.leaveCombat()
        clean()
    end)
end)

describe("raid switching: a new player behind a token", function()
    it("RF:SyncGuid drops the old member's buff data (markers, missing count, smart-buff list) and marks it dirty", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF = ns.RaidFrames
        local b = RF.buttons[3]
        assertFalse(RF:SyncGuid(b), "same player: nothing changes")
        b.buffMarkerData = { { kind = "miss", key = "kings", count = 1 } }
        b.buffPending = { { unit = "raid3", key = "kings" } }
        b.buffMissing = 2
        b.buffReport = { { key = "kings", missing = true } }
        RF.buffDirty[b] = nil
        assertFalse(RF:SyncGuid(b))
        assertEquals(b.buffMissing, 2, "kept for the same player")
        mock.state.guids = { raid3 = "Player-1-somebody-else" }
        assertTrue(RF:SyncGuid(b))
        assertNil(b.buffMarkerData); assertNil(b.buffPending); assertNil(b.buffMissing); assertNil(b.buffReport)
        assertTrue(RF.buffDirty[b], "re-checked on the next tick")
        assertEquals(b.guid, "Player-1-somebody-else")
        -- an unreadable GUID counts as a different player
        mock.state.secretAll = true
        b.buffMissing = 1
        assertTrue(RF:SyncGuid(b))
        assertNil(b.buffMissing)
        mock.state.secretAll = false
        clean()
    end)
end)

describe("raid switching: tooltip and slash", function()
    local function capture()
        local lines = {}
        local gt = _G.GameTooltip
        gt.SetOwner = function() lines = {} end
        gt.AddLine = function(_, t) lines[#lines + 1] = tostring(t) end
        gt.AddDoubleLine = function(_, a, b) lines[#lines + 1] = tostring(a) .. " " .. tostring(b) end
        return function() return table.concat(lines, "\n") end
    end

    it("'Offline' tooltip line on an offline party bar and an offline raid bar (no range line)", function()
        local ns = H.boot({ group = 4 })
        local text = capture()
        mock.state.offline.party2 = true
        mock.fire("UNIT_CONNECTION", "party2"); mock.runOnUpdate(2, 0.3)
        ns.UnitFrames:ShowTooltip(ns.UnitFrames.byUnit.party2)
        assertTrue(text():find("\nOffline", 1, true) ~= nil, text())
        assertNil(text():find("In range", 1, true), "no range line for an offline member")
        local ns2 = H.boot({ group = 4, raid = 10 })
        text = capture()
        mock.state.offline.raid4 = true
        mock.fire("UNIT_CONNECTION", "raid4")
        assertEquals(ns2.RaidFrames.buttons[4].state, "offline")
        ns2.UnitFrames:ShowTooltip(ns2.RaidFrames.buttons[4])
        assertTrue(text():find("\nOffline", 1, true) ~= nil, text())
        assertNil(text():find("range", 1, true))
        -- online again: no Offline line
        mock.state.offline.raid4 = nil
        mock.fire("UNIT_CONNECTION", "raid4")
        ns2.UnitFrames:ShowTooltip(ns2.RaidFrames.buttons[4])
        assertNil(text():find("Offline", 1, true))
        clean()
    end)

    it("/hf raid <mode> applies at once (no coalescing delay) and prints the current status", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF = ns.RaidFrames
        mock.printed = {}
        assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "raid party"))
        assertEquals(RF.active, "party", "switched before any timer ran")
        local out = table.concat(mock.printed, "\n")
        assertTrue(out:find("Layout switching: Always party.", 1, true) ~= nil, out)
        assertTrue(out:find("Layout: party", 1, true) ~= nil, "status is current: " .. out)
        mock.printed = {}
        assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "raid auto"))
        assertEquals(RF.active, "raid")
        assertTrue(table.concat(mock.printed, "\n"):find("Layout: raid", 1, true) ~= nil)
        mock.flushTimers()
        clean()
    end)
end)
