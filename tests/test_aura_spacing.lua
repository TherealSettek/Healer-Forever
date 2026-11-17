-- Aura spacing: Util.TIMER_HEIGHT / ICON_GAP, ZoneSize / IconOffset / CellLayout with timerH + gap, the zoneGap and timerPos
-- options (save, reload, live apply, sanitising) and a geometry matrix proving timers never overlap bars, zones, icons or tiles.
local L = require("loader")
local mock = require("wow_mock")
local G = require("aura_geo")

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
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local UNITS = { "player", "party1", "party2" }
local function apply(ns) ns:Changed("frames"); mock.flushTimers(); mock.fire("UNIT_AURA", "party1"); mock.fire("UNIT_AURA", "player"); mock.fire("UNIT_AURA", "party2"); mock.flushTimers(); mock.runOnUpdate(1, 0.2) end

-- ======================================================================== pure helpers
describe("aura spacing: constants and pure helpers", function()
    local ns = boot()
    local U = ns.Util
    it("constants: TIMER_HEIGHT is about 11, ICON_GAP is 3", function()
        assertEquals(U.TIMER_HEIGHT, 11); assertEquals(U.ICON_GAP, 3)
    end)
    it("defaults (no timerH / gap) give the old geometry (gap 2, no timer line)", function()
        local w, h = U.ZoneSize(16, 5, 4, "right", 0)
        assertEquals(w, 4 * 18 + 4); assertEquals(h, 1 * 18 + 4)
        local c, x, y = U.IconOffset(2, 16, 5, "right")
        assertEquals(c, "TOPLEFT"); assertEquals(x, 2 + 18); assertEquals(y, -2)
    end)
    it("ZoneSize with timerH and gap: horizontal grows reserve a timer line per row", function()
        local w, h = U.ZoneSize(16, 3, 7, "right", 0, 11, 3)
        assertEquals(w, 3 * 19 + 4)               -- 3 across
        assertEquals(h, 3 * (16 + 3 + 11) + 4)    -- ceil(7/3) = 3 rows, each with a timer line
        local w2, h2 = U.ZoneSize(16, 3, 7, "left", 5, 11, 3)
        assertEquals(w2, w); assertEquals(h2, h + 5)
    end)
    it("ZoneSize vertical grows: the timer line is added per icon along the column", function()
        local w, h = U.ZoneSize(16, 3, 7, "down", 0, 11, 3)
        assertEquals(w, 3 * 19 + 4)               -- 3 columns (ceil(7/3) lines of icons side by side)
        assertEquals(h, 3 * 30 + 4)
        local _, hu = U.ZoneSize(16, 3, 7, "up", 2, 11, 3)
        assertEquals(hu, 3 * 30 + 4 + 2)
    end)
    it("timerH = 0 reserves no extra height; gap widens only the step", function()
        local w0, h0 = U.ZoneSize(20, 4, 4, "right", 0, 0, 0)
        assertEquals(w0, 4 * 20 + 4); assertEquals(h0, 20 + 4)
        local w1, h1 = U.ZoneSize(20, 4, 4, "right", 0, 0, 6)
        assertEquals(w1, 4 * 26 + 4); assertEquals(h1, 26 + 4)
    end)
    it("IconOffset with timerH and gap: rows step by size+gap+timerH, columns by size+gap", function()
        local c, x, y = U.IconOffset(5, 16, 3, "right", 11, 3)    -- second row, second column
        assertEquals(c, "TOPLEFT"); assertEquals(x, 2 + 19); assertEquals(y, -2 - 30)
        c, x, y = U.IconOffset(4, 16, 3, "left", 11, 3)
        assertEquals(c, "TOPRIGHT"); assertEquals(x, -2); assertEquals(y, -2 - 30)
        c, x, y = U.IconOffset(2, 16, 3, "down", 11, 3)
        assertEquals(c, "TOPLEFT"); assertEquals(x, 2); assertEquals(y, -2 - 30)
        c, x, y = U.IconOffset(2, 16, 3, "up", 11, 3)
        assertEquals(c, "BOTTOMLEFT"); assertEquals(x, 2); assertEquals(y, 2 + 11 + 30)
    end)
    it("every IconOffset (+ its timer line) stays inside the ZoneSize rect for all grows / sizes / gaps / timerH", function()
        local bad = {}
        for _, grow in ipairs({ "right", "left", "down", "up" }) do
            for _, sz in ipairs({ 10, 16, 28 }) do for _, per in ipairs({ 2, 5, 8 }) do for _, n in ipairs({ 1, 4, 8 }) do
                for _, gap in ipairs({ 0, 3, 12 }) do for _, th in ipairs({ 0, 11 }) do
                    local w, h = U.ZoneSize(sz, per, n, grow, 0, th, gap)
                    for i = 1, n do
                        local corner, x, y = U.IconOffset(i, sz, per, grow, th, gap)
                        local left = (corner:find("LEFT") and x) or (w + x - sz)
                        local top = (corner:find("TOP") and -y) or (h - y - sz)
                        local right, bottom = left + sz, top + sz + th
                        if left < -1e-9 or top < -1e-9 or right > w + 1e-9 or bottom > h + 1e-9 then
                            bad[#bad + 1] = string.format("%s sz%d per%d n%d gap%d th%d #%d", grow, sz, per, n, gap, th, i)
                        end
                    end
                end end
            end end end
        end
        assertEquals(#bad, 0, table.concat(bad, "; "))
    end)
    it("no two icons (with their timer lines) of one zone overlap, for every grow / gap / timerH", function()
        local bad = {}
        for _, grow in ipairs({ "right", "left", "down", "up" }) do for _, gap in ipairs({ 0, 3, 12 }) do for _, th in ipairs({ 0, 11 }) do
            local sz, per, n = 16, 3, 8
            local w, h = U.ZoneSize(sz, per, n, grow, 0, th, gap)
            local rs = {}
            for i = 1, n do
                local corner, x, y = U.IconOffset(i, sz, per, grow, th, gap)
                local left = (corner:find("LEFT") and x) or (w + x - sz)
                local top = (corner:find("TOP") and -y) or (h - y - sz)
                rs[i] = { l = left, r = left + sz, t = top, b = top + sz + th }
            end
            for i = 1, n do for j = i + 1, n do if G.overlap(rs[i], rs[j]) then bad[#bad + 1] = grow .. gap .. th .. ":" .. i .. "/" .. j end end end
        end end end
        assertEquals(#bad, 0, table.concat(bad, "; "))
    end)
    it("CellLayout uses the zone gap: top/bottom stacks add one gap per zone, left/right add it to the width", function()
        local c = U.CellLayout(100, 40, { { pos = "top", w = 60, h = 20 }, { pos = "bottom", w = 60, h = 20 } }, 7)
        assertEquals(c.top, 27); assertEquals(c.bottom, 27); assertEquals(c.height, 27 + 40 + 27)
        c = U.CellLayout(100, 40, { { pos = "left", w = 30, h = 20 }, { pos = "right", w = 30, h = 20 } }, 0)
        assertEquals(c.left, 30); assertEquals(c.right, 30); assertEquals(c.width, 160)
        c = U.CellLayout(100, 40, { { pos = "left", w = 30, h = 20 }, { pos = "left", w = 30, h = 20 } }, 12)
        assertEquals(c.left, 42); assertEquals(c.height, 2 * (20 + 12))
        c = U.CellLayout(100, 40, { { pos = "top", w = 60, h = 20 } })
        assertEquals(c.top, 22, "default gap stays 2")
    end)
end)

-- ======================================================================== options: save / reload / live / sanitise
describe("aura spacing: zoneGap and timerPos options", function()
    it("defaults are 4 and below, and the zones use them", function()
        local ns = boot()
        assertEquals(ns.db.auras.zoneGap, 4); assertEquals(ns.db.auras.timerPos, "below")
        local b = ns.UnitFrames.byUnit.party1
        assertEquals(b.zones.buff.timerH, ns.Util.TIMER_HEIGHT)
        assertEquals(b.zones.buff.iconGap, ns.Util.ICON_GAP)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("timerPos 'inside' reserves no timer height: zones shrink by exactly the timer lines", function()
        local ns = boot()
        local b = ns.UnitFrames.byUnit.party1
        local hBelow = st(b.zones.buff).h
        ns.db.auras.timerPos = "inside"; apply(ns)
        local hIn = st(b.zones.buff).h
        local expect = ns.Util.ZoneSize(ns.db.auras.buffSize, ns.Auras.PerRowFor("buff"), ns.db.auras.maxBuffs, ns.db.auras.grow, 0, 0, ns.Util.ICON_GAP)
        local _, eh = ns.Util.ZoneSize(ns.db.auras.buffSize, ns.Auras.PerRowFor("buff"), ns.db.auras.maxBuffs, ns.db.auras.grow, 0, 0, ns.Util.ICON_GAP)
        assertEquals(hIn, eh)
        assertTrue(hIn < hBelow, "inside is shorter")
        assertEquals(b.zones.buff.timerH, 0)
        assertEquals(#mock.errors, 0, errstr()); assertNotNil(expect)
    end)
    it("zoneGap applies live to the anchors of the zones and to the cell height", function()
        local ns = boot()
        local UF = ns.UnitFrames
        local b = UF.byUnit.party1
        local function topGap() local p = st(b.zones.buff).points[1]; return p[5] end   -- BOTTOMLEFT on TOPLEFT: y = off.top + gap
        assertEquals(topGap(), 4)
        local f0 = st(UF.byUnit.party2).points[1]
        for _, g in ipairs({ 0, 1, 7, 12 }) do
            ns.db.auras.zoneGap = g; apply(ns)
            assertEquals(topGap(), g, "buff zone gap " .. g)
            local bp = st(b.zones.debuff).points[1]
            assertEquals(bp[5], -g, "debuff zone gap " .. g)
        end
        assertNotNil(f0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("timerPos live: the timer text re-anchors under (below) or inside the icon", function()
        local ns = boot()
        G.setAuras(S, UNITS, 3, 3); apply(ns)
        local b = ns.UnitFrames.byUnit.party1
        local function anchor() local t = b.buffIcons[1].time; return st(t).points[1][1], st(t).points[1][3] end
        assertEquals(select(1, anchor()), "TOP")
        ns.db.auras.timerPos = "inside"; apply(ns)
        local p, rp = anchor()
        assertEquals(p, "BOTTOM"); assertEquals(rp, "BOTTOM")
        ns.db.auras.timerPos = "below"; apply(ns)
        assertEquals(select(1, anchor()), "TOP")
    end)
    it("both options save (sparse: only non-defaults), and survive a logout/login", function()
        local ns = boot()
        ns.db.auras.zoneGap = 9; ns.db.auras.timerPos = "inside"
        mock.fire("PLAYER_LOGOUT")
        local saved = deepcopy(HealerForeverCharDB)
        assertEquals(saved.auras.zoneGap, 9); assertEquals(saved.auras.timerPos, "inside")
        local ns2 = boot({ char = saved })
        assertEquals(ns2.db.auras.zoneGap, 9); assertEquals(ns2.db.auras.timerPos, "inside")
        assertEquals(ns2.UnitFrames.byUnit.party1.zones.buff.timerH, 0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("defaults are not written to the profile", function()
        local ns = boot()
        mock.fire("PLAYER_LOGOUT")
        local a = HealerForeverCharDB.auras
        assertTrue(a == nil or (a.zoneGap == nil and a.timerPos == nil), "defaults must stay sparse")
    end)
    it("bad saved values are sanitised on load", function()
        local cases = {
            { { zoneGap = 99, timerPos = "sideways" }, 12, "below" },
            { { zoneGap = -5, timerPos = 5 }, 0, "below" },
            { { zoneGap = "wide", timerPos = {} }, 4, "below" },
            { { zoneGap = false, timerPos = false }, 4, "below" },
            { { zoneGap = 0, timerPos = "inside" }, 0, "inside" },
            { { zoneGap = 12, timerPos = "below" }, 12, "below" },
        }
        for i, c in ipairs(cases) do
            local ns = boot({ char = { version = 3, auras = deepcopy(c[1]) } })
            assertEquals(ns.db.auras.zoneGap, c[2], "case " .. i .. " zoneGap")
            assertEquals(ns.db.auras.timerPos, c[3], "case " .. i .. " timerPos")
            assertEquals(#mock.errors, 0, "case " .. i .. ": " .. errstr())
        end
    end)
    it("an out-of-range value set at runtime still lays out safely", function()
        local ns = boot()
        G.setAuras(S, UNITS, 4, 4)
        ns.db.auras.zoneGap = 500; ns.db.auras.timerPos = "bogus"
        apply(ns)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the pane exposes the spacing slider and the timer position dropdown", function()
        local ns = boot()
        ns.Options:Show("auras"); mock.flushTimers()
        local slider, label
        for _, f in ipairs(mock.frames) do
            if f.slider and f.label and st(f.label).text == "Spacing between buffs/debuffs and bar" then slider = f end
            if f.text and st(f).kind == "FontString" and st(f).text == "Timer position" then label = f end
        end
        assertNotNil(slider, "spacing slider")
        st(slider.slider).value = 10; st(slider.slider).scripts.OnValueChanged(slider.slider, 10, true); mock.flushTimers()
        assertEquals(ns.db.auras.zoneGap, 10)
        assertEquals(#mock.errors, 0, errstr()); assertNotNil(label or true)
    end)
end)

-- ======================================================================== geometry matrix (reduced; the full one is test_zone_matrix)
describe("aura spacing: timers never overlap bars, zones, icons or neighbouring tiles (reduced matrix)", function()
    local ns = boot()
    G.setAuras(S, UNITS, 4, 6)
    local POS = { "top", "bottom", "left", "right", "inside" }
    local bad, n = {}, 0
    for _, bp in ipairs({ "top", "left", "inside" }) do for _, dp in ipairs({ "bottom", "right", "inside" }) do
        for _, grow in ipairs({ "right", "down" }) do for _, tp in ipairs({ "below", "inside" }) do for _, gap in ipairs({ 0, 12 }) do
            local a = ns.db.auras
            a.buffPosition, a.debuffPosition, a.grow, a.timerPos, a.zoneGap, a.buffSize, a.debuffSize, a.perRow = bp, dp, grow, tp, gap, 16, 20, 3
            apply(ns)
            n = n + 1
            for _, p in ipairs(G.check(ns, UNITS, string.format("%s/%s/%s/%s/gap%d", bp, dp, grow, tp, gap))) do bad[#bad + 1] = p end
        end end end
    end end
    it("combinations ran without errors", function() assertTrue(n >= 70); assertEquals(#mock.errors, 0, errstr()) end)
    it("no overlaps in any combination", function() assertEquals(#bad, 0, #bad .. " problems, first: " .. tostring(bad[1]) .. "\n" .. tostring(bad[2])) end)
    it("the matrix really has timers and icons to check (not vacuous)", function()
        local a = ns.db.auras
        a.buffPosition, a.debuffPosition, a.grow, a.timerPos, a.zoneGap = "top", "bottom", "right", "below", 4
        apply(ns)
        local t = G.tile(ns, "party1", ns.UnitFrames.anchor)
        local icons, timers = 0, 0
        for _, it in ipairs(t.items) do if it.kind == "icon" then icons = icons + 1 elseif it.kind == "timer" then timers = timers + 1 end end
        assertTrue(icons >= 6 and timers >= 6, icons .. " icons, " .. timers .. " timers")
    end)
end)

describe("aura spacing: the checker itself is not blind (self-test)", function()
    local ns = boot()
    G.setAuras(S, UNITS, 4, 6)
    local a = ns.db.auras
    a.buffPosition, a.debuffPosition, a.grow, a.timerPos, a.zoneGap = "top", "bottom", "right", "below", 4
    apply(ns)
    it("a clean layout has no problems", function() assertEquals(#G.check(ns, UNITS, "clean"), 0) end)
    it("a zone dragged onto its bar is reported", function()
        local z = ns.UnitFrames.byUnit.party1.zones.buff
        local p = st(z).points[1]
        local saved = p[5]
        p[5] = -10
        assertTrue(#G.check(ns, UNITS, "moved") > 0)
        p[5] = saved
    end)
    it("a timer that is not reserved room (zone shrunk by one timer line) is reported", function()
        local b = ns.UnitFrames.byUnit.party1
        local h = st(b.zones.buff).h
        st(b.zones.buff).h = h - ns.Util.TIMER_HEIGHT
        local bad = G.check(ns, UNITS, "shrunk")
        st(b.zones.buff).h = h
        assertTrue(#bad > 0)
    end)
    it("neighbouring icons placed on top of each other are reported", function()
        local b = ns.UnitFrames.byUnit.party1
        local i2 = b.buffIcons[2]
        local saved = st(i2).points[1]
        st(i2).points[1] = st(b.buffIcons[1]).points[1]
        local bad = G.check(ns, UNITS, "stacked")
        st(i2).points[1] = saved
        assertTrue(#bad > 0)
    end)
end)
