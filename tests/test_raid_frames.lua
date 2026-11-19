-- Raid frames (Frames/RaidFrames.lua), Phase 1: creation, layout switching (auto / always party / always raid, battleground,
-- arena, in and out of combat), the cell layout (mid-combat joiners), secret roster fallback, alias event routing, the
-- slash commands and the report lines. Visual style (Phase 2: muting, deficit alpha, outlines) is NOT asserted here.
local mock = require("wow_mock")
local H = require("raid_helpers")
local L = require("loader")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local st, errstr = H.st, H.errstr

local function clean(label)
    assertEquals(#mock.errors, 0, (label or "") .. " errors:\n" .. errstr())
    assertEquals(H.violations(), "", (label or "") .. " protected calls in combat")
end

describe("raid frames: creation", function()
    it("an anchor and 40 secure unit buttons with fixed raid tokens, AnyUp only, all hidden while solo", function()
        local ns = H.boot({ group = 0 })
        clean("boot")
        local RF = ns.RaidFrames
        assertNotNil(RF.anchor); assertEquals(st(RF.anchor).name, "HealerForeverRaidFrame")
        assertEquals(#RF.buttons, 40)
        for i, b in ipairs(RF.buttons) do
            local s = st(b)
            assertEquals(s.name, "HealerForeverRaidUnit" .. i)
            assertTrue(s.template:find("SecureUnitButtonTemplate", 1, true) ~= nil)
            assertTrue(s.template:find("SecureHandlerEnterLeaveTemplate", 1, true) ~= nil)
            assertTrue(s.template:find("SecureHandlerStateTemplate", 1, true) ~= nil)
            assertEquals(s.attrs.unit, "raid" .. i)
            assertFalse(s.shown, "button " .. i .. " hidden")
            local clicks = mock.callsTo("RegisterForClicks", function(c) return c.obj == b end)
            assertEquals(#clicks, 1)
            assertDeepEquals(clicks[1].args, { "AnyUp" }, "AnyUp only (SecureUnitButton_OnClick has no up/down filter)")
            assertNil(rawget(b, "SetScript"), "SetScript is never overridden on a secure button")
            assertNil(rawget(b, "HookScript"), "HookScript is never overridden on a secure button")
        end
        assertFalse(st(RF.anchor).shown)
        assertEquals(RF.active, "party")
    end)
    it("creating the frames during combat (reload in combat) waits for combat to end, then switches", function()
        local ns = H.boot({ group = 4, afterLoad = function() mock.state.combat = true end, raid = 15 })
        clean("combat login")
        local RF = ns.RaidFrames
        assertNil(RF.anchor, "no raid frames created in combat")
        H.leaveCombat()
        clean("after combat")
        assertNotNil(RF.anchor)
        assertEquals(RF.active, "raid")
        assertEquals(#H.shownRaidButtons(ns), 15)
        assertFalse(st(ns.UnitFrames.anchor).shown, "the party frames (also created after combat) are suspended")
    end)
end)

describe("raid frames: party mode is idle", function()
    it("no unit watch, no click attributes, no state drivers, anchor hidden, no override bindings", function()
        local ns = H.boot({ group = 4 })
        clean()
        for _, b in ipairs(ns.RaidFrames.buttons) do
            assertFalse(st(b).unitWatch == true, st(b).name .. " watched")
            assertDeepEquals(H.clickAttrs(b), {}, st(b).name .. " has click attributes")
            assertNil(next(st(b).stateDrivers or {}), st(b).name .. " has a state driver")
            assertFalse(st(b).shown)
        end
        local overrides = mock.callsTo("SetOverrideBindingClick")
        for _, c in ipairs(overrides) do
            for _, b in ipairs(ns.RaidFrames.buttons) do assertTrue(c.args[1] ~= b, "override binding on a raid button") end
        end
        assertEquals(#H.shownPartyButtons(ns) >= 5 and 1 or 0, 1, "party frames shown")
        -- the OnUpdate of the hidden raid anchor never runs (mock.runScript skips hidden frames) and nothing raises
        mock.runOnUpdate(5, 0.25)
        clean("idle ticks")
    end)
end)

describe("raid frames: switching out of combat", function()
    it("joining a 10-man raid switches to the raid layout; leaving restores the party frames", function()
        local ns = H.boot({ group = 4 })
        local RF, UF = ns.RaidFrames, ns.UnitFrames
        H.roster(10)
        clean("join")
        assertEquals(RF.active, "raid")
        assertTrue(st(RF.anchor).shown)
        assertFalse(st(UF.anchor).shown, "party anchor hidden")
        -- Auto inside a raid = soft suspend: the party buttons keep their unit watch (so they can come back in combat), but
        -- nobody sees them: the party anchor is hidden by the secure driver, the raid anchor shown by its own driver
        assertEquals(#H.visiblePartyButtons(ns), 0, "no party bar visible")
        for _, b in ipairs(UF.buttons) do assertTrue(st(b).unitWatch == true, st(b).name .. " keeps its unit watch") end
        assertEquals(H.driver(UF.anchor), H.PARTY_SOFT_DRIVER)
        assertEquals(H.driver(RF.anchor), H.RAID_SOFT_DRIVER)
        assertEquals(#H.shownRaidButtons(ns), 10)
        for i, b in ipairs(RF.buttons) do assertTrue(st(b).unitWatch == true, "button " .. i .. " watched") end
        H.roster(0)
        clean("leave")
        assertEquals(RF.active, "party")
        assertNil(H.driver(UF.anchor), "party driver unregistered after the switch back")
        assertNil(H.driver(RF.anchor), "raid driver unregistered after the switch back")
        assertFalse(st(RF.anchor).shown)
        assertTrue(st(UF.anchor).shown)
        assertEquals(#H.visiblePartyButtons(ns), 5)
        assertEquals(#H.shownRaidButtons(ns), 0)
        assertEquals(#H.shownPartyButtons(ns), 5, "player + 4 party members back")
        for _, b in ipairs(RF.buttons) do assertFalse(st(b).unitWatch == true) end
    end)
    it("'raid layout only above 5': a 5-man raid in one subgroup keeps the party frames; split or 6 -> raid", function()
        local ns = H.boot({ group = 4 })
        local RF = ns.RaidFrames
        H.roster(5, { party = true })
        clean()
        assertEquals(RF.active, "party", RF.reason)
        H.roster(5, { party = true, subgroups = { 1, 1, 1, 2, 2 } })
        assertEquals(RF.active, "raid", "split over two subgroups")
        H.roster(5, { party = true })
        assertEquals(RF.active, "party")
        H.roster(6, { party = true })
        assertEquals(RF.active, "raid")
        ns.db.raid.onlyAbove5 = false
        H.roster(3, { party = true })
        assertEquals(RF.active, "raid", "option off: any raid")
        clean()
    end)
    it("battleground -> raid layout even in a 5-man group; arena -> party even in a raid", function()
        local ns = H.boot({ group = 4 })
        local RF = ns.RaidFrames
        mock.state.instanceType = "pvp"
        mock.fire("ZONE_CHANGED_NEW_AREA"); mock.flushTimers()
        assertEquals(RF.active, "raid", RF.reason)
        assertTrue(RF.reason:find("battleground", 1, true) ~= nil)
        mock.state.instanceType = "arena"
        H.roster(5, { subgroups = { 1, 2, 1, 2, 1 } })
        assertEquals(RF.active, "party", RF.reason)
        mock.state.instanceType = "none"
        mock.fire("ZONE_CHANGED_NEW_AREA"); mock.flushTimers()
        assertEquals(RF.active, "raid", "split 5-man raid outside the arena")
        clean()
    end)
    it("Always party never shows the raid frames, even in a 40-man raid", function()
        local ns = H.boot({ group = 4, afterLoad = function(n) n.db.raid.layoutMode = "party" end })
        H.roster(40)
        assertEquals(ns.RaidFrames.active, "party")
        assertEquals(#H.shownRaidButtons(ns), 0)
        clean()
    end)
    it("Always raid outside a raid: buttons 1-5 show player, party1..4; joining a raid gives raid tokens", function()
        local ns = H.boot({ group = 4, afterLoad = function(n) n.db.raid.layoutMode = "raid" end })
        local RF = ns.RaidFrames
        clean()
        assertEquals(RF.active, "raid")
        for i, token in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
            assertEquals(st(RF.buttons[i]).attrs.unit, token); assertEquals(RF.buttons[i].unit, token)
        end
        assertEquals(#H.shownRaidButtons(ns), 5)
        assertEquals(#H.shownPartyButtons(ns), 0)
        H.roster(12)
        for i = 1, 5 do assertEquals(st(RF.buttons[i]).attrs.unit, "raid" .. i) end
        assertEquals(#H.shownRaidButtons(ns), 12)
        H.roster(0)
        assertEquals(st(RF.buttons[1]).attrs.unit, "player", "back to player / party tokens")
        clean()
    end)
    it("changing a raid setting re-lays out live (scale, size)", function()
        local ns = H.boot({ group = 4 })
        H.roster(10)
        local RF = ns.RaidFrames
        ns.db.raid.scale = 80; ns.db.raid.width = 90
        ns:Changed("raid"); mock.flushTimers()
        assertEquals(st(RF.anchor).scale, 0.8)
        assertEquals(st(RF.buttons[1]).w, 90)
        clean()
    end)
end)

describe("raid frames: switching in combat", function()
    it("joining in combat: no protected calls, party stays, one chat line, switch on PLAYER_REGEN_ENABLED", function()
        local ns = H.boot({ group = 4 })
        local RF, UF = ns.RaidFrames, ns.UnitFrames
        H.enterCombat()
        mock.printed = {}
        H.roster(20)
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        H.roster(21)
        clean("in combat")
        assertEquals(RF.active, "party")
        assertTrue(st(UF.anchor).shown, "party still shown")
        assertEquals(#H.shownRaidButtons(ns), 0, "no raid button shown (they are not watched yet)")
        local lines = {}
        for _, p in ipairs(mock.printed) do if p:find("layout", 1, true) then lines[#lines + 1] = p end end
        assertEquals(#lines, 1, "exactly one chat line: " .. table.concat(mock.printed, " | "))
        assertTrue(lines[1]:find("after combat", 1, true) ~= nil)
        assertTrue(RF:StatusLine():find("after combat", 1, true) ~= nil)
        H.leaveCombat()
        clean("after combat")
        assertEquals(RF.active, "raid")
        assertEquals(#H.shownRaidButtons(ns), 21)
        assertFalse(st(UF.anchor).shown)
        assertNil(RF:StatusLine():find("after combat", 1, true))
    end)
    it("leaving the raid in combat keeps the raid frames until combat ends, then restores the party", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF = ns.RaidFrames
        assertEquals(RF.active, "raid")
        H.enterCombat()
        H.roster(0)
        clean("in combat")
        assertEquals(RF.active, "raid")
        H.leaveCombat()
        clean()
        assertEquals(RF.active, "party")
        assertEquals(#H.shownPartyButtons(ns), 5)
    end)
    it("a mid-combat joiner: rf-layout is queued, no protected call, and the joiner gets its own free cell", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local RF = ns.RaidFrames
        H.enterCombat()
        mock.calls = {}
        H.roster(11)
        clean("roster change in combat")
        for _, c in ipairs(mock.calls) do
            if c.combat and c.secure then
                assertFalse(c.method == "SetPoint" or c.method == "SetAttribute" or c.method == "SetSize" or c.method == "Show"
                    or c.method == "Hide" or c.method == "ClearAllPoints" or c.method == "SetScale", "protected " .. c.method .. " on " .. c.frame)
            end
        end
        local shown = H.shownRaidButtons(ns)
        assertEquals(#shown, 11, "the game's unit watch shows the joiner in combat")
        local cells = {}
        for _, b in ipairs(shown) do
            local x, y = H.cellOf(b)
            local key = x .. "," .. y
            assertNil(cells[key], st(b).name .. " shares a cell with " .. tostring(cells[key]))
            cells[key] = st(b).name
        end
        -- no two shown bars overlap
        local c = ns.db.raid
        for i = 1, #shown do
            for j = i + 1, #shown do
                local ax, ay = H.cellOf(shown[i]); local bx, by = H.cellOf(shown[j])
                local overlap = ax < bx + c.width and bx < ax + c.width and ay < by + c.height and by < ay + c.height
                assertFalse(overlap, st(shown[i]).name .. " overlaps " .. st(shown[j]).name)
            end
        end
        H.leaveCombat()
        clean()
        assertEquals(RF.plan.counts[3], 1, "after combat raid11 moved into group 3")
    end)
    it("a setting change in combat is queued (no protected calls) and applied after combat", function()
        local ns = H.boot({ group = 4, raid = 10 })
        H.enterCombat()
        ns.db.raid.width = 100
        ns:Changed("raid"); mock.flushTimers()
        clean("in combat")
        assertTrue(st(ns.RaidFrames.buttons[1]).w ~= 100)
        H.leaveCombat()
        assertEquals(st(ns.RaidFrames.buttons[1]).w, 100)
        clean()
    end)
    it("everything secret in combat (roster, unit values, group size): no errors, no protected calls", function()
        local ns = H.boot({ group = 4, raid = 10 })
        H.enterCombat()
        mock.state.secretAll = true; mock.state.secret = true; mock.state.secretRoster = true
        H.roster(14)
        for _, ev in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_NAME_UPDATE", "UNIT_CONNECTION", "UNIT_FLAGS", "UNIT_IN_RANGE_UPDATE" }) do
            for _, u in ipairs({ "player", "raid1", "raid3", "raid12", "party1" }) do mock.fire(ev, u) end
        end
        mock.runOnUpdate(8, 0.25)
        clean("secret combat")
        mock.state.secretAll, mock.state.secret = false, false
        H.leaveCombat()
        clean("after")
        assertEquals(#H.shownRaidButtons(ns), 14)
    end)
end)

describe("raid frames: roster", function()
    it("subgroups come from GetRaidRosterInfo (12 returns)", function()
        local ns = H.boot({ group = 4, raid = 8, raidOpts = { subgroups = { 2, 2, 5, 5, 5, 2, 7, 7 } } })
        local plan = ns.RaidFrames.plan
        assertEquals(plan.counts[2], 3); assertEquals(plan.counts[5], 3); assertEquals(plan.counts[7], 2); assertEquals(plan.counts[1], 0)
        assertEquals(ns.RaidFrames.buttons[3].raidGroup, 5)
        clean()
    end)
    it("secret roster: subgroup falls back to ceil(i / 5), a 4-man raid uses the raid layout (unknown subgroups)", function()
        local ns = H.boot({ group = 3, setup = function(S) S.secretRoster = true end, raid = 4, raidOpts = { party = true } })
        local RF = ns.RaidFrames
        clean()
        assertEquals(RF.active, "raid", RF.reason)
        assertFalse(RF:OneSubgroup())
        H.roster(12, { subgroups = { 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8 } })
        assertEquals(RF.plan.counts[1], 5); assertEquals(RF.plan.counts[2], 5); assertEquals(RF.plan.counts[3], 2)
        assertEquals(RF.plan.counts[8], 0, "the secret subgroup 8 is never read")
        clean()
    end)
    it("GetRaidRosterInfo raising or missing: fallback, no error", function()
        local ns = H.boot({ group = 4, setup = function(S) S.rosterError = true end, raid = 7 })
        assertEquals(ns.RaidFrames.active, "raid")
        assertEquals(ns.RaidFrames.plan.counts[2], 2)
        mock.setGlobal("GetRaidRosterInfo", nil)
        H.roster(9)
        assertEquals(ns.RaidFrames.plan.counts[2], 4)
        clean()
    end)
    it("sort by role within groups uses the roles (tank first)", function()
        local ns = H.boot({ group = 4, afterLoad = function(n) n.db.raid.sortWithin = "role" end,
            raid = 5, raidOpts = { subgroups = { 1, 1, 1, 1, 1 }, members = { [2] = { role = "DAMAGER" }, [3] = { role = "DAMAGER" }, [4] = { role = "DAMAGER" }, [5] = { role = "TANK" } } } })
        ns.db.raid.onlyAbove5 = false
        ns:Changed("raid"); mock.flushTimers()
        local plan = ns.RaidFrames.plan
        assertEquals(plan.byButton[5].slot, 1, "the tank sits on top")
        assertEquals(plan.byButton[1].slot, 2, "the player (healer) second")
        clean()
    end)
end)

describe("raid frames: unit events and aliases", function()
    it("UNIT_HEALTH for 'player' updates the raid button that shows the player (alias)", function()
        local ns = H.boot({ group = 4, raid = 10, raidOpts = { playerIndex = 3 } })
        local RF = ns.RaidFrames
        assertEquals(RF.alias.player, RF.buttons[3])
        mock.state.units.player.health = 321
        mock.fire("UNIT_HEALTH", "player")
        assertEquals(st(RF.buttons[3].health).value, 321)
        mock.state.units.raid7.health = 111
        mock.fire("UNIT_HEALTH", "raid7")
        assertEquals(st(RF.buttons[7].health).value, 111)
        clean()
    end)
    it("party1..4 alias to their raid buttons; a secret UnitIsUnit gives no alias (no error)", function()
        local ns = H.boot({ group = 4, raid = 10, raidOpts = { playerIndex = 2, party = true } })
        local RF = ns.RaidFrames
        assertEquals(RF.alias.party1, RF.buttons[1])
        assertEquals(RF.alias.party2, RF.buttons[3])
        mock.state.secretUnitIsUnit = true
        H.roster(10, { playerIndex = 2, party = true })
        assertNil(RF.alias.player); assertNil(RF.alias.party1)
        mock.fire("UNIT_HEALTH", "player")
        clean()
    end)
    it("events for units without a raid button and party-mode events do nothing to raid buttons", function()
        local ns = H.boot({ group = 4 })
        local before = #mock.calls
        mock.fire("UNIT_HEALTH", "raid5"); mock.fire("UNIT_HEALTH", "player"); mock.fire("UNIT_HEALTH", "nameplate1")
        for i = before + 1, #mock.calls do
            local c = mock.calls[i]
            for _, b in ipairs(ns.RaidFrames.buttons) do assertTrue(c.obj ~= b, "raid button touched in party mode") end
        end
        clean()
    end)
    it("the 0.2 s round robin touches only shown raid buttons and raises nothing", function()
        local ns = H.boot({ group = 4, raid = 25 })
        mock.state.dead.raid4 = true
        mock.runOnUpdate(25, 0.2)
        assertEquals(ns.RaidFrames.buttons[4].state, "dead")
        clean()
    end)
end)

describe("raid frames: slash commands and report", function()
    it("/hf raid prints the layout and why; /hf raid party|raid|auto set it live; junk prints usage", function()
        local ns = H.boot({ group = 4, raid = 10 })
        local ok, err, out = H.slash("raid")
        assertTrue(ok, err)
        assertTrue(out:find("Layout: raid (in a raid of 10)", 1, true) ~= nil, out)
        ok, err, out = H.slash("raid party")
        assertTrue(ok, err)
        assertEquals(ns.db.raid.layoutMode, "party")
        assertEquals(ns.RaidFrames.active, "party")
        assertTrue(out:find("Always party", 1, true) ~= nil, out)
        H.slash("raid RAID")
        assertEquals(ns.db.raid.layoutMode, "raid")
        H.slash("raid auto")
        assertEquals(ns.db.raid.layoutMode, "auto")
        ok, err, out = H.slash("raid sideways")
        assertTrue(ok, err)
        assertEquals(ns.db.raid.layoutMode, "auto")
        assertTrue(out:find("/hf raid [auto|party|raid]", 1, true) ~= nil, out)
        clean()
    end)
    it("/hf debug raid lists context, anchor, shown buttons and aliases, without player names", function()
        local ns = H.boot({ group = 4, raid = 10, raidOpts = { playerIndex = 3 } })
        local ok, err, out = H.slash("debug raid")
        assertTrue(ok, err)
        assertTrue(out:find("context: inRaid=true size=10", 1, true) ~= nil, out)
        assertTrue(out:find("anchor: shown=true", 1, true) ~= nil, out)
        assertTrue(out:find("#10 unit=raid10 shown=true watched=true", 1, true) ~= nil, out)
        assertTrue(out:find("shown buttons: 10 / 40", 1, true) ~= nil, out)
        assertTrue(out:find("player->raid3", 1, true) ~= nil, out)
        assertNil(out:find("Raider", 1, true), "no player names in debug output")
        clean()
    end)
    it("/hf debug click raid5 explains the raid button", function()
        H.boot({ group = 4, raid = 10 })
        local ok, err, out = H.slash("debug click raid5")
        assertTrue(ok, err)
        assertTrue(out:find("raid5 button", 1, true) ~= nil, out)
        clean()
    end)
    it("/hf report has the Raid settings line and the Layout line with its reason", function()
        local ns = H.boot({ group = 4, raid = 25 })
        local text = ns.Report.Build()
        if type(text) == "table" then text = table.concat(text, "\n") end
        assertTrue(text:find("Layout: raid (in a raid of 25)", 1, true) ~= nil, "layout line")
        assertTrue(text:find("Raid: mode=auto onlyAbove5=true scale=100 size=64x24 spacing=2 groups=columns/8 labels=true sort=none hideEmpty=true", 1, true) ~= nil, "raid settings line")
        assertNil(text:find("Raider", 1, true), "no raid member names in the report")
        clean()
    end)
end)

describe("raid frames: core helpers are secret-safe", function()
    it("ns.InRaid / GroupSize / InstanceType: secret -> true / 40 / 'none'; errors -> false / 0 / 'none'", function()
        local ns = H.boot({ group = 0 })
        mock.state.secretGroup = true; mock.state.secretInstance = true
        assertEquals(ns.InRaid(), true); assertEquals(ns.GroupSize(), 40); assertEquals(ns.InstanceType(), "none")
        mock.state.secretGroup = false; mock.state.secretInstance = false
        mock.setRaid(7); mock.state.instanceType = "raid"
        assertEquals(ns.InRaid(), true); assertEquals(ns.GroupSize(), 7); assertEquals(ns.InstanceType(), "raid")
        mock.setGlobal("IsInRaid", function() error("x") end)
        mock.setGlobal("GetNumGroupMembers", function() error("x") end)
        mock.setGlobal("IsInInstance", function() error("x") end)
        assertEquals(ns.InRaid(), false); assertEquals(ns.GroupSize(), 0); assertEquals(ns.InstanceType(), "none")
    end)
end)

describe("raid frames: TOC", function()
    it("RaidLayout loads right after Util; RaidStyle and RaidFrames after UnitFrames and before ClickCast", function()
        local idx = {}
        for i, f in ipairs(L.parseToc().files) do idx[f:gsub("\\", "/")] = i end
        assertEquals(idx["Util/RaidLayout.lua"], idx["Util/Util.lua"] + 1)
        assertTrue(idx["Frames/RaidStyle.lua"] > idx["Frames/UnitFrames.lua"])
        assertTrue(idx["Frames/RaidFrames.lua"] > idx["Frames/RaidStyle.lua"])
        assertTrue(idx["ClickCast/ClickCast.lua"] > idx["Frames/RaidFrames.lua"])
    end)
end)
