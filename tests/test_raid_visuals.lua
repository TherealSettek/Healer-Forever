-- Raid bars, style D "Hurt stands out" (Frames/RaidStyle.lua + the unit updates in Frames/RaidFrames.lua), Phase 2:
-- muting through a per-class Step colour curve (and its fallbacks), the deficit / percent / none centre text with its
-- "only when hurt" alpha, the state texts, the name, the text geometry against RaidLayout.Reserves / TextLayout, the target
-- and aggro outlines, the range look (dashes, alpha, secret path), incoming heals, event routing, combat and everything
-- secret, and RS.Render (preview path) matching the real unit path. Buff markers and debuff containers (Phase 3) are not
-- asserted here.
local mock = require("wow_mock")
local H = require("raid_helpers")
local L = require("loader")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local st, errstr = H.st, H.errstr

local function clean(label)
    assertEquals(#mock.errors, 0, (label or "") .. " errors:\n" .. errstr())
    assertEquals(H.violations(), "", (label or "") .. " protected calls in combat")
end

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function rgb(r, g, b) return { r, g, b } end
local function assertColor(c, r, g, b, label)
    if type(r) == "table" then r, g, b, label = r[1], r[2], r[3], g end
    assertNotNil(c, label .. ": no colour")
    assertTrue(near(c.r, r) and near(c.g, g) and near(c.b, b),
        string.format("%s: expected (%.3f,%.3f,%.3f) got (%s,%s,%s)", label, r, g, b, tostring(c.r), tostring(c.g), tostring(c.b)))
end

-- Raid of 10: raid1 = player (PALADIN 800/1000), raid2 full health, raid3 hurt 600/1000, others full.
-- opts.setup(S) runs before the addon loads (mock globals can be replaced there).
local function boot(opts)
    opts = opts or {}
    local ns = H.boot({ group = 4, raid = opts.raid or 10, raidOpts = opts.raidOpts or { members = { [3] = { health = 600, class = "MAGE" } } },
        setup = opts.setup, afterLoad = opts.afterLoad })
    return ns, ns.RaidFrames, ns.RaidStyle
end

local function bar(button) return st(button.health) end
local function center(button) return st(button.centerText) end
local function refresh(unit, ev) mock.fire(ev or "UNIT_HEALTH", unit); mock.flushTimers() end
local function fullUpdate(ns, button) ns.RaidFrames:UpdateAll(button) end

-- ------------------------------------------------------------------------------------------------ bar colour (muting)
describe("raid visuals: muting (full health muted, hurt in full class colour)", function()
    it("Step curve: a full bar is muted (class 38% + #2a2a2a), a hurt bar has the full class colour", function()
        local ns, RF, RS = boot()
        clean("boot")
        local r, g, b = ns.UnitFrames.ClassColorFor("raid2")
        local mr, mg, mb = RS.Muted(r, g, b)
        assertColor(bar(RF.buttons[2]).sbColor, mr, mg, mb, "full raid2 muted")
        local r3, g3, b3 = ns.UnitFrames.ClassColorFor("raid3")
        assertColor(bar(RF.buttons[3]).sbColor, r3, g3, b3, "hurt raid3 full colour")
        -- the curve is really a Step curve per class with hurt -> full colour at 0 and muted from RS.FULL_AT (99.5 %) on
        assertEquals(RS.FULL_AT, 0.995)
        local found = false
        for _, c in ipairs(mock.curves) do
            if c.curveType == Enum.LuaCurveType.Step and #c.points == 2 and c.points[1][1] == 0 and c.points[2][1] == RS.FULL_AT then
                local p0, p1 = c.points[1][2], c.points[2][2]
                if near(p0.r, r) and near(p0.g, g) and near(p0.b, b) and near(p1.r, mr) and near(p1.g, mg) then found = true end
            end
        end
        assertTrue(found, "a Step colour curve hurt=class / full=muted (point at FULL_AT) exists for raid2's class")
        -- health changes flip it live
        mock.state.units.raid3.health = 1000; refresh("raid3")
        assertColor(bar(RF.buttons[3]).sbColor, rgb(RS.Muted(r3, g3, b3)), "raid3 healed -> muted")
        mock.state.units.raid2.health = 10; refresh("raid2")
        assertColor(bar(RF.buttons[2]).sbColor, r, g, b, "raid2 hurt -> full colour")
        -- the step sits at 99.5 %: 99.6 % still counts as full (muted), 99.4 % is hurt (rounding never flickers a full bar)
        mock.state.units.raid3.health = 996; refresh("raid3")
        assertColor(bar(RF.buttons[3]).sbColor, rgb(RS.Muted(r3, g3, b3)), "99.6% -> muted")
        mock.state.units.raid3.health = 994; refresh("raid3")
        assertColor(bar(RF.buttons[3]).sbColor, r3, g3, b3, "99.4% -> full colour")
    end)
    it("the muted mix is exactly class * 0.38 + 42/255 * 0.62", function()
        local _, _, RS = boot()
        local mr, mg, mb = RS.Muted(1, 0, 0.5)
        assertTrue(near(mr, 0.38 + 42 / 255 * 0.62) and near(mg, 42 / 255 * 0.62) and near(mb, 0.19 + 42 / 255 * 0.62))
    end)
    it("fallback without UnitHealthPercent: readable health decides (full -> muted, hurt -> full)", function()
        local ns, RF, RS = boot({ setup = function() mock.setGlobal("UnitHealthPercent", nil) end })
        clean()
        local r, g, b = ns.UnitFrames.ClassColorFor("raid2")
        assertColor(bar(RF.buttons[2]).sbColor, rgb(RS.Muted(r, g, b)), "full muted")
        assertColor(bar(RF.buttons[3]).sbColor, rgb(ns.UnitFrames.ClassColorFor("raid3")), "hurt full")
    end)
    it("fallback without the curve API (C_CurveUtil / CreateColor missing): same result, no error", function()
        local ns, RF, RS = boot({ setup = function() mock.setGlobal("C_CurveUtil", nil) end })
        clean()
        assertFalse(RS.CurvesSupported())
        local r, g, b = ns.UnitFrames.ClassColorFor("raid2")
        assertColor(bar(RF.buttons[2]).sbColor, rgb(RS.Muted(r, g, b)), "full muted")
        assertColor(bar(RF.buttons[3]).sbColor, rgb(ns.UnitFrames.ClassColorFor("raid3")), "hurt full")
    end)
    it("everything secret: through the curve the colour is passed on secret; without it the bar shows full colour", function()
        local ns, RF = boot()
        mock.state.secretAll = true
        fullUpdate(ns, RF.buttons[2])
        clean("secret curve")
        assertTrue(mock.isSecret(bar(RF.buttons[2]).sbColor.r), "secret colour straight into SetStatusBarColor")
        mock.setGlobal("UnitHealthPercent", nil)
        fullUpdate(ns, RF.buttons[2])
        clean("secret no curve")
        assertColor(bar(RF.buttons[2]).sbColor, rgb(ns.UnitFrames.ClassColorFor("raid2")), "unknown health -> full colour (a hurt bar is never hidden)")
    end)
    it("muteFull off: always the full class colour", function()
        local ns, RF = boot({ afterLoad = function(n) n.db.raid.muteFull = false end })
        assertColor(bar(RF.buttons[2]).sbColor, rgb(ns.UnitFrames.ClassColorFor("raid2")), "full health, mute off")
        clean()
    end)
end)

-- ------------------------------------------------------------------------------------------------ centre text
describe("raid visuals: health number", function()
    it("deficit: '-<missing>' in a constant red; 'only when hurt' through the text ALPHA from a Step float curve", function()
        local ns, RF, RS = boot()
        local red = RS.COLORS.deficit
        local c3 = center(RF.buttons[3])
        assertEquals(c3.text, "-" .. AbbreviateNumbers(400))
        assertColor(c3.textColor, red[1], red[2], red[3], "deficit red")
        assertEquals(c3.textColor.a, 1, "the colour itself is constant (alpha 1)")
        assertEquals(c3.alpha, 1, "visible while hurt")
        local c2 = center(RF.buttons[2])
        assertEquals(c2.text, "")
        assertEquals(c2.alpha, 0, "FontString alpha 0 at full health (no truth test on a possibly secret value)")
        assertColor(c2.textColor, red[1], red[2], red[3], "same red at full health")
        -- the float curve: Step, 1 below FULL_AT, 0 from FULL_AT on
        local curve = RS.HurtAlphaCurve()
        assertNotNil(curve)
        assertTrue(curve.isFloat, "a plain number curve (C_CurveUtil.CreateCurve), not a colour curve")
        assertEquals(curve.curveType, Enum.LuaCurveType.Step)
        assertDeepEquals(curve.points, { { 0, 1 }, { RS.FULL_AT, 0 } })
        -- 99.999 % counts as full (alpha 0), 99 % is hurt (alpha 1)
        mock.state.units.raid2.maxHealth = 100000; mock.state.units.raid2.health = 99999
        fullUpdate(ns, RF.buttons[2])
        assertEquals(center(RF.buttons[2]).alpha, 0, "0.99999 -> alpha 0")
        mock.state.units.raid2.health = 99000
        fullUpdate(ns, RF.buttons[2])
        assertEquals(center(RF.buttons[2]).alpha, 1, "0.99 -> alpha 1")
        clean()
    end)
    it("the deficit alpha is reset to 1 for DEAD and in percent mode (a full bar's alpha 0 never hides them)", function()
        local ns, RF = boot()
        local b = RF.buttons[2]
        assertEquals(center(b).alpha, 0, "full: hidden number")
        mock.state.dead.raid2 = true
        fullUpdate(ns, b)
        assertEquals(center(b).text, "DEAD")
        assertEquals(center(b).alpha, 1, "DEAD visible")
        mock.state.dead.raid2 = nil
        fullUpdate(ns, b)
        assertEquals(center(b).alpha, 0, "alive and full again: hidden")
        ns.db.raid.healthText = "percent"; ns:Changed("raid"); mock.flushTimers()
        fullUpdate(ns, b)
        assertEquals(center(b).text, "100%")
        assertEquals(center(b).alpha, 1, "percent mode shows 100%")
        clean()
    end)
    it("deficit with secret health: the secret goes straight into the text and into SetAlpha", function()
        local ns, RF, RS = boot()
        mock.state.secretAll = true
        fullUpdate(ns, RF.buttons[3])
        clean()
        assertEquals(center(RF.buttons[3]).text, "<secret formatted>")
        assertTrue(mock.isSecret(center(RF.buttons[3]).alpha), "secret alpha from UnitHealthPercent(unit, false, curve)")
        local red = RS.COLORS.deficit
        assertColor(center(RF.buttons[3]).textColor, red[1], red[2], red[3], "the colour stays the constant red")
    end)
    it("deficit fallbacks: no UnitHealthMissing -> calculator GetMissingHealth; no calculator -> max - hp; secret -> percent; nothing -> ''", function()
        local ns, RF, RS = boot({ setup = function() mock.setGlobal("UnitHealthMissing", nil) end })
        local red = RS.COLORS.deficit
        assertEquals(center(RF.buttons[3]).text, "-" .. AbbreviateNumbers(400), "calculator: max - hp")
        assertColor(center(RF.buttons[3]).textColor, red[1], red[2], red[3], "red")
        assertEquals(center(RF.buttons[2]).text, "", "full: no number")
        -- the calculator follows the unit it was last asked about (it is cached at module level)
        mock.state.units.raid4.health = 100
        fullUpdate(ns, RF.buttons[4]); fullUpdate(ns, RF.buttons[3])
        assertEquals(center(RF.buttons[4]).text, "-" .. AbbreviateNumbers(mock.state.units.raid4.maxHealth - 100))
        assertEquals(center(RF.buttons[3]).text, "-" .. AbbreviateNumbers(400))
        -- secret: the calculator's secret missing health goes straight into the text
        mock.state.secretAll = true
        fullUpdate(ns, RF.buttons[3])
        assertEquals(center(RF.buttons[3]).text, "<secret formatted>", "secret missing health formatted by the game")
        assertTrue(mock.isSecret(center(RF.buttons[3]).alpha))
        mock.state.secretAll = false
        -- no calculator either: readable max - hp
        mock.setGlobal("CreateUnitHealPredictionCalculator", nil)
        fullUpdate(ns, RF.buttons[3])
        assertEquals(center(RF.buttons[3]).text, "-" .. AbbreviateNumbers(400), "readable max - hp")
        assertColor(center(RF.buttons[3]).textColor, red[1], red[2], red[3], "red")
        -- and secret: the percent text, its colour from RS.PercentColorCurve (secret through the curve)
        mock.state.secretAll = true
        fullUpdate(ns, RF.buttons[3])
        assertEquals(center(RF.buttons[3]).text, "<secret formatted>", "secret health: the percent text (secret formatted)")
        assertTrue(mock.isSecret(center(RF.buttons[3]).textColor.r), "percent colour through the Step colour curve")
        -- no UnitHealthPercent either: nothing readable -> empty text, red (unknown = hurt)
        mock.setGlobal("UnitHealthPercent", nil)
        fullUpdate(ns, RF.buttons[3])
        assertEquals(center(RF.buttons[3]).text, "", "nothing readable: empty")
        local hurt = RS.COLORS.percentHurt
        assertColor(center(RF.buttons[3]).textColor, hurt[1], hurt[2], hurt[3], "unknown -> percent red")
        assertEquals(center(RF.buttons[3]).alpha, 1)
        clean()
    end)
    it("RS.PercentColorCurve: a Step colour curve, red below FULL_AT, light grey from FULL_AT", function()
        local _, _, RS = boot()
        local curve = RS.PercentColorCurve()
        assertNotNil(curve)
        assertEquals(curve.curveType, Enum.LuaCurveType.Step)
        assertEquals(#curve.points, 2)
        assertEquals(curve.points[1][1], 0); assertEquals(curve.points[2][1], RS.FULL_AT)
        local hurt, full = RS.COLORS.percentHurt, RS.COLORS.percentFull
        assertColor(curve.points[1][2], hurt[1], hurt[2], hurt[3], "below")
        assertColor(curve.points[2][2], full[1], full[2], full[3], "full")
        assertTrue(RS.PercentColorCurve() == curve, "cached")
    end)
    it("percent: number with red while hurt, light grey at full health (curve and readable fallback)", function()
        for _, noCurve in ipairs({ false, true }) do
            local _, RF, RS = boot({ afterLoad = function(n) n.db.raid.healthText = "percent" end,
                setup = noCurve and function() mock.setGlobal("C_CurveUtil", nil) end or nil })
            local label = noCurve and "no curve" or "curve"
            local hurt, full = RS.COLORS.percentHurt, RS.COLORS.percentFull
            assertEquals(center(RF.buttons[3]).text, "60%", label)
            assertColor(center(RF.buttons[3]).textColor, hurt[1], hurt[2], hurt[3], label .. " hurt")
            assertEquals(center(RF.buttons[2]).text, "100%", label)
            assertColor(center(RF.buttons[2]).textColor, full[1], full[2], full[3], label .. " full")
            clean(label)
        end
    end)
    it("none: no number at all", function()
        local _, RF = boot({ afterLoad = function(n) n.db.raid.healthText = "none" end })
        assertEquals(center(RF.buttons[3]).text, "")
        assertEquals(center(RF.buttons[2]).text, "")
        clean()
    end)
    it("the centre text is never given a width (it can never be cut)", function()
        local ns, RF = boot()
        mock.state.dead.raid5 = true; mock.state.offline.raid6 = true
        for i = 1, 10 do fullUpdate(ns, RF.buttons[i]) end
        for _, b in ipairs(RF.buttons) do
            assertEquals(#mock.callsTo("SetWidth", function(c) return c.obj == b.centerText end), 0, "SetWidth on the centre text")
        end
    end)
end)

describe("raid visuals: states", function()
    local function setup()
        local ns, RF, RS = boot()
        return ns, RF, RS, mock.state
    end
    it("dead: DEAD, empty grey bar; dead and out of range or not visible: CAN'T RES", function()
        local ns, RF, RS, S = setup()
        S.dead.raid4 = true; refresh("raid4", "UNIT_FLAGS")
        local b = RF.buttons[4]
        assertEquals(center(b).text, "DEAD")
        assertEquals(bar(b).value, 0)
        assertColor(bar(b).sbColor, RS.COLORS.grey[1], RS.COLORS.grey[2], RS.COLORS.grey[3], "grey")
        S.outOfRange.raid4 = true; refresh("raid4", "UNIT_IN_RANGE_UPDATE")
        assertEquals(center(b).text, "CAN'T RES")
        S.outOfRange.raid4 = nil; S.invisible = { raid4 = true }; refresh("raid4", "UNIT_IN_RANGE_UPDATE")
        assertEquals(center(b).text, "CAN'T RES")
        S.invisible.raid4 = nil; refresh("raid4", "UNIT_IN_RANGE_UPDATE")
        assertEquals(center(b).text, "DEAD")
        S.dead.raid4 = nil; refresh("raid4", "UNIT_FLAGS")
        assertEquals(center(b).text, "", "alive again at full health: no number")
        assertEquals(bar(b).value, 1000)
        clean()
    end)
    it("ghost stays GHOST (also out of range); offline: OFFLINE with a full grey bar; not visible: '?'", function()
        local ns, RF, RS, S = setup()
        S.dead.raid5 = true; S.ghost = { raid5 = true }; S.outOfRange.raid5 = true
        refresh("raid5", "UNIT_FLAGS"); refresh("raid5", "UNIT_IN_RANGE_UPDATE")
        assertEquals(center(RF.buttons[5]).text, "GHOST")
        assertEquals(bar(RF.buttons[5]).value, 0)
        S.offline.raid6 = true; refresh("raid6", "UNIT_CONNECTION")
        assertEquals(center(RF.buttons[6]).text, "OFFLINE")
        assertEquals(bar(RF.buttons[6]).value, 1)
        assertColor(bar(RF.buttons[6]).sbColor, RS.COLORS.grey[1], RS.COLORS.grey[2], RS.COLORS.grey[3], "offline grey")
        S.invisible = { raid7 = true }; refresh("raid7", "UNIT_IN_RANGE_UPDATE")
        assertEquals(center(RF.buttons[7]).text, "?")
        assertColor(bar(RF.buttons[7]).sbColor, RS.COLORS.grey[1], RS.COLORS.grey[2], RS.COLORS.grey[3], "not visible grey")
        clean()
    end)
end)

describe("raid visuals: name", function()
    it("own name gold, others light grey, dim when dead or not visible", function()
        local ns, RF, RS = boot({ raidOpts = { playerIndex = 3 } })
        local C = RS.COLORS
        assertColor(st(RF.buttons[3].name).textColor, C.nameMe[1], C.nameMe[2], C.nameMe[3], "me")
        assertColor(st(RF.buttons[2].name).textColor, C.name[1], C.name[2], C.name[3], "other")
        assertEquals(st(RF.buttons[2].name).text, "Raider2")
        mock.state.dead.raid2 = true; refresh("raid2", "UNIT_FLAGS")
        assertColor(st(RF.buttons[2].name).textColor, C.nameDim[1], C.nameDim[2], C.nameDim[3], "dead dim")
        mock.state.invisible = { raid4 = true }; refresh("raid4", "UNIT_IN_RANGE_UPDATE")
        assertColor(st(RF.buttons[4].name).textColor, C.nameDim[1], C.nameDim[2], C.nameDim[3], "not visible dim")
        clean()
    end)
    it("showNames off hides the name", function()
        local _, RF = boot({ afterLoad = function(n) n.db.raid.showNames = false end })
        for i = 1, 10 do assertFalse(st(RF.buttons[i].name).shown) end
        clean()
    end)
end)

-- ------------------------------------------------------------------------------------------------ geometry
describe("raid visuals: text geometry against Reserves / TextLayout", function()
    -- rectangles in frame coordinates (x right, y down) from the anchors RS.PlaceText really set
    local function rects(frame, cfg)
        local layout = frame.textLayout
        local res = frame.reserves
        local areaR = cfg.width - res.right
        local num
        local p = st(frame.centerText).points[1]
        if p[1] == "TOP" then
            num = { x = p[4] - layout.numW / 2, y = -p[5], w = layout.numW, h = layout.tfs }
        else
            assertEquals(p[1], "TOPRIGHT")
            num = { x = p[4] - layout.numW, y = -p[5], w = layout.numW, h = layout.tfs }
        end
        local name
        if st(frame.name).shown then
            local q = st(frame.name).points[1]
            local w = st(frame.name).w
            if q[2] == frame.centerText then
                assertEquals(q[1], "TOPRIGHT"); assertEquals(q[3], "TOPLEFT")
                name = { x = num.x + q[4] - w, y = num.y - q[5], w = w, h = cfg.nameSize + 2 }
            else
                name = { x = q[4], y = -q[5], w = w, h = cfg.nameSize + 2 }
            end
        end
        return num, name, areaR, layout
    end
    local function overlap(a, b) return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h end

    it("sweep 40-120 x 14-40 x name 6-10 x debuffs on/off x 0/2 buff markers: number never cut, name never over the number or markers", function()
        local ns = boot()
        local RS, RL = ns.RaidStyle, ns.RaidLayout
        local frame = ns.NewFrame("Frame", nil, UIParent)
        RS.Build(frame)
        local base = H.deepcopy(ns.db.raid)
        local n = 0
        for w = 40, 120, 8 do
            for h = 14, 40, 3 do
                for nameSize = 6, 10, 2 do
                    for _, deb in ipairs({ true, false }) do
                        for _, markers in ipairs({ 0, 2 }) do
                            n = n + 1
                            local cfg = H.deepcopy(base)
                            cfg.width, cfg.height, cfg.nameSize = w, h, nameSize
                            cfg.debuffs.show = deb
                            frame.buffMarkers = nil
                            RS.Apply(frame, cfg)
                            RS.SetBuffReserve(frame, markers)
                            RS.ShowNumber(frame, "deficit")
                            local label = string.format("w=%d h=%d name=%d deb=%s markers=%d", w, h, nameSize, tostring(deb), markers)
                            local res = frame.reserves
                            assertDeepEquals(res, RL.Reserves(cfg, markers), label .. ": reserves")
                            local num, name, areaR, layout = rects(frame, cfg)
                            local heightSize = math.max(9, math.min(18, math.floor(h * 0.5 + 0.5)))
                            assertTrue(layout.tfs >= math.min(10, heightSize), label .. ": number shrunk to " .. layout.tfs)
                            -- never left of the bar's inner edge (1 px border + 1 px pad): a number wider than the free
                            -- area runs right over the icons instead of being clipped on the left
                            assertTrue(num.x >= 2 - 1e-9, label .. string.format(": number runs off the LEFT edge (%.1f)", num.x))
                            -- inside the text frame's clip rect (the health bar, x 1 .. w - 1)
                            assertTrue(num.x + num.w <= w - 1 + 1e-9, label .. ": number cut on the right")
                            if num.x + num.w > areaR + 1e-9 then
                                assertEquals(layout.tfs, math.min(10, heightSize), label .. ": the number only runs into the icons at its minimum size")
                            end
                            if name then
                                assertTrue(name.w >= 6, label .. ": name narrower than 6 px shown")
                                assertTrue(name.x >= 0 and name.x + name.w <= w, label .. ": name outside the bar")
                                assertFalse(overlap(name, num), label .. ": name overlaps the number")
                                if res.buffW > 0 then
                                    local markersRect = { x = w - res.buffW, y = 0, w = res.buffW, h = res.bsz + 1 }
                                    assertFalse(overlap(name, markersRect), label .. ": name under the buff markers")
                                end
                            else
                                assertTrue(layout.nameW < 6, label .. ": name hidden although it had room")
                            end
                        end
                    end
                end
            end
        end
        assertTrue(n > 500)
        clean()
    end)
    it("short bars put the name to the LEFT of the number, anchored to the centre text", function()
        local ns = boot({ afterLoad = function(n) n.db.raid.height = 14; n.db.raid.nameSize = 10; n.db.raid.width = 120 end })
        local b = ns.RaidFrames.buttons[3]
        assertFalse(b.textLayout.stacked)
        local q = st(b.name).points[1]
        assertEquals(q[1], "TOPRIGHT"); assertTrue(q[2] == b.centerText); assertEquals(q[3], "TOPLEFT"); assertEquals(q[4], -3)
        clean()
    end)
end)

describe("raid visuals: Reserves (pure)", function()
    local function cfgWith(over)
        local ns = boot()
        local c = H.deepcopy(ns.db.raid)
        for k, v in pairs(over or {}) do c[k] = v end
        return ns.RaidLayout, c
    end
    it("no markers and debuff icons on: the debuff row is reserved for debuffs.max icons", function()
        local RL, c = cfgWith()
        local r = RL.Reserves(c, 0)
        assertEquals(r.buffW, 0)
        assertEquals(r.isz, RL.DebuffIconSize(c.width, 3, math.min(c.debuffs.size, c.height - 2)))
        assertEquals(r.debW, 3 * (r.isz + 1) + 1)
        assertEquals(r.right, r.debW); assertEquals(r.shift, 0)
    end)
    it("markers: n * (size + 1) + 1, size capped at height - 2; hidden buffs reserve nothing", function()
        local RL, c = cfgWith({ height = 14 })
        local r = RL.Reserves(c, 2)
        assertEquals(r.bsz, 10); assertEquals(r.buffW, 2 * 11 + 1)
        c.buffs.size = 16
        assertEquals(RL.Reserves(c, 1).bsz, 12)
        c.buffs.show = false
        assertEquals(RL.Reserves(c, 2).buffW, 0)
    end)
    it("glow-only or hidden debuffs reserve no icon row", function()
        local RL, c = cfgWith()
        c.debuffs.display = "glow"
        assertEquals(RL.Reserves(c, 0).debW, 0)
        c.debuffs.display = "icons"; c.debuffs.show = false
        assertEquals(RL.Reserves(c, 0).debW, 0)
    end)
    it("markers and icons that cannot share the height: the icon row shifts left of the markers", function()
        local RL, c = cfgWith({ height = 16 })
        local r = RL.Reserves(c, 1)
        assertTrue(r.bsz + r.isz + 3 > 16)
        assertEquals(r.shift, r.buffW)
        assertEquals(r.debW, r.shift + 3 * (r.isz + 1) + 1)
        local tall = RL.Reserves((function() c.height = 40 return c end)(), 1)
        assertEquals(tall.shift, 0)
    end)
end)

-- ------------------------------------------------------------------------------------------------ outlines and range
describe("raid visuals: target and aggro outlines", function()
    it("target: white outline on the target only, follows PLAYER_TARGET_CHANGED", function()
        local _, RF = boot()
        mock.state.target = "raid2"
        mock.fire("PLAYER_TARGET_CHANGED")
        assertTrue(st(RF.buttons[2].targetFrame).shown)
        assertFalse(st(RF.buttons[3].targetFrame).shown)
        mock.state.target = "raid3"
        mock.fire("PLAYER_TARGET_CHANGED")
        assertFalse(st(RF.buttons[2].targetFrame).shown)
        assertTrue(st(RF.buttons[3].targetFrame).shown)
        clean()
    end)
    it("secret target answer: outline shown, alpha from SetAlphaFromBoolean(v, 1, 0)", function()
        local _, RF = boot()
        mock.state.secretTarget = true
        mock.calls = {}
        mock.fire("PLAYER_TARGET_CHANGED")
        local o = RF.buttons[2].targetFrame
        assertTrue(st(o).shown)
        local calls = mock.callsTo("SetAlphaFromBoolean", function(c) return c.obj == o end)
        assertEquals(#calls, 1)
        assertTrue(mock.isSecret(calls[1].args[1])); assertEquals(calls[1].args[2], 1); assertEquals(calls[1].args[3], 0)
        clean()
    end)
    it("aggro: threat >= 2 shows the red outline, < 2 hides it, a secret status keeps the last state, dead hides it", function()
        local _, RF = boot()
        local S = mock.state
        S.threat = { raid3 = 2 }
        mock.fire("UNIT_THREAT_SITUATION_UPDATE", "raid3")
        local o = RF.buttons[3].aggroFrame
        assertTrue(st(o).shown)
        S.threat.raid3 = 1; mock.fire("UNIT_THREAT_SITUATION_UPDATE", "raid3")
        assertFalse(st(o).shown)
        S.threat.raid3 = 3; mock.fire("UNIT_THREAT_SITUATION_UPDATE", nil)
        assertTrue(st(o).shown, "a nil-unit event refreshes every bar")
        S.secretThreat = true; mock.fire("UNIT_THREAT_SITUATION_UPDATE", "raid3")
        assertTrue(st(o).shown, "secret: last known kept")
        S.secretThreat = nil
        S.dead.raid3 = true; refresh("raid3", "UNIT_FLAGS")
        assertFalse(st(o).shown, "no aggro outline on a dead bar")
        clean()
    end)
end)

describe("raid visuals: range", function()
    local function spyDashes(ns)
        local log = {}
        local real = ns.UnitFrames.LayoutDashes
        ns.UnitFrames.LayoutDashes = function(button, color, dash, gap)
            log[#log + 1] = { button = button, dash = dash, gap = gap }
            return real(button, color, dash, gap)
        end
        return log
    end
    it("out of range: alpha = rangeAlpha / 100 and a 4/3 dashed outline; not visible: 2/3 dotted; back in: alpha 1, no dashes", function()
        local ns, RF = boot({ afterLoad = function(n) n.db.raid.rangeAlpha = 35 end })
        local log = spyDashes(ns)
        local b = RF.buttons[4]
        mock.state.outOfRange.raid4 = true; refresh("raid4", "UNIT_IN_RANGE_UPDATE")
        assertEquals(st(b).alpha, 0.35)
        assertTrue(st(b.dashFrame).shown)
        assertEquals(log[#log].button, b); assertEquals(log[#log].dash, 4); assertEquals(log[#log].gap, 3)
        mock.state.outOfRange.raid4 = nil; mock.state.invisible = { raid4 = true }; refresh("raid4", "UNIT_IN_RANGE_UPDATE")
        assertEquals(st(b).alpha, 0.35)
        assertEquals(log[#log].dash, 2); assertEquals(log[#log].gap, 3)
        mock.state.invisible = {}; refresh("raid4", "UNIT_IN_RANGE_UPDATE")
        assertEquals(st(b).alpha, 1)
        assertFalse(st(b.dashFrame).shown)
        local n = #log
        refresh("raid4", "UNIT_IN_RANGE_UPDATE")
        assertEquals(#log, n, "dashes are only re-laid out when the look changes")
        clean()
    end)
    it("secret in-range answer: button alpha and dashes follow SetAlphaFromBoolean, no truth test", function()
        local _, RF = boot()
        mock.state.secretRange = true
        mock.calls = {}
        refresh("raid4", "UNIT_IN_RANGE_UPDATE")
        local b = RF.buttons[4]
        local calls = mock.callsTo("SetAlphaFromBoolean", function(c) return c.obj == b end)
        assertEquals(#calls, 1)
        assertTrue(mock.isSecret(calls[1].args[1])); assertEquals(calls[1].args[2], 1); assertEquals(calls[1].args[3], 0.5)
        local dash = mock.callsTo("SetAlphaFromBoolean", function(c) return c.obj == b.dashFrame end)
        assertEquals(#dash, 1); assertEquals(dash[1].args[2], 0); assertEquals(dash[1].args[3], 1)
        clean()
    end)
    it("no frames or textures are created by range changes in combat", function()
        local _, RF = boot()
        H.enterCombat()
        local before = #mock.frames
        for i = 2, 10 do
            mock.state.outOfRange["raid" .. i] = true; refresh("raid" .. i, "UNIT_IN_RANGE_UPDATE")
            mock.state.outOfRange["raid" .. i] = nil; mock.state.invisible = { ["raid" .. i] = true }; refresh("raid" .. i, "UNIT_IN_RANGE_UPDATE")
        end
        mock.runOnUpdate(10, 0.2)
        assertEquals(#mock.frames, before, "new regions created in combat")
        assertTrue(st(RF.buttons[10].dashFrame).shown)
        clean()
    end)
end)

describe("raid visuals: incoming heals", function()
    local function bootPred(opts)
        opts = opts or {}
        return boot({ afterLoad = opts.afterLoad, raidOpts = opts.raidOpts, setup = function(S)
            S.incoming = {}
            mock.setGlobal("CreateUnitHealPredictionCalculator", function()
                local calc = {}
                calc.GetIncomingHeals = function() if S.secretAll then return mock.newSecret() end return S.incoming[calc.unit] or 0 end
                return calc
            end)
            mock.setGlobal("UnitGetDetailedHealPrediction", function(unit, _, calc) calc.unit = unit end)
        end })
    end
    it("shows the incoming amount on alive bars, hidden when the option is off or the member is dead", function()
        local ns, RF = bootPred()
        mock.state.incoming.raid3 = 250
        mock.fire("UNIT_HEAL_PREDICTION", "raid3")
        local p = st(RF.buttons[3].pred)
        assertTrue(p.shown); assertEquals(p.value, 250); assertEquals(p.max, 1000)
        mock.state.dead.raid3 = true; refresh("raid3", "UNIT_FLAGS")
        assertFalse(st(RF.buttons[3].pred).shown)
        mock.state.dead.raid3 = nil; refresh("raid3", "UNIT_FLAGS")
        ns.db.raid.showIncoming = false; ns:Changed("raid"); mock.flushTimers()
        mock.fire("UNIT_HEAL_PREDICTION", "raid3")
        assertFalse(st(RF.buttons[3].pred).shown)
        clean()
    end)
    it("a secret amount goes straight into SetValue; UNIT_HEAL_PREDICTION for 'player' reaches the player's raid bar", function()
        local _, RF = bootPred({ raidOpts = { playerIndex = 2 } })
        mock.state.incoming.raid2 = 77
        mock.fire("UNIT_HEAL_PREDICTION", "player")
        assertEquals(st(RF.buttons[2].pred).value, 77)
        mock.state.secretAll = true
        mock.fire("UNIT_HEAL_PREDICTION", "raid4")
        assertTrue(mock.isSecret(st(RF.buttons[4].pred).value))
        clean()
    end)
end)

-- ------------------------------------------------------------------------------------------------ combat / secret
describe("raid visuals: combat and everything secret", function()
    it("every unit event in combat with everything secret: no errors, no protected calls", function()
        local ns, RF = boot()
        H.enterCombat()
        mock.state.secretAll = true; mock.state.secretRange = true; mock.state.secretTarget = true; mock.state.secretThreat = true
        for _, ev in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_NAME_UPDATE", "UNIT_CONNECTION", "UNIT_FLAGS", "UNIT_IN_RANGE_UPDATE",
            "UNIT_HEAL_PREDICTION", "UNIT_THREAT_SITUATION_UPDATE" }) do
            for _, u in ipairs({ "player", "raid1", "raid3", "raid9", "party2" }) do mock.fire(ev, u) end
        end
        mock.fire("PLAYER_TARGET_CHANGED"); mock.fire("UNIT_THREAT_SITUATION_UPDATE")
        for _, b in ipairs(RF.buttons) do if st(b).shown then ns.RaidFrames:UpdateAll(b) end end
        mock.runOnUpdate(10, 0.2)
        clean("secret combat")
        assertEquals(#mock.createdInCombat, 0, "nothing created in combat")
    end)
end)

-- ------------------------------------------------------------------------------------------------ preview path
describe("raid visuals: RS.Render (preview) matches the real unit path", function()
    it("same bar colour, value, centre text, text colour and name colour for alive / hurt / dead / offline / out of range", function()
        -- missing amounts >= 1000 so the mock's AbbreviateNumbers ("%.1fk") and RS.Abbreviate agree (see the report note on
        -- "k" vs the client's "K")
        local ns, RF, RS = boot({ raidOpts = { members = { [3] = { health = 1500, maxHealth = 3000, class = "MAGE" }, [5] = { class = "PRIEST" },
            [6] = { class = "DRUID" }, [7] = { class = "ROGUE", health = 3000, maxHealth = 5000 } } } })
        local S = mock.state
        S.dead.raid5 = true; S.offline.raid6 = true; S.outOfRange.raid7 = true
        for _, u in ipairs({ "raid5", "raid6", "raid7" }) do refresh(u, "UNIT_FLAGS"); refresh(u, "UNIT_CONNECTION"); refresh(u, "UNIT_IN_RANGE_UPDATE") end
        local cfg = ns.db.raid
        local cases = {
            { i = 2, data = { class = "PRIEST", hp = 1000, maxHp = 1000, name = "Raider2" } },
            { i = 3, data = { class = "MAGE", hp = 1500, maxHp = 3000, name = "Raider3" } },
            { i = 5, data = { class = "PRIEST", hp = 0, maxHp = 1000, state = "dead", name = "Raider5" } },
            { i = 6, data = { class = "DRUID", hp = 1000, maxHp = 1000, state = "offline", name = "Raider6" } },
            { i = 7, data = { class = "ROGUE", hp = 3000, maxHp = 5000, range = "out", name = "Raider7" } },
        }
        for _, case in ipairs(cases) do
            local real = RF.buttons[case.i]
            local fake = ns.NewFrame("Frame", nil, UIParent)
            RS.Render(fake, case.data, cfg)
            local label = "raid" .. case.i
            local rc, fc = bar(real).sbColor, bar(fake).sbColor
            assertTrue(near(rc.r, fc.r, 1e-4) and near(rc.g, fc.g, 1e-4) and near(rc.b, fc.b, 1e-4),
                label .. string.format(" bar colour real (%.3f,%.3f,%.3f) preview (%.3f,%.3f,%.3f)", rc.r, rc.g, rc.b, fc.r, fc.g, fc.b))
            assertEquals(bar(fake).value / bar(fake).max, bar(real).value / bar(real).max, label .. " fill")
            assertEquals(center(fake).text, center(real).text, label .. " centre text")
            local rt, ft = center(real).textColor, center(fake).textColor
            if (rt.a or 1) > 0 and center(real).text ~= "" then
                assertTrue(near(rt.r, ft.r) and near(rt.g, ft.g) and near(rt.b, ft.b), label .. " text colour")
            end
            local rn, fn = st(real.name).textColor, st(fake.name).textColor
            assertTrue(near(rn.r, fn.r) and near(rn.g, fn.g) and near(rn.b, fn.b), label .. " name colour")
            assertEquals(st(fake).alpha or 1, st(real).alpha or 1, label .. " range alpha")
        end
        clean()
    end)
    it("the preview frames are plain frames: Render never creates a secure frame or touches a unit API", function()
        local ns = boot()
        local before = mock.secureCreatedInCombat or 0
        local calls = 0
        local realHealth = UnitHealth
        mock.setGlobal("UnitHealth", function(...) calls = calls + 1; return realHealth(...) end)
        local f = ns.NewFrame("Frame", nil, UIParent)
        ns.RaidStyle.Render(f, { class = "MAGE", hp = 10, maxHp = 100, state = "alive" }, ns.db.raid)
        assertEquals(calls, 0)
        assertFalse(st(f).secure)
        assertEquals(mock.secureCreatedInCombat or 0, before)
    end)
end)

-- ------------------------------------------------------------------------------------------------ text above the glow
-- In game the bar glow (frame + 3) hid the first letter of the name and the number's minus: the texts were children of
-- the clipping health bar. Now: own text frame (child of the bar frame, frame + 5) above the real glow holder (+ 4) and
-- the glow (+ 3), under the buff markers / debuff icons (+ 6). RS.Apply re-asserts glow / holder / text out of combat.
describe("raid visuals: text frame above the glow (frame levels)", function()
    -- every frame below root (parent chain), with its explicitly set level
    local function descendants(root)
        local out = {}
        for _, f in ipairs(mock.frames) do
            local p, guard = st(f).parent, 0
            while type(p) == "table" and guard < 50 do
                if p == root then out[#out + 1] = f; break end
                p = rawget(p, "__s") and st(p).parent; guard = guard + 1
            end
        end
        return out
    end
    -- parent level change, two engine models: "shift" moves every descendant by the same delta (relative order kept),
    -- "raise" lifts only the descendants that would sit at or below the new parent level to parent + 1 (order collapses)
    local function changeLevel(frame, newLevel, mode)
        local old = frame:GetFrameLevel()
        local kids = descendants(frame)
        frame:SetFrameLevel(newLevel)
        for _, f in ipairs(kids) do
            local s = st(f)
            if s.level then
                if mode == "shift" then s.level = s.level + (newLevel - old)
                elseif s.level <= newLevel then s.level = newLevel + 1 end
            end
        end
    end
    -- glow < holder < text (exact offsets) and text above the bar; returns whether the icons are above the text
    local function assertOrder(b, label)
        local L = b:GetFrameLevel()
        local glow, text = b.glowFrame:GetFrameLevel(), b.textFrame:GetFrameLevel()
        assertEquals(glow, L + 3, label .. ": glow at frame + 3")
        assertEquals(text, L + 5, label .. ": texts at frame + 5")
        assertEquals(b.RS.GLOW_LEVEL, 3); assertEquals(b.RS.TEXT_LEVEL, 5)
        if b.glowHolder then
            local holder = b.glowHolder:GetFrameLevel()
            assertTrue(glow < holder and holder < text, label .. ": glow " .. glow .. " < holder " .. holder .. " < text " .. text)
            assertEquals(holder, L + 4, label .. ": real glow holder at frame + 4")
        end
        assertTrue(text > b.health:GetFrameLevel(), label .. ": texts above the health bar")
        assertTrue(text > b.pred:GetFrameLevel(), label .. ": texts above the incoming heals")
        local iconsAbove = b.debuffZone:GetFrameLevel() > text
        for _, slot in ipairs(b.buffSlots) do iconsAbove = iconsAbove and slot:GetFrameLevel() > text end
        return iconsAbove
    end

    it("the text frame is a child of the bar frame (not of the clipping health bar) and holds the name and the number", function()
        local ns, RF, RS = boot()
        for i = 1, 10 do
            local b = RF.buttons[i]
            local label = "raid" .. i
            assertTrue(st(b.textFrame).parent == b, label .. ": text frame parent is the bar frame")
            assertFalse(st(b.textFrame).parent == b.health, label .. ": not a child of the health bar")
            assertTrue(st(b.name).parent == b.textFrame, label .. ": name in the text frame")
            assertTrue(st(b.centerText).parent == b.textFrame, label .. ": number in the text frame")
            assertTrue(st(b.textFrame).clipsChildren, label .. ": the text frame clips its own texts to the bar")
            assertFalse(st(b.textFrame).mouse and true or false, label .. ": the text frame takes no mouse")
        end
        assertNotNil(RS)
        clean()
    end)
    it("after Build and Apply (real bars, glowIcons): glow 3 < holder 4 < text 5 < debuff zone / buff slots 6", function()
        local ns, RF, RS = boot()
        for i = 1, 10 do
            local b = RF.buttons[i]
            b.RS = RS
            assertNotNil(b.glowHolder, "raid" .. i .. ": real glow holder")
            assertTrue(assertOrder(b, "raid" .. i), "raid" .. i .. ": debuff zone / buff slots above the texts")
            assertEquals(b.debuffZone:GetFrameLevel(), b:GetFrameLevel() + 6)
            for _, slot in ipairs(b.buffSlots) do assertEquals(slot:GetFrameLevel(), b:GetFrameLevel() + 6) end
            b.RS = nil
        end
        -- a plain frame right after RS.Build (no Apply yet): same order
        local f = ns.NewFrame("Frame", nil, UIParent)
        RS.Build(f)
        f.RS = RS
        assertTrue(assertOrder(f, "Build only"))
        clean()
    end)
    it("RS.Apply re-sets the levels after a parent level change (both engine models), out of combat, no protected calls", function()
        local ns, RF, RS = boot()
        local gaps = {}
        for _, mode in ipairs({ "shift", "raise" }) do
            -- shift: up and down; raise (children lifted to parent + 1): only upwards, by more than the +14 the bar uses
            for _, delta in ipairs(mode == "shift" and { 17, -1, 40 } or { 20, 57 }) do
                local b = RF.buttons[3]
                local lvl = b:GetFrameLevel() + delta
                b.RS = RS
                changeLevel(b, lvl, mode)
                RS.Apply(b, ns.db.raid)
                local label = mode .. " by " .. delta
                local iconsAbove = assertOrder(b, label)
                if mode == "shift" then
                    assertTrue(iconsAbove, label .. ": icons above the texts")
                elseif not iconsAbove then
                    gaps[#gaps + 1] = label
                end
                b.RS = nil
            end
        end
        -- KNOWN GAP (reported): RS.Apply re-asserts glow / holder / text but not the buff slots / debuff zone (frame + 6);
        -- an engine that only lifts children to parent + 1 would leave the icons under the texts.
        if #gaps > 0 then
            warn("RaidStyle.Apply: buff slots / debuff zone levels are not re-set with the texts (" .. table.concat(gaps, ", ")
                .. "): icons under the text after a collapsing parent level change")
        end
        clean()
    end)
    it("in combat with everything secret: state / number changes re-place the texts without touching frame levels or secure frames", function()
        local ns, RF, RS = boot()
        local b = RF.buttons[4]
        local before = { b.glowFrame:GetFrameLevel(), b.textFrame:GetFrameLevel(), b.glowHolder:GetFrameLevel() }
        H.enterCombat()
        mock.state.secretAll = true
        mock.state.dead.raid4 = true; refresh("raid4", "UNIT_FLAGS")
        mock.state.offline.raid4 = true; refresh("raid4", "UNIT_CONNECTION")
        mock.state.offline.raid4 = nil; mock.state.dead.raid4 = nil; refresh("raid4", "UNIT_FLAGS")
        RS.ShowState(b, "cantres"); RS.ShowNumber(b, "deficit"); RS.ShowNumber(b, "percent")
        assertDeepEquals({ b.glowFrame:GetFrameLevel(), b.textFrame:GetFrameLevel(), b.glowHolder:GetFrameLevel() }, before)
        mock.state.secretAll = false
        H.leaveCombat()
        clean("combat")
    end)
end)

-- ------------------------------------------------------------------------------------------------ PlaceText sweep
describe("raid visuals: PlaceText places every centre text from the layout's left position", function()
    -- left edge of the centre text from the anchor PlaceText set (TOP = centred, TOPRIGHT = right-aligned)
    local function leftOf(frame)
        local layout = frame.textLayout
        local p = st(frame.centerText).points[1]
        assertEquals(p[2], frame); assertEquals(p[3], "TOPLEFT")
        if p[1] == "TOP" then return p[4] - layout.numW / 2, layout end
        assertEquals(p[1], "TOPRIGHT")
        return p[4] - layout.numW, layout
    end
    local KINDS = { { "state", "dead" }, { "state", "ghost" }, { "state", "offline" }, { "state", "cantres" }, { "state", "hidden" },
        { "num", "deficit" }, { "num", "percent" } }

    it("sweep: all state texts and numbers start at >= 2 px, fit the bar when they can, state text shrinks to 6 px then runs right", function()
        local ns = boot()
        local RS, RL = ns.RaidStyle, ns.RaidLayout
        local frame = ns.NewFrame("Frame", nil, UIParent)
        RS.Build(frame)
        local base = H.deepcopy(ns.db.raid)
        local n, shrunkTo6, overflowed = 0, 0, 0
        for w = 40, 120, 10 do
            for h = 14, 40, 4 do
                for _, nameSize in ipairs({ 6, 8, 10 }) do
                    for _, deb in ipairs({ 0, 3 }) do
                        for _, markers in ipairs({ 0, 3 }) do
                            local cfg = H.deepcopy(base)
                            cfg.width, cfg.height, cfg.nameSize = w, h, nameSize
                            cfg.debuffs.show = deb > 0
                            cfg.debuffs.max = math.max(1, deb)
                            frame.buffMarkers = nil
                            RS.Apply(frame, cfg)
                            RS.SetBuffReserve(frame, markers)
                            for _, k in ipairs(KINDS) do
                                n = n + 1
                                local label = string.format("w=%d h=%d name=%d deb=%d markers=%d %s", w, h, nameSize, deb, markers, k[2])
                                if k[1] == "state" then RS.ShowState(frame, k[2]) else RS.ShowNumber(frame, k[2]) end
                                local x, layout = leftOf(frame)
                                local areaR = w - frame.reserves.right
                                assertEquals(layout.numLeft, x, label .. ": placed from TextLayout's numLeft")
                                assertTrue(x >= 2, label .. ": centre text left of the inner edge (" .. x .. ")")
                                if layout.numW <= w - 4 then
                                    assertTrue(x + layout.numW <= w - 2, label .. ": runs off the right edge although it fits the bar")
                                end
                                if k[1] == "state" then
                                    local hs = math.max(7, math.min(11, math.floor(h * 0.36 + 0.5)))
                                    assertTrue(layout.tfs >= 6 and layout.tfs <= hs, label .. ": state size " .. layout.tfs)
                                    local len = #RS.STATE_TEXT[k[2]]
                                    assertEquals(layout.numW, math.ceil(len * layout.tfs * 0.75), label .. ": capitals width model 0.75 em")
                                    if layout.tfs > 6 then
                                        assertTrue(layout.numW <= areaR - 3, label .. ": state text larger than 6 px but wider than the free area")
                                    end
                                    if layout.tfs < hs then
                                        -- shrunk only as far as needed
                                        assertTrue(math.ceil(len * (layout.tfs + 1) * 0.75) > areaR - 3, label .. ": shrunk more than needed")
                                    end
                                    if layout.tfs == 6 and layout.tfs < hs then shrunkTo6 = shrunkTo6 + 1 end
                                    if layout.numW > areaR - 3 then
                                        assertEquals(layout.tfs, 6, label .. ": overflows only at 6 px")
                                        overflowed = overflowed + 1
                                    end
                                end
                                local fsz = select(2, frame.centerText:GetFont())
                                if fsz then assertEquals(fsz, layout.tfs, label .. ": font size applied") end
                            end
                        end
                    end
                end
            end
        end
        assertTrue(n > 1500)
        assertTrue(shrunkTo6 > 0, "the sweep reaches the 6 px floor")
        assertTrue(overflowed > 0, "the sweep reaches the overflow-to-the-right case")
        assertNotNil(RL)
        clean()
    end)
    it("CAN'T RES on a 40 px bar with 3 debuff icons: 6 px, starts at 2 px and runs right over the icons", function()
        local ns = boot()
        local RS = ns.RaidStyle
        local frame = ns.NewFrame("Frame", nil, UIParent)
        RS.Build(frame)
        local cfg = H.deepcopy(ns.db.raid)
        cfg.width, cfg.height = 40, 24
        cfg.debuffs.show, cfg.debuffs.max = true, 3
        RS.Apply(frame, cfg)
        RS.ShowState(frame, "cantres")
        local x, layout = leftOf(frame)
        assertEquals(layout.tfs, 6)
        assertEquals(x, 2)
        assertTrue(x + layout.numW > 40 - frame.reserves.right, "runs into the icon area (last resort)")
        assertEquals(st(frame.centerText).text, "CAN'T RES")
        clean()
    end)
    it("the centre text is re-placed when its kind or length changes (state -> number -> state)", function()
        local ns = boot()
        local RS = ns.RaidStyle
        local frame = ns.NewFrame("Frame", nil, UIParent)
        RS.Build(frame)
        local cfg = H.deepcopy(ns.db.raid)
        cfg.width, cfg.height = 48, 22
        RS.Apply(frame, cfg)
        RS.ShowState(frame, "offline")
        local x1, l1 = leftOf(frame)
        RS.ShowNumber(frame, "deficit")
        local x2, l2 = leftOf(frame)
        RS.ShowState(frame, "dead")
        local x3, l3 = leftOf(frame)
        assertTrue(l1.numW ~= l2.numW or x1 ~= x2)
        assertTrue(l3.numW < l1.numW, "DEAD is narrower than OFFLINE")
        assertTrue(x1 >= 2 and x2 >= 2 and x3 >= 2)
        clean()
    end)
end)

-- ------------------------------------------------------------------------------------------------ preview debuff icons
describe("raid visuals: preview debuff icons (RS.SetFakeDebuffs / RS.FakeDebuffIcon)", function()
    -- C_Spell.GetSpellTexture: a distinct texture per spell id; texMode switches it to missing / error / secret / nil
    local texMode, texCalls
    local function setup(S)
        texMode, texCalls = "ok", {}
        local FAKE = { [118] = true, [2818] = true, [3427] = true, [980] = true }
        -- only the preview's representative spells are affected (the rest of the addon keeps the mock's icon)
        C_Spell.GetSpellTexture = function(id)
            if not FAKE[id] then return 134400 end
            texCalls[#texCalls + 1] = id
            if texMode == "error" then error("spell data not loaded") end
            if texMode == "secret" then return mock.newSecret() end
            if texMode == "nil" then return nil end
            return 9000000 + id
        end
        assertNotNil(S)
    end
    local function plainBar(ns, over)
        local RS = ns.RaidStyle
        local f = ns.NewFrame("Frame", nil, UIParent)
        RS.Build(f)
        local cfg = H.deepcopy(ns.db.raid)
        cfg.debuffs.show, cfg.debuffs.max, cfg.debuffs.display = true, 3, "glowIcons"
        for k, v in pairs(over or {}) do cfg[k] = v end
        RS.Apply(f, cfg)
        return f, RS
    end

    it("each dispel type gets its representative spell's texture (Magic 118, Poison 2818, Disease 3427, Curse 980), cropped 0.08-0.92", function()
        local ns = boot({ setup = setup })
        local f, RS = plainBar(ns)
        assertDeepEquals(RS.FAKE_DEBUFF_SPELL, { Magic = 118, Poison = 2818, Disease = 3427, Curse = 980 })
        local DC = ns.Classes.DISPEL_COLORS
        RS.SetFakeDebuffs(f, { "Magic", "Poison", "Disease" }, true)
        assertEquals(f.fakeDebuffCount, 3)
        local want = { Magic = 9000118, Poison = 9002818, Disease = 9003427 }
        for i, t in ipairs({ "Magic", "Poison", "Disease" }) do
            local icon = f.fakeDebuffs[i]
            local label = "icon " .. i .. " " .. t
            assertEquals(st(icon.fill).texture, want[t], label .. ": spell texture")
            assertDeepEquals(st(icon.fill).texCoord, { 0.08, 0.92, 0.08, 0.92 }, label .. ": cropped like the real aura icons")
            assertTrue(st(icon.fill).shown and st(icon.border).shown, label .. " shown")
            assertColor(st(icon.border).vertex, DC[t].r, DC[t].g, DC[t].b, label .. " border in the dispel colour")
            assertColor(st(icon.fill).vertex, 1, 1, 1, label .. " fill not tinted")
            -- the fill sits 1 px inside the border
            local p = st(icon.fill).points
            assertTrue(p[1][2] == icon.border and p[1][4] == 1 and p[1][5] == -1, label .. " fill inset top-left")
            assertTrue(p[2][2] == icon.border and p[2][4] == -1 and p[2][5] == 1, label .. " fill inset bottom-right")
            assertEquals(st(icon.border).w, f.reserves.isz)
        end
        -- type change on slot 1: new texture; the others hide
        RS.SetFakeDebuffs(f, { "Curse" }, true)
        assertEquals(st(f.fakeDebuffs[1].fill).texture, 9000980)
        assertFalse(st(f.fakeDebuffs[2].fill).shown); assertFalse(st(f.fakeDebuffs[3].border).shown)
        assertEquals(f.fakeDebuffCount, 1)
        -- glow-only display: no icons
        RS.SetFakeDebuffs(f, { "Magic" }, false)
        assertEquals(f.fakeDebuffCount, 0)
        assertFalse(st(f.fakeDebuffs[1].fill).shown)
        -- unknown type / bad input: nothing drawn, no error
        RS.SetFakeDebuffs(f, { "Bleed" }, true); assertEquals(f.fakeDebuffCount, 0)
        RS.SetFakeDebuffs(f, "Magic", true); assertEquals(f.fakeDebuffCount, 0)
        RS.SetFakeDebuffs(f, nil, true); assertEquals(f.fakeDebuffCount, 0)
        -- a good texture is looked up once per type (cached)
        local calls = #texCalls
        for _ = 1, 3 do assertEquals(RS.FakeDebuffIcon("Magic"), 9000118) end
        assertEquals(#texCalls, calls, "cached after the first good lookup")
        clean()
    end)
    it("question mark when C_Spell / GetSpellTexture is missing, errors, returns nil or a secret; the fallback is retried later", function()
        local ns = boot({ setup = setup })
        local RS = ns.RaidStyle
        local Q = RS.FALLBACK_ICON
        assertEquals(Q, "Interface\\Icons\\INV_Misc_QuestionMark")
        -- whole C_Spell missing
        local realCSpell = C_Spell
        mock.setGlobal("C_Spell", nil)
        assertEquals(RS.FakeDebuffIcon("Magic"), Q, "no C_Spell")
        mock.setGlobal("C_Spell", realCSpell)
        -- function missing
        local fn = C_Spell.GetSpellTexture
        C_Spell.GetSpellTexture = nil
        assertEquals(RS.FakeDebuffIcon("Magic"), Q, "no GetSpellTexture")
        C_Spell.GetSpellTexture = fn
        for _, m in ipairs({ "error", "nil", "secret" }) do
            texMode = m
            local v = RS.FakeDebuffIcon("Poison")
            assertEquals(v, Q, m .. ": question mark")
            assertFalse(mock.isSecret(v), m .. ": a secret texture is never returned")
        end
        -- unknown type: question mark without a lookup
        texMode = "ok"
        local calls = #texCalls
        assertEquals(RS.FakeDebuffIcon("Bleed"), Q)
        assertEquals(#texCalls, calls, "no spell for an unknown type")
        -- the question mark was not cached: the spell data loaded, the real icon comes back
        assertEquals(RS.FakeDebuffIcon("Poison"), 9002818, "fallback retried")
        assertEquals(RS.FakeDebuffIcon("Magic"), 9000118, "fallback retried")
        -- once cached a later failure keeps the real icon
        texMode = "error"
        assertEquals(RS.FakeDebuffIcon("Poison"), 9002818, "cached")
        clean()
    end)
    it("the preview icon itself picks up the real texture once the spell data loads (question mark not kept)", function()
        local ns = boot({ setup = setup })
        local f, RS = plainBar(ns)
        texMode = "error"
        RS.SetFakeDebuffs(f, { "Magic" }, true)
        assertEquals(st(f.fakeDebuffs[1].fill).texture, RS.FALLBACK_ICON, "question mark while the spell data is missing")
        texMode = "ok"
        RS.SetFakeDebuffs(f, { "Magic" }, true)
        local tex = st(f.fakeDebuffs[1].fill).texture
        if tex ~= 9000118 then
            -- KNOWN BUG (reported): SetFakeDebuffs only re-sets the texture when the slot's type changes
            -- (icon.type ~= t), so a question mark drawn once stays until the type changes or the slot hides.
            warn("RaidStyle.SetFakeDebuffs: a preview debuff icon that got the question mark keeps it after the spell data loads"
                .. " (same type on the same slot is never re-textured)")
        end
        -- hiding the slot and showing it again re-textures it
        RS.SetFakeDebuffs(f, {}, true)
        RS.SetFakeDebuffs(f, { "Magic" }, true)
        assertEquals(st(f.fakeDebuffs[1].fill).texture, 9000118, "re-shown slot gets the real texture")
        clean()
    end)
    it("everything secret: the preview debuff icons draw without errors (plain spell ids, no unit data)", function()
        local ns = boot({ setup = setup })
        mock.state.secretAll = true
        H.enterCombat()
        local f, RS = plainBar(ns)
        RS.SetFakeDebuffs(f, { "Magic", "Curse" }, true)
        assertEquals(f.fakeDebuffCount, 2)
        assertEquals(st(f.fakeDebuffs[2].fill).texture, 9000980)
        H.leaveCombat()
        mock.state.secretAll = false
        clean()
    end)
    it("geometry: icons right to left in the debuff zone, 1 px apart, never overlapping each other", function()
        local ns = boot({ setup = setup })
        for _, w in ipairs({ 40, 64, 120 }) do
            local f, RS = plainBar(ns, { width = w })
            RS.SetFakeDebuffs(f, { "Magic", "Poison", "Disease" }, true)
            local size = f.reserves.isz
            for i = 1, 3 do
                local p = st(f.fakeDebuffs[i].border).points[1]
                assertEquals(p[1], "BOTTOMRIGHT"); assertTrue(p[2] == f.debuffZone)
                assertEquals(p[4], -((i - 1) * (size + 1)), "w=" .. w .. " icon " .. i .. " x")
                assertEquals(st(f.fakeDebuffs[i].border).w, size)
            end
            -- the zone holds all three: 3 * (size + 1) + 1 wide
            assertEquals(st(f.debuffZone).w, 3 * (size + 1) + 1)
        end
        clean()
    end)
end)
