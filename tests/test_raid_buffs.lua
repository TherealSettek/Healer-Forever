-- My buff markers on the raid bars (Phase 3): RaidLayout.BuffMarkers / NextBuffCheck (pure), the markers on real raid bars
-- (missing = gold, ending = orange with pulse / sweep / border), count badge, combat hide / dim, re-check after combat,
-- death in combat, the 8-per-tick throttle, UNIT_AURA ignored in combat, idle in party mode, never clickable, the Self rule
-- on my own raid bar, MissingCount and the smart buff key (raid replaces the party class buffs, role buffs kept), the
-- tooltip lines, and RS.Render drawing the same markers.
local mock = require("wow_mock")
local H = require("raid_helpers")
local L = require("loader")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local st, errstr = H.st, H.errstr

local function clean(label)
    assertEquals(#mock.errors, 0, (label or "") .. " errors:\n" .. errstr())
    assertEquals(H.violations(), "", (label or "") .. " protected calls in combat")
    assertEquals(#mock.blocked, 0, (label or "") .. " blocked calls")
end

-- ------------------------------------------------------------------------------------------------ pure
local ns0 = L.loadContract({})
local RL = ns0.RaidLayout

local function item(key, opts)
    opts = opts or {}
    local it = { key = key, missing = opts.missing ~= false and (opts.missing or opts.ending) or false }
    if opts.ending then it.auraName = "Some Buff"; it.remaining = opts.remaining or 10; it.pct = opts.pct; it.duration = opts.duration end
    if opts.present then it.missing = false; it.auraName = "Some Buff"; it.remaining = opts.remaining; it.duration = opts.duration; it.pct = opts.pct end
    return it
end

describe("raid buffs: BuffItemState / BuffMarkers (pure)", function()
    local miss1, miss2 = item("a", { missing = true }), item("b", { missing = true })
    local end1, end2 = item("c", { ending = true, remaining = 5 }), item("d", { ending = true, remaining = 8 })
    local ok1 = item("e", { present = true, remaining = 500 })
    it("item states: gone -> miss, missing with time left -> end, not missing -> nil", function()
        assertEquals(RL.BuffItemState(miss1), "miss")
        assertEquals(RL.BuffItemState(end1), "end")
        assertNil(RL.BuffItemState(ok1))
        assertNil(RL.BuffItemState(nil)); assertNil(RL.BuffItemState("x"))
        assertEquals(RL.BuffItemState({ key = "z", missing = true, auraName = "X", remaining = 0 }), "miss", "0 s left = gone")
    end)
    it("state (default): first missing with the missing count + first ending with the ending count, max 2", function()
        local m = RL.BuffMarkers({ ok1, end1, miss1, end2, miss2 }, "state", true)
        assertEquals(#m, 2)
        assertEquals(m[1].kind, "miss"); assertEquals(m[1].key, "a"); assertEquals(m[1].count, 2)
        assertEquals(m[2].kind, "end"); assertEquals(m[2].key, "c"); assertEquals(m[2].count, 2)
        assertEquals(#RL.BuffMarkers({ ok1 }, "state", true), 0)
        local onlyEnd = RL.BuffMarkers({ end2 }, "state", true)
        assertEquals(#onlyEnd, 1); assertEquals(onlyEnd[1].kind, "end"); assertEquals(onlyEnd[1].count, 1)
    end)
    it("first: one icon only, missing before ending", function()
        local m = RL.BuffMarkers({ end1, miss1, miss2 }, "first", true)
        assertEquals(#m, 1); assertEquals(m[1].kind, "miss"); assertEquals(m[1].count, 2)
        m = RL.BuffMarkers({ end1, end2 }, "first", true)
        assertEquals(#m, 1); assertEquals(m[1].kind, "end"); assertEquals(m[1].count, 2)
    end)
    it("stack: one icon per buff (missing first), max 3, count 1", function()
        local m = RL.BuffMarkers({ end1, miss1, end2, miss2 }, "stack", true)
        assertEquals(#m, 3)
        assertEquals(m[1].key, "a"); assertEquals(m[2].key, "b"); assertEquals(m[3].key, "c")
        for _, x in ipairs(m) do assertEquals(x.count, 1) end
    end)
    it("showEnding false: ending buffs get no icon in any mode", function()
        for _, mode in ipairs({ "state", "first", "stack" }) do
            local m = RL.BuffMarkers({ end1, end2 }, mode, false)
            assertEquals(#m, 0, mode)
            m = RL.BuffMarkers({ end1, miss1 }, mode, false)
            assertEquals(#m, 1, mode); assertEquals(m[1].kind, "miss")
        end
    end)
    it("bad input: nil report, junk items", function()
        assertEquals(#RL.BuffMarkers(nil, "state", true), 0)
        assertEquals(#RL.BuffMarkers({ "x", 5 }, "stack", true), 0)
    end)
end)

describe("raid buffs: ItemDuration / NextBuffCheck (pure)", function()
    it("duration: explicit, else derived from time left and percentage, else nil", function()
        assertEquals(RL.ItemDuration({ duration = 600 }), 600)
        assertEquals(RL.ItemDuration({ remaining = 30, pct = 10 }), 300)
        assertNil(RL.ItemDuration({ remaining = 30 }))
        assertNil(RL.ItemDuration({ remaining = 0, pct = 0 }))
    end)
    it("a present buff is due when it crosses the rebuff % (time left = percent of its duration)", function()
        local t = RL.NextBuffCheck({ item("x", { present = true, remaining = 300, duration = 600 }) }, 5, 1000)
        assertEquals(t, 1000 + 300 - 30)
        -- exactly at the boundary: due now
        assertEquals(RL.NextBuffCheck({ item("x", { present = true, remaining = 30, duration = 600 }) }, 5, 1000), 1000)
        -- already below (rounding): never in the past
        assertEquals(RL.NextBuffCheck({ item("x", { present = true, remaining = 20, duration = 600 }) }, 5, 1000), 1000)
    end)
    it("an ending buff is due when it runs out; unknown duration -> when it runs out; percent 0 -> when it runs out", function()
        assertEquals(RL.NextBuffCheck({ item("x", { ending = true, remaining = 12 }) }, 5, 1000), 1012)
        assertEquals(RL.NextBuffCheck({ item("x", { present = true, remaining = 90 }) }, 5, 1000), 1090)
        assertEquals(RL.NextBuffCheck({ item("x", { present = true, remaining = 300, duration = 600 }) }, 0, 1000), 1300)
    end)
    it("the earliest item wins; missing / permanent / junk items are not timed", function()
        local r = { item("a", { present = true, remaining = 300, duration = 600 }), item("b", { ending = true, remaining = 40 }),
            item("c", { missing = true }), item("d", { present = true, remaining = 0 }), "junk" }
        assertEquals(RL.NextBuffCheck(r, 5, 1000), 1040)
        assertNil(RL.NextBuffCheck({ item("c", { missing = true }) }, 5, 1000))
        assertNil(RL.NextBuffCheck(nil, 5, 1000))
    end)
end)

-- ------------------------------------------------------------------------------------------------ real bars
-- Priest player (fortitude for everyone, + spirit for non-melee non-tanks): several buffs per member.
local function boot(opts)
    opts = opts or {}
    local ns, S = H.boot({ group = 4, raid = opts.raid or 10, raidOpts = opts.raidOpts,
        setup = function(S0)
            S0.units.player.class = opts.class or "PRIEST"
            if opts.setup then opts.setup(S0) end
        end,
        afterLoad = function(n, S0)
            if (opts.class or "PRIEST") == "PRIEST" then
                n.db.presets[1] = n.Presets.ExampleFor("PRIEST"); n.db.activePreset = 1
            end
            if opts.afterLoad then opts.afterLoad(n, S0) end
        end })
    mock.runOnUpdate(6, 0.25)
    return ns, ns.RaidFrames, ns.RaidStyle, S
end
local function tickAll() for _ = 1, 8 do mock.runOnUpdate(2, 0.25) end end
local function aura(name, left, dur)
    local S = mock.state
    S.nextAura = (S.nextAura or 9000) + 1
    return { spellId = S.nextAura, auraInstanceID = S.nextAura, name = name, icon = 136000, duration = dur, expirationTime = S.now + left,
        applications = 0, isHelpful = true, sourceUnit = "player" }
end
local function slots(button)
    local out = {}
    for _, s in ipairs(button.buffSlots) do if st(s).shown then out[#out + 1] = s end end
    return out
end
local function setAuras(unit, list) mock.state.auras[unit] = list; mock.fire("UNIT_AURA", unit); tickAll() end

describe("raid buffs: markers on the raid bars", function()
    it("missing buffs: gold marker with the spell icon and a count badge for 2+ (state mode)", function()
        local ns, RF, RS = boot()
        clean()
        local b = RF.buttons[2]   -- PRIEST healer: fortitude + spirit
        local s = slots(b)
        assertEquals(#s, 1)
        local c = RS.COLORS.buffMissing
        local v = st(s[1].border).vertex
        assertTrue(v.r == c[1] and v.g == c[2] and v.b == c[3], "gold border")
        assertEquals(st(s[1].count).text, "2")
        assertTrue(st(s[1].countBG).shown)
        assertEquals(st(s[1].icon).texture, ns.BuffButtons.IconFor(ns.Classes.BUFFS.fortitude.name, ns.Classes.BUFFS.fortitude))
        assertEquals(b.buffMissing, 2)
        -- a melee member gets only fortitude: no badge
        local rogue = RF.buttons[4]
        assertEquals(#slots(rogue), 1)
        assertEquals(st(slots(rogue)[1].count).text, ""); assertFalse(st(slots(rogue)[1].countBG).shown)
    end)
    it("a long buff clears its marker; under the rebuff % it turns orange and pulses (Play once per state change)", function()
        local _, RF, RS = boot()
        local b = RF.buttons[4]   -- ROGUE: fortitude only
        local slot = b.buffSlots[1]
        setAuras("raid4", { aura("Power Word: Fortitude", 1500, 1800) })
        assertEquals(#slots(b), 0, "buff on: no marker")
        mock.calls = {}
        setAuras("raid4", { aura("Power Word: Fortitude", 60, 1800) })   -- 3.3 % < 5 %
        assertEquals(#slots(b), 1)
        local c = RS.COLORS.buffEnding
        local v = st(slot.border).vertex
        assertTrue(v.r == c[1] and v.g == c[2] and v.b == c[3], "orange border")
        assertTrue(st(slot.pulse).playing, "pulse while ending")
        mock.fire("UNIT_AURA", "raid4"); tickAll(); mock.fire("UNIT_AURA", "raid4"); tickAll()
        assertEquals(#mock.callsTo("Play", function(x) return x.obj == slot.pulse end), 1, "Play only on the state change")
        setAuras("raid4", {})
        assertFalse(st(slot.pulse).playing, "missing: no pulse")
        clean()
    end)
    it("a present buff is re-checked by itself when it crosses the rebuff % (no aura event)", function()
        local _, RF = boot()
        local b = RF.buttons[4]
        setAuras("raid4", { aura("Power Word: Fortitude", 100, 1800) })   -- due in 100 - 90 = 10 s
        assertEquals(#slots(b), 0)
        mock.advance(11, 0.25)
        assertEquals(#slots(b), 1, "turned ending without UNIT_AURA")
        assertEquals(b.buffSlots[1].kind, "end")
    end)
    it("endingLook sweep: a cooldown sweep over the rebuff window, no pulse; border: neither", function()
        local _, RF = boot({ afterLoad = function(n) n.db.raid.buffs.endingLook = "sweep" end })
        local b = RF.buttons[4]
        local fort = aura("Power Word: Fortitude", 60, 1800)
        setAuras("raid4", { fort })
        local slot = b.buffSlots[1]
        assertTrue(st(slot.cd).shown)
        local start, dur = tostring(slot.cdKey):match("^([%d%.]+):([%d%.]+)$")
        start, dur = tonumber(start), tonumber(dur)
        assertNotNil(dur, "SetCooldown(start, window) applied (cdKey " .. tostring(slot.cdKey) .. ")")
        local window = 1800 * 5 / 100
        assertTrue(math.abs(dur - window) < 1e-6, "window " .. tostring(dur))
        assertTrue(math.abs(start + window - fort.expirationTime) < 0.6, "the sweep ends when the buff runs out")
        assertFalse(st(slot.pulse).playing == true)
        local _, RF2 = boot({ afterLoad = function(n) n.db.raid.buffs.endingLook = "border" end })
        setAuras("raid4", { aura("Power Word: Fortitude", 60, 1800) })
        local s2 = RF2.buttons[4].buffSlots[1]
        assertTrue(st(s2).shown); assertFalse(st(s2.cd).shown); assertFalse(st(s2.pulse).playing == true)
        clean()
    end)
    it("showEnding off: an ending buff shows nothing", function()
        local _, RF = boot({ afterLoad = function(n) n.db.raid.buffs.showEnding = false end })
        setAuras("raid4", { aura("Power Word: Fortitude", 60, 1800) })
        assertEquals(#slots(RF.buttons[4]), 0)
    end)
    it("buffs.show off: no markers anywhere", function()
        local _, RF = boot({ afterLoad = function(n) n.db.raid.buffs.show = false end })
        for _, b in ipairs(RF.buttons) do assertEquals(#slots(b), 0) end
    end)
    it("marker slots are never clickable (no EnableMouse(true), mouse off)", function()
        local _, RF = boot()
        for _, b in ipairs(RF.buttons) do
            for _, s in ipairs(b.buffSlots) do
                assertEquals(#mock.callsTo("EnableMouse", function(x) return x.obj == s and x.args[1] == true end), 0)
                assertFalse(st(s).mouse == true)
            end
        end
    end)
end)

describe("raid buffs: combat", function()
    it("hide (default): markers vanish in combat, come back after combat", function()
        local _, RF = boot()
        local b = RF.buttons[2]
        assertEquals(#slots(b), 1)
        H.enterCombat()
        assertEquals(#slots(b), 0)
        H.leaveCombat(); tickAll()
        assertEquals(#slots(b), 1)
        clean()
    end)
    it("dim: last known markers stay at alpha 0.45, desaturated, without pulse", function()
        local _, RF, RS = boot({ afterLoad = function(n) n.db.raid.buffs.inCombat = "dim" end })
        setAuras("raid4", { aura("Power Word: Fortitude", 60, 1800) })
        local slot = RF.buttons[4].buffSlots[1]
        assertTrue(st(slot.pulse).playing)
        H.enterCombat()
        assertTrue(st(slot).shown)
        assertEquals(st(slot).alpha, RS.DIM_ALPHA); assertEquals(RS.DIM_ALPHA, 0.45)
        assertTrue(st(slot.icon).desat)
        assertFalse(st(slot.pulse).playing)
        H.leaveCombat(); tickAll()
        assertEquals(st(slot).alpha, 1); assertFalse(st(slot.icon).desat); assertTrue(st(slot.pulse).playing)
        clean()
    end)
    it("no aura reads in combat; UNIT_AURA in combat is ignored; everyone is re-checked after combat", function()
        local ns, RF = boot({ afterLoad = function(n) n.db.raid.buffs.inCombat = "dim" end })
        H.enterCombat()
        mock.resetAuraCalls()
        mock.state.auras.raid4 = { aura("Power Word: Fortitude", 1500, 1800) }
        mock.fire("UNIT_AURA", "raid4")
        assertNil(RF.buffDirty[RF.buttons[4]], "not marked dirty in combat")
        mock.runOnUpdate(10, 0.25)
        assertEquals(mock.auraCalls.combat, 0, "aura APIs read in combat")
        assertEquals(#slots(RF.buttons[4]), 1, "still the last known (dimmed) marker")
        H.leaveCombat()
        for _, b in ipairs(RF.buttons) do assertTrue(RF.buffDirty[b] == true) end
        tickAll()
        assertEquals(#slots(RF.buttons[4]), 0, "re-checked after combat")
        clean()
        assertNotNil(ns)
    end)
    it("a death in combat clears that member's markers at once (also in dim mode)", function()
        local _, RF = boot({ afterLoad = function(n) n.db.raid.buffs.inCombat = "dim" end })
        H.enterCombat()
        assertEquals(#slots(RF.buttons[2]), 1)
        mock.state.dead.raid2 = true
        mock.fire("UNIT_FLAGS", "raid2")
        assertEquals(#slots(RF.buttons[2]), 0)
        assertNil(RF.buttons[2].buffMarkerData)
        clean()
    end)
end)

describe("raid buffs: throttle and idle", function()
    it("at most 8 members are checked per 0.5 s tick", function()
        local _, RF = boot({ raid = 30 })
        RF:MarkAllBuffsDirty()
        local n = RF:BuffTick()
        assertEquals(n, 8)
        assertEquals(RF.BUFF_PER_TICK, 8); assertEquals(RF.BUFF_TICK, 0.5)
        local total = n
        for _ = 1, 5 do total = total + RF:BuffTick() end
        assertEquals(total, 30, "everyone checked over several ticks")
        assertEquals(RF:BuffTick(), 0, "nothing dirty or due: nothing checked")
    end)
    it("party mode: no checks, no markers, raid MissingCount 0", function()
        local ns, RF = boot({ raid = 0 })
        RF:MarkAllBuffsDirty()
        assertEquals(RF:BuffTick(), 0)
        for _, b in ipairs(RF.buttons) do assertEquals(#slots(b), 0) end
        assertEquals(RF:MissingCount(), 0)
        assertEquals(#RF:PendingList(), 0)
        assertNotNil(ns)
    end)
end)

describe("raid buffs: Self rule, MissingCount, smart buff, tooltip", function()
    it("my own raid bar follows the preset's Self rule (evaluated as 'player')", function()
        local ns, RF = boot({ class = "PALADIN", raidOpts = { playerIndex = 3 } })
        assertEquals(RF.buttons[3].buffMarkerData[1].key, "wisdom", "class rule for a Paladin healer")
        ns.db.presets[ns.db.activePreset].self = { "kings" }
        ns:Changed("presets"); tickAll()
        assertEquals(RF.buttons[3].buffMarkerData[1].key, "kings")
        assertEquals(RF.buttons[6].buffMarkerData[1].key, "might", "others keep their class rule")
    end)
    it("MissingCount: raid bars replace the party buttons while the raid layout is active", function()
        local ns, RF = boot()
        local raidMissing = 0
        for _, b in ipairs(RF.buttons) do if st(b).shown then raidMissing = raidMissing + (b.buffMissing or 0) end end
        assertTrue(raidMissing >= 10)
        assertEquals(RF:MissingCount(), raidMissing)
        assertEquals(ns.BuffButtons:MissingCount(), raidMissing, "no extras configured: the raid count alone")
        H.roster(0); mock.tick(); mock.flushTimers()
        assertEquals(RF:MissingCount(), 0)
        local party = 0
        for _, b in ipairs(ns.BuffButtons.buttons) do if b.buffKey then party = party + (b.missingCount or 1) end end
        assertEquals(ns.BuffButtons:MissingCount(), party)
    end)
    it("smart buff key: picks a raid member while the raid layout is active, strict macro; party tokens otherwise", function()
        local ns, RF = boot()
        mock.tick(); mock.flushTimers()
        local smart = ns.BuffButtons.smart
        local u = st(smart).attrs.unit
        assertTrue(type(u) == "string" and (u:match("^raid%d+$") or u == "player"), "smart target " .. tostring(u))
        local macro = st(smart).attrs.macrotext or st(smart).attrs.macrotext1
        if macro then assertEquals(#H.macroProblems(macro, u), 0, macro) end
        for _, e in ipairs(RF:PendingList()) do assertEquals(e.kind, "blessing") end
        H.roster(0); mock.tick(); mock.flushTimers()
        local u2 = st(smart).attrs.unit
        assertTrue(u2 == nil or u2 == "player" or u2:match("^party%d$") ~= nil, "party mode target " .. tostring(u2))
        clean()
    end)
    it("smart list: raid class buffs replace the party ones (raid tokens only), role buffs (extras) are kept", function()
        local ns = boot({ class = "PALADIN" })
        local seen
        local real = ns.Presets.PickNext
        ns.Presets.PickNext = function(list, ...) seen = list; return real(list, ...) end
        ns.db.presets[ns.db.activePreset].extras = { { spell = "Blessing of Sanctuary", roles = { TANK = true } } }
        ns:Changed("presets"); tickAll(); mock.tick(); mock.flushTimers()
        ns.Presets.PickNext = real
        assertNotNil(seen, "smart button evaluated")
        local blessings, extras = 0, 0
        for _, e in ipairs(seen) do
            if e.kind == "blessing" then
                blessings = blessings + 1
                assertTrue(e.unit == "player" or e.unit:match("^raid%d+$") ~= nil, "class buff on a party token: " .. tostring(e.unit))
            elseif e.kind == "extra" then
                extras = extras + 1
            end
        end
        assertTrue(blessings >= 5, "raid class buffs on the list (" .. blessings .. ")")
        assertTrue(extras >= 1, "the tank's role buff is kept")
        clean()
    end)
    it("tooltip lines: raid group, 'My buffs:' with one line per buff; in combat a note; dead: not checked", function()
        local _, RF = boot()
        setAuras("raid3", { aura("Power Word: Fortitude", 60, 1800) })
        local lines = {}
        local tip = { AddLine = function(_, t) lines[#lines + 1] = t end }
        RF.TooltipExtra(RF.buttons[3], tip)
        local text = table.concat(lines, "\n")
        assertTrue(text:find("Raid group 1", 1, true) ~= nil, text)
        assertTrue(text:find("My buffs:", 1, true) ~= nil, text)
        assertTrue(text:find("Power Word: Fortitude: ending, 1:00 left", 1, true) ~= nil or text:find("Power Word: Fortitude: ending", 1, true) ~= nil, text)
        assertTrue(text:find("Divine Spirit: missing", 1, true) ~= nil, text)
        H.enterCombat()
        lines = {}
        RF.TooltipExtra(RF.buttons[3], tip)
        assertTrue(table.concat(lines, "\n"):find("re-checked after combat", 1, true) ~= nil)
        H.leaveCombat()
        mock.state.dead.raid3 = true; mock.fire("UNIT_FLAGS", "raid3")
        lines = {}
        RF.TooltipExtra(RF.buttons[3], tip)
        assertTrue(table.concat(lines, "\n"):find("not checked (dead or offline)", 1, true) ~= nil, table.concat(lines, "|"))
        clean()
    end)
end)

describe("raid buffs: RS.Render draws the same markers as the real bar", function()
    it("same slots, colours, counts, pulse; combat hide and dim", function()
        local ns, RF, RS = boot()
        setAuras("raid4", { aura("Power Word: Fortitude", 60, 1800) })
        local cfg = ns.db.raid
        for _, i in ipairs({ 2, 4 }) do
            local real = RF.buttons[i]
            for _, mode in ipairs({ "none", "hide", "dim" }) do
                cfg.buffs.inCombat = mode == "dim" and "dim" or "hide"
                local inCombat = mode ~= "none"
                if inCombat then H.enterCombat() end
                RF:RenderAllBuffMarkers()
                local fake = ns.NewFrame("Frame", nil, UIParent)
                RS.Render(fake, { class = "PRIEST", hp = 1000, maxHp = 1000, buffs = real.buffMarkerData, combat = inCombat }, cfg)
                local label = "raid" .. i .. " " .. mode
                for k = 1, RS.MAX_MARKERS do
                    local a, b = real.buffSlots[k], fake.buffSlots[k]
                    assertEquals(st(b).shown, st(a).shown, label .. " slot " .. k .. " shown")
                    if st(a).shown then
                        assertDeepEquals(st(b.border).vertex, st(a.border).vertex, label .. " border")
                        assertEquals(st(b.count).text, st(a.count).text, label .. " count")
                        assertEquals(st(b.pulse).playing == true, st(a.pulse).playing == true, label .. " pulse")
                        assertEquals(st(b).alpha, st(a).alpha, label .. " alpha")
                        assertEquals(st(b.icon).texture, st(a.icon).texture, label .. " icon")
                    end
                end
                if inCombat then H.leaveCombat(); tickAll() end
            end
        end
        cfg.buffs.inCombat = "hide"
        clean()
    end)
end)
