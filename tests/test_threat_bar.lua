-- Threat bar on the party frames (style A "level strip", decisions.md "Threat bar on party frames"):
-- frames.showThreatBar / threatBarHeight / threatBarOnlyCombat / threatBarShowSafe (green for level 0). Covers the colours (GetThreatStatusColor and its fallback),
-- defaults, sanitizing bad saved values, sparse save and reload, an older 0.10.1 save, geometry (reserve above the health bar,
-- pets and the raid layout untouched, no overlaps), the level -> colour mapping, dead / offline / not visible, "Only in combat",
-- secret threat (and everything secret), toggling in combat (no protected calls) and range dimming (readable and secret).
local mock = require("wow_mock")
local H = require("raid_helpers")
local Fx = require("fixtures")
local L = require("loader")
local G = require("aura_geo")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local st, deepcopy = H.st, H.deepcopy
local FIXTURE = HF_TESTS .. "/fixtures/settings-v0.10.1.lua"
local MEMBERS = { "player", "party1", "party2", "party3", "party4" }
local FALLBACK = { { 1, 1, 0.47 }, { 1, 0.6, 0 }, { 1, 0, 0 } }
local THREAT_KEYS = { "showThreatBar", "threatBarHeight", "threatBarOnlyCombat", "threatBarShowSafe" }
local SAFE = { 0.25, 0.8, 0.3 }

local function clean(label)
    assertEquals(#mock.errors, 0, (label or "") .. " errors:\n" .. H.errstr())
    assertEquals(H.violations(), "", (label or "") .. ": protected calls in combat")
end
local function errorLogEmpty(ns)
    local n = type(ns.db.errorLog) == "table" and #ns.db.errorLog or 0
    assertEquals(n, 0, "errorLog: " .. (n > 0 and tostring(ns.db.errorLog[1].message or ns.db.errorLog[1].text) or ""))
end

local PARTY_WITH_PET = {}
for k, v in pairs(H.PARTY) do PARTY_WITH_PET[k] = v end
PARTY_WITH_PET.partypet1 = H.unit("Wolfie", "WARRIOR", nil, 300, 400)

-- Boots with the threat bar on (unless opts.on == false). opts.frames = extra saved frames keys.
local function boot(opts)
    opts = opts or {}
    local char = opts.char
    if not char then
        char = { version = 4, frames = { showThreatBar = opts.on ~= false } }
        for k, v in pairs(opts.frames or {}) do char.frames[k] = v end
    end
    return H.boot({ group = 4, char = char, party = opts.party or PARTY_WITH_PET, setup = opts.setup, raid = opts.raid })
end

local function btn(ns, u) return ns.UnitFrames.byUnit[u] end
local function stripShown(b) return b.threatStrip ~= nil and st(b.threatStrip).shown == true end
local function edgeShown(b) return b.threatEdge ~= nil and st(b.threatEdge).shown == true end
local function colorOf(b) local v = st(b.threatStrip).vertex; return v and { v.r, v.g, v.b } end
local function sameColor(c, want) return c ~= nil and math.abs(c[1] - want[1]) < 1e-6 and math.abs(c[2] - want[2]) < 1e-6 and math.abs(c[3] - want[3]) < 1e-6 end
local function setThreat(u, level)
    local S = mock.state
    S.threat = S.threat or {}
    S.threat[u] = level
    mock.fire("UNIT_THREAT_SITUATION_UPDATE", u); mock.flushTimers()
end
local function apply(ns) ns:Changed("frames"); mock.flushTimers() end
local function save() mock.fire("PLAYER_LOGOUT"); return deepcopy(_G.HealerForeverCharDB) end
local function healthY(b) local p = st(b.health).points[1]; return p[3] end
local function margin(ns) return ns.Util.BorderSpec(ns.db.frames.border.style, ns.db.frames.border.width).outset + 2 end

-- =====================================================================================================================
describe("threat bar: colours from GetThreatStatusColor", function()
    it("the mock answers readable r, g, b for 1..3 like the client (and nil outside 0..3)", function()
        mock.install()
        for level = 1, 3 do
            local r, g, b = GetThreatStatusColor(level)
            assertTrue(type(r) == "number" and type(g) == "number" and type(b) == "number", "level " .. level)
            assertTrue(sameColor({ r, g, b }, FALLBACK[level]), "level " .. level .. " = the client's colour")
        end
        assertNil((GetThreatStatusColor(9)))
        mock.uninstall()
    end)
    it("the game's colours are used when it answers (read at load)", function()
        local custom = { { 0.1, 0.2, 0.3 }, { 0.4, 0.5, 0.6 }, { 0.7, 0.8, 0.9 } }
        local ns = boot({ setup = function(S) S.threatColors = custom end })
        clean()
        for level = 1, 3 do assertTrue(sameColor(ns.UnitFrames.THREAT_COLORS[level], custom[level]), "level " .. level) end
        ns.db.frames.threatBarOnlyCombat = false; apply(ns)
        setThreat("party1", 2)
        assertTrue(sameColor(colorOf(btn(ns, "party1")), custom[2]), "the strip is painted with the game's colour")
    end)
    local cases = {
        { "missing (no GetThreatStatusColor at all)", function() mock.setGlobal("GetThreatStatusColor", nil) end },
        { "answers secret values", function(S) S.threatColorsSecret = true end },
        { "raises an error", function(S) S.threatColorsError = true end },
        { "answers nothing", function() mock.setGlobal("GetThreatStatusColor", function() return nil end) end },
        { "answers strings", function() mock.setGlobal("GetThreatStatusColor", function() return "1", "0", "0" end) end },
        { "answers only r", function() mock.setGlobal("GetThreatStatusColor", function() return 0.5 end) end },
    }
    for _, c in ipairs(cases) do
        it("falls back to fixed yellow / orange / red when the API " .. c[1], function()
            local ns = boot({ setup = c[2], frames = { threatBarOnlyCombat = false } })
            clean(c[1])
            for level = 1, 3 do
                assertTrue(sameColor(ns.UnitFrames.THREAT_COLORS[level], FALLBACK[level]), c[1] .. " level " .. level)
            end
            setThreat("party2", 3)
            assertTrue(stripShown(btn(ns, "party2")))
            assertTrue(sameColor(colorOf(btn(ns, "party2")), FALLBACK[3]))
            clean(c[1])
        end)
    end
end)

-- =====================================================================================================================
describe("threat bar: settings defaults and sanitizing", function()
    it("defaults: off, 3 px, only in combat (DEFAULTS and a fresh character)", function()
        local ns = H.boot({ group = 4 })
        assertEquals(ns.DEFAULTS.frames.showThreatBar, false)
        assertEquals(ns.DEFAULTS.frames.threatBarHeight, 3)
        assertEquals(ns.DEFAULTS.frames.threatBarOnlyCombat, true)
        assertEquals(ns.db.frames.showThreatBar, false)
        assertEquals(ns.db.frames.threatBarHeight, 3)
        assertEquals(ns.db.frames.threatBarOnlyCombat, true)
        assertEquals(ns.DEFAULTS.version, 4, "no schema bump")
        clean()
    end)
    it("bar heights are clamped to 2..6 and rounded: 1, 7, \"x\", 3.6 load as 2, 6, 3, 4", function()
        for _, c in ipairs({ { 1, 2 }, { 7, 6 }, { "x", 3 }, { 3.6, 4 }, { 0 / 0, 3 }, { -5, 2 }, { 99, 6 }, { 2.5, 3 }, { 5.49, 5 },
            { 4, 4 }, { true, 3 }, { { 5 }, 3 } }) do
            local ns = boot({ frames = { threatBarHeight = c[1] } })
            assertEquals(ns.db.frames.threatBarHeight, c[2], "saved " .. tostring(c[1]))
            assertEquals(math.floor(ns.db.frames.threatBarHeight), ns.db.frames.threatBarHeight, "a whole number")
            clean()
        end
    end)
    it("wrong types for the switches fall back to their defaults", function()
        local ns = H.boot({ group = 4, char = { version = 4, frames = { showThreatBar = "yes", threatBarOnlyCombat = 0 } } })
        assertEquals(ns.db.frames.showThreatBar, false)
        assertEquals(ns.db.frames.threatBarOnlyCombat, true)
        clean()
        ns = H.boot({ group = 4, char = { version = 4, frames = { showThreatBar = true, threatBarOnlyCombat = false } } })
        assertEquals(ns.db.frames.showThreatBar, true, "a good value is kept")
        assertEquals(ns.db.frames.threatBarOnlyCombat, false)
        clean()
    end)
end)

-- =====================================================================================================================
describe("threat bar: sparse save and reload", function()
    it("untouched threat settings are not written", function()
        local ns = H.boot({ group = 4 })
        local out = save(ns)
        for _, k in ipairs(THREAT_KEYS) do assertNil(out.frames and out.frames[k], k .. " written although unchanged") end
    end)
    it("one changed key saves only that key (nothing else in the save changes)", function()
        local ns = H.boot({ group = 4 })
        local before = ns:BuildSaveTable()
        ns.db.frames.threatBarHeight = 5
        local after = ns:BuildSaveTable()
        assertEquals(after.frames.threatBarHeight, 5)
        after.frames.threatBarHeight = nil
        if next(after.frames) == nil then after.frames = nil end
        assertDeepEquals(after, before, "only frames.threatBarHeight differs")
        ns.db.frames.threatBarHeight = 3
        ns.db.frames.showThreatBar = true
        after = ns:BuildSaveTable()
        assertEquals(after.frames.showThreatBar, true)
        assertNil(after.frames.threatBarHeight); assertNil(after.frames.threatBarOnlyCombat)
    end)
    it("save -> reload keeps the values and they apply (strip on, 5 px, also out of combat)", function()
        local ns = H.boot({ group = 4, party = PARTY_WITH_PET })
        ns.db.frames.showThreatBar = true; ns.db.frames.threatBarHeight = 5; ns.db.frames.threatBarOnlyCombat = false
        apply(ns)
        local saved = save(ns)
        assertEquals(saved.frames.showThreatBar, true); assertEquals(saved.frames.threatBarHeight, 5); assertEquals(saved.frames.threatBarOnlyCombat, false)
        local ns2 = H.boot({ group = 4, char = saved, party = PARTY_WITH_PET })
        clean()
        assertEquals(ns2.db.frames.showThreatBar, true); assertEquals(ns2.db.frames.threatBarHeight, 5)
        assertEquals(ns2.db.frames.threatBarOnlyCombat, false)
        local b = btn(ns2, "party1")
        assertNotNil(b.threatStrip, "strip created on reload")
        assertEquals(st(b.threatStrip).h, 5)
        assertEquals(ns2.UnitFrames.ThreatReserve(ns2.db.frames, { outset = 2 }), 10)
        setThreat("party1", 3)
        assertTrue(stripShown(b), "shown out of combat (Only in combat off)")
        assertDeepEquals(save(ns2), saved, "stable after a second save")
    end)
    it("the 0.10.1 fixture loads unchanged: threat defaults, no threat keys written back, frames table identical", function()
        local raw = Fx.loadSaved(FIXTURE, "HealerForeverCharDB")
        for _, k in ipairs(THREAT_KEYS) do assertNil(raw.frames[k], "fixture has no " .. k) end
        local ns = H.boot({ group = 4, char = raw })
        clean()
        assertEquals(ns.db.frames.showThreatBar, false); assertEquals(ns.db.frames.threatBarHeight, 3)
        assertEquals(ns.db.frames.threatBarOnlyCombat, true)
        local out = ns:BuildSaveTable()
        assertDeepEquals(out.frames, raw.frames, "frames written back exactly as loaded")
        for _, b in ipairs(ns.UnitFrames.buttons) do assertNil(b.threatStrip, "no strip for an old save") end
    end)
end)

-- =====================================================================================================================
describe("threat bar: geometry", function()
    it("option off: no strip is created and the member frame is the old height", function()
        local ns = boot({ on = false })
        local f, m = ns.db.frames, margin(ns)
        for _, b in ipairs(ns.UnitFrames.buttons) do assertNil(b.threatStrip); assertNil(b.threatEdge) end
        for _, u in ipairs(MEMBERS) do
            local b = btn(ns, u)
            assertEquals(st(b).h, m * 2 + f.height + 6, u .. " old height (margins + health + power)")
            assertEquals(healthY(b), -m, u .. " health bar at the old place")
        end
        assertEquals(ns.UnitFrames.ThreatReserve(f, { outset = 2 }), 0)
        assertNil(ns.UnitFrames.threatReserved)
        clean()
    end)
    it("option on: members grow by the reserve (8 px at default), health bar 8 px lower, pets unchanged", function()
        local off = boot({ on = false })
        local offH, offY = {}, {}
        for _, u in ipairs(MEMBERS) do offH[u] = st(btn(off, u)).h; offY[u] = healthY(btn(off, u)) end
        local pet = btn(off, "partypet1")
        local offPet = { h = st(pet).h, w = st(pet).w, y = healthY(pet) }

        local ns = boot()
        clean()
        assertEquals(ns.UnitFrames.ThreatReserve(ns.db.frames, { outset = 2 }), 8)
        for _, u in ipairs(MEMBERS) do
            local b = btn(ns, u)
            assertEquals(st(b).h, offH[u] + 8, u .. " frame grows by 8")
            assertEquals(healthY(b), offY[u] - 8, u .. " health bar 8 px lower")
            assertNotNil(b.threatStrip, u .. " has a strip")
            assertEquals(st(b.threatStrip).h, 3); assertEquals(st(b.threatEdge).h, 5)
        end
        local p = btn(ns, "partypet1")
        assertEquals(st(p).h, offPet.h, "pet height unchanged"); assertEquals(st(p).w, offPet.w)
        assertEquals(healthY(p), offPet.y, "pet health unchanged")
        assertNil(p.threatStrip, "pets get no strip")
        for _, pu in ipairs(ns.UnitFrames.PET_UNITS and { "pet", "partypet1", "partypet2", "partypet3", "partypet4" } or {}) do
            local pb = btn(ns, pu)
            if pb then assertNil(pb.threatStrip, pu) end
        end
    end)
    it("height 6 grows the members 3 px more than the default", function()
        local def = boot()
        local ns = boot({ frames = { threatBarHeight = 6 } })
        for _, u in ipairs(MEMBERS) do
            assertEquals(st(btn(ns, u)).h, st(btn(def, u)).h + 3, u)
            assertEquals(healthY(btn(ns, u)), healthY(btn(def, u)) - 3, u)
            assertEquals(st(btn(ns, u).threatStrip).h, 6)
        end
    end)
    it("the strip sits inside its frame, clear of the health bar border; top buffs move up with it; nothing overlaps", function()
        local off = boot({ on = false })
        local gapOff = {}
        for _, u in ipairs(MEMBERS) do
            local b = btn(off, u)
            local rz, rh = G.rect(b.zones.buff, off.UnitFrames.anchor), G.rect(b.health, off.UnitFrames.anchor)
            gapOff[u] = rh.t - rz.b
        end
        for _, opts in ipairs({ {}, { frames = { threatBarHeight = 6 } }, { frames = { threatBarHeight = 2, layout = "horizontal" } },
            { frames = { border = { style = "gold", width = 4, color = "gold" } } }, { frames = { border = { style = "none", width = 1, color = "black" } } },
            { frames = { border = { style = "thin", width = 1, color = "black" }, layout = "vertical" } } }) do
            local ns = boot(opts)
            local root = ns.UnitFrames.anchor
            local label = (opts.frames and (tostring(opts.frames.threatBarHeight) .. "/" .. tostring(opts.frames.layout) .. "/" .. tostring(opts.frames.border and opts.frames.border.style)) or "default")
            local o = ns.Util.BorderSpec(ns.db.frames.border.style, ns.db.frames.border.width).outset
            local strips = {}
            for _, u in ipairs(MEMBERS) do
                local b = btn(ns, u)
                local rb, rh, re, rs = G.rect(b, root), G.rect(b.health, root), G.rect(b.threatEdge, root), G.rect(b.threatStrip, root)
                assertNotNil(re, label .. " edge positioned"); assertNotNil(rs, label .. " strip positioned")
                assertTrue(G.inside(re, rb), label .. " " .. u .. " edge leaves its frame " .. G.fmt(re) .. " vs " .. G.fmt(rb))
                assertTrue(G.inside(rs, re), label .. " " .. u .. " strip leaves its black edge")
                local border = { l = rh.l - o, t = rh.t - o, r = rh.r + o, b = rh.b + o }
                assertFalse(G.overlap(re, border), label .. " " .. u .. " edge overlaps the health bar border")
                assertTrue(border.t - re.b >= 1 - 1e-6, label .. " " .. u .. " at least 1 px free above the bar border")
                assertTrue(math.abs(re.l - border.l) < 1e-6 and math.abs(re.r - border.r) < 1e-6, label .. " " .. u .. " full width of the bar border")
                if b.power and st(b.power).shown then assertFalse(G.overlap(re, G.rect(b.power, root)), label .. " overlaps the power bar") end
                for kind, z in pairs(b.zones or {}) do
                    if st(z).shown then
                        local rz = G.rect(z, root)
                        assertFalse(G.overlap(re, rz), label .. " " .. u .. " strip overlaps the " .. kind .. " zone")
                    end
                end
                strips[#strips + 1] = { u = u, r = re }
                if not opts.frames then
                    local rz = G.rect(b.zones.buff, root)
                    assertEquals(rh.t - rz.b, gapOff[u] + 8, u .. " top buffs 8 px further above the health bar")
                end
            end
            -- strips never touch another member
            for _, s in ipairs(strips) do
                for _, u in ipairs(MEMBERS) do
                    if u ~= s.u then assertFalse(G.overlap(s.r, G.rect(btn(ns, u), root)), label .. " strip of " .. s.u .. " overlaps " .. u) end
                end
            end
            local problems = G.check(ns, MEMBERS, label)
            assertEquals(#problems, 0, table.concat(problems, "\n"))
            clean(label)
        end
    end)
    it("turning it on and off live: grows, then back to exactly the old geometry, strips hidden", function()
        local ns = boot({ on = false })
        local before = {}
        for _, u in ipairs(MEMBERS) do before[u] = { h = st(btn(ns, u)).h, y = healthY(btn(ns, u)) } end
        ns.db.frames.showThreatBar = true; ns.db.frames.threatBarOnlyCombat = false; apply(ns)
        setThreat("party1", 3)
        assertTrue(stripShown(btn(ns, "party1")))
        for _, u in ipairs(MEMBERS) do assertEquals(st(btn(ns, u)).h, before[u].h + 8, u) end
        ns.db.frames.showThreatBar = false; apply(ns)
        for _, u in ipairs(MEMBERS) do
            local b = btn(ns, u)
            assertEquals(st(b).h, before[u].h, u .. " height restored"); assertEquals(healthY(b), before[u].y, u .. " health restored")
            assertFalse(stripShown(b), u .. " strip hidden"); assertFalse(edgeShown(b), u .. " edge hidden")
        end
        assertNil(ns.UnitFrames.threatReserved)
        clean()
    end)
end)

-- =====================================================================================================================
describe("threat bar: level -> colour, and member states", function()
    local ns = boot({ frames = { threatBarOnlyCombat = false } })
    local b = btn(ns, "party1")
    it("0 hidden, 1 yellow, 2 orange, 3 red, nil hidden (strip and its black edge together)", function()
        setThreat("party1", 0); assertFalse(stripShown(b)); assertFalse(edgeShown(b))
        for level = 1, 3 do
            setThreat("party1", level)
            assertTrue(stripShown(b), "level " .. level); assertTrue(edgeShown(b))
            assertTrue(sameColor(colorOf(b), FALLBACK[level]) or sameColor(colorOf(b), ns.UnitFrames.THREAT_COLORS[level]), "level " .. level)
            assertTrue(sameColor(colorOf(b), ns.UnitFrames.THREAT_COLORS[level]))
        end
        assertTrue(sameColor(ns.UnitFrames.THREAT_COLORS[1], { 1, 1, 0.47 }), "yellow"); assertTrue(sameColor(ns.UnitFrames.THREAT_COLORS[2], { 1, 0.6, 0 }), "orange")
        assertTrue(sameColor(ns.UnitFrames.THREAT_COLORS[3], { 1, 0, 0 }), "red")
        mock.state.threatNil = { party1 = true }
        mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1")
        assertFalse(stripShown(b), "nil -> hidden"); assertFalse(edgeShown(b))
        mock.state.threatNil = nil
        setThreat("party1", 4); assertFalse(stripShown(b), "an unknown level draws nothing")
        setThreat("party1", 0)
        clean()
    end)
    it("each member has its own level; a nil-unit event refreshes everyone", function()
        mock.state.threat = { party1 = 1, party2 = 2, party3 = 3, party4 = 0, player = 2 }
        mock.fire("UNIT_THREAT_SITUATION_UPDATE"); mock.flushTimers()
        assertTrue(sameColor(colorOf(btn(ns, "party1")), FALLBACK[1])); assertTrue(sameColor(colorOf(btn(ns, "party2")), FALLBACK[2]))
        assertTrue(sameColor(colorOf(btn(ns, "party3")), FALLBACK[3])); assertFalse(stripShown(btn(ns, "party4")))
        assertTrue(stripShown(btn(ns, "player")), "the player's own frame too")
        mock.state.threat = {}; mock.fire("UNIT_THREAT_SITUATION_UPDATE"); mock.flushTimers()
        for _, u in ipairs(MEMBERS) do assertFalse(stripShown(btn(ns, u)), u) end
    end)
    it("the red aggro border still works next to the strip", function()
        setThreat("party1", 3); assertTrue(b.aggro)
        setThreat("party1", 1); assertFalse(b.aggro); assertTrue(stripShown(b))
        setThreat("party1", 0)
    end)
    it("dead, ghost, offline and not visible hide the strip; it comes back when they are alive / visible again", function()
        local S = mock.state
        setThreat("party1", 3); assertTrue(stripShown(b))
        S.dead.party1 = true; mock.fire("UNIT_FLAGS", "party1"); mock.flushTimers()
        assertEquals(b.state, "dead"); assertFalse(stripShown(b), "dead"); assertFalse(edgeShown(b))
        setThreat("party1", 3); assertFalse(stripShown(b), "still dead")
        S.dead.party1 = nil; mock.fire("UNIT_FLAGS", "party1"); mock.flushTimers()
        assertTrue(stripShown(b), "alive again")
        S.ghost = { party1 = true }; S.dead.party1 = true; mock.fire("UNIT_FLAGS", "party1"); mock.flushTimers()
        assertEquals(b.state, "ghost"); assertFalse(stripShown(b), "ghost")
        S.ghost = nil; S.dead.party1 = nil; mock.fire("UNIT_FLAGS", "party1"); mock.flushTimers()
        S.offline.party1 = true; mock.fire("UNIT_CONNECTION", "party1"); mock.flushTimers()
        assertEquals(b.state, "offline"); assertFalse(stripShown(b), "offline")
        S.offline.party1 = nil; mock.fire("UNIT_CONNECTION", "party1"); mock.flushTimers()
        assertTrue(stripShown(b), "online again")
        S.invisible = { party1 = true }; ns.UnitFrames:UpdateRange(b)
        assertEquals(b.rangeState, "hidden"); assertFalse(stripShown(b), "not visible"); assertFalse(edgeShown(b))
        S.invisible = nil; ns.UnitFrames:UpdateRange(b)
        assertTrue(stripShown(b), "visible again")
        setThreat("party1", 0)
        clean()
    end)
end)

-- =====================================================================================================================
describe("threat bar: Only in combat", function()
    it("on (default): hidden out of combat, shown after PLAYER_REGEN_DISABLED, hidden after PLAYER_REGEN_ENABLED", function()
        local ns = boot()
        local b = btn(ns, "party2")
        setThreat("party2", 3)
        assertFalse(stripShown(b), "out of combat")
        H.enterCombat()
        assertTrue(stripShown(b), "in combat"); assertTrue(sameColor(colorOf(b), FALLBACK[3]))
        setThreat("party2", 1); assertTrue(sameColor(colorOf(b), FALLBACK[1]), "colour follows in combat")
        H.leaveCombat()
        assertFalse(stripShown(b), "after combat"); assertFalse(edgeShown(b))
        clean()
    end)
    it("PLAYER_REGEN_DISABLED alone counts as fighting (before InCombatLockdown turns true)", function()
        local ns = boot()
        local b = btn(ns, "party2")
        setThreat("party2", 2)
        mock.fire("PLAYER_REGEN_DISABLED"); mock.flushTimers()
        assertTrue(ns.UnitFrames.PlayerFighting() and true or false)
        assertTrue(stripShown(b), "shown on the event itself")
        mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertFalse(stripShown(b))
        clean()
    end)
    it("InCombatLockdown alone counts as fighting (a /reload in combat: no REGEN_DISABLED seen)", function()
        local ns = boot()
        local b = btn(ns, "party2")
        mock.state.combat = true
        setThreat("party2", 3)
        assertTrue(stripShown(b))
        H.leaveCombat()
        assertFalse(stripShown(b))
        clean()
    end)
    it("off: shown out of combat as well, and stays shown through a fight", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        local b = btn(ns, "party2")
        setThreat("party2", 2)
        assertTrue(stripShown(b), "out of combat")
        H.enterCombat(); assertTrue(stripShown(b))
        H.leaveCombat(); assertTrue(stripShown(b))
        clean()
    end)
    it("flipping Only in combat applies at once, also in combat", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        local b = btn(ns, "party3")
        setThreat("party3", 3); assertTrue(stripShown(b))
        ns.db.frames.threatBarOnlyCombat = true; apply(ns)
        assertFalse(stripShown(b), "out of combat it hides now")
        H.enterCombat(); assertTrue(stripShown(b))
        ns.db.frames.threatBarOnlyCombat = false; apply(ns); assertTrue(stripShown(b))
        H.leaveCombat(); assertTrue(stripShown(b))
        clean()
    end)
end)

-- =====================================================================================================================
describe("threat bar: secret values", function()
    it("a secret threat keeps the last colour and visibility; no errors", function()
        local ns = boot()
        local b = btn(ns, "party1")
        setThreat("party1", 2)
        H.enterCombat()
        assertTrue(stripShown(b)); assertTrue(sameColor(colorOf(b), FALLBACK[2]))
        mock.state.secretThreat = true
        for _ = 1, 3 do mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1"); mock.fire("UNIT_THREAT_SITUATION_UPDATE") end
        mock.flushTimers()
        assertTrue(stripShown(b), "kept"); assertTrue(sameColor(colorOf(b), FALLBACK[2]), "kept orange")
        assertEquals(ns.UnitFrames.threatLevel[b], 2, "the secret is never stored")
        -- a member whose level was never readable stays hidden
        assertFalse(stripShown(btn(ns, "party4")))
        mock.state.secretThreat = nil
        setThreat("party1", 3); assertTrue(sameColor(colorOf(b), FALLBACK[3]), "readable again")
        H.leaveCombat()
        clean(); errorLogEmpty(ns)
    end)
    it("a secret level 0 after a readable 3 keeps red (the strip never compares the secret)", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        local b = btn(ns, "party3")
        setThreat("party3", 3)
        mock.state.secretThreat = true; mock.state.threat.party3 = 0
        mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party3"); mock.flushTimers()
        assertTrue(stripShown(b)); assertTrue(sameColor(colorOf(b), FALLBACK[3]))
        mock.state.secretThreat = nil
        clean()
    end)
    it("everything secret (S.secretAll) in and out of combat: full event storm, no errors, last state kept", function()
        local ns = boot()
        local S = mock.state
        setThreat("party1", 3); setThreat("party2", 1)
        H.enterCombat()
        S.secretAll = true; S.secretRange = true; S.secretTarget = true; S.secretThreat = true
        for _, ev in ipairs({ "UNIT_THREAT_SITUATION_UPDATE", "UNIT_HEALTH", "UNIT_FLAGS", "UNIT_CONNECTION", "UNIT_IN_RANGE_UPDATE", "UNIT_AURA" }) do
            for _, u in ipairs(MEMBERS) do mock.fire(ev, u) end
        end
        mock.fire("UNIT_THREAT_SITUATION_UPDATE"); mock.fire("PLAYER_TARGET_CHANGED"); mock.fire("GROUP_ROSTER_UPDATE")
        mock.flushTimers(); mock.runOnUpdate(3, 0.5); mock.flushTimers()
        clean("secretAll in combat"); errorLogEmpty(ns)
        assertTrue(stripShown(btn(ns, "party1"))); assertTrue(sameColor(colorOf(btn(ns, "party1")), FALLBACK[3]))
        assertTrue(stripShown(btn(ns, "party2"))); assertTrue(sameColor(colorOf(btn(ns, "party2")), FALLBACK[1]))
        assertFalse(stripShown(btn(ns, "party3")))
        H.leaveCombat()
        assertFalse(stripShown(btn(ns, "party1")), "Only in combat still hides out of combat with secret values")
        -- out of combat, everything still secret: toggle the option and relayout
        ns.db.frames.threatBarOnlyCombat = false; apply(ns)
        ns.db.frames.threatBarHeight = 5; apply(ns)
        mock.fire("UNIT_THREAT_SITUATION_UPDATE"); mock.flushTimers()
        assertTrue(stripShown(btn(ns, "party1"))); assertEquals(st(btn(ns, "party1").threatStrip).h, 5)
        S.secretAll = false; S.secretRange = false; S.secretTarget = false; S.secretThreat = false
        clean("secretAll out of combat"); errorLogEmpty(ns)
    end)
    it("S.secret (every value reported secret by issecretvalue) keeps the last state too", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        setThreat("party1", 2)
        mock.state.secret = true; mock.state.secretThreat = true
        mock.fire("UNIT_THREAT_SITUATION_UPDATE"); mock.flushTimers()
        assertTrue(stripShown(btn(ns, "party1"))); assertTrue(sameColor(colorOf(btn(ns, "party1")), FALLBACK[2]))
        mock.state.secret = false; mock.state.secretThreat = false
        clean()
    end)
end)

-- =====================================================================================================================
describe("threat bar: toggling in combat", function()
    it("turning it on in combat: no protected calls, no strips or space yet; space and strips after combat", function()
        local ns = boot({ on = false })
        local h0 = st(btn(ns, "party1")).h
        H.enterCombat()
        mock.calls = {}
        ns.db.frames.showThreatBar = true; ns.db.frames.threatBarOnlyCombat = false; apply(ns)
        setThreat("party1", 3)
        clean("toggle on in combat")
        assertEquals(st(btn(ns, "party1")).h, h0, "no resize in combat")
        for _, u in ipairs(MEMBERS) do
            local b = btn(ns, u)
            assertFalse(stripShown(b), u .. " nothing drawn over the bar while the space is not reserved")
            assertNil(b.threatStrip, u .. " no strip textures created in combat")
        end
        H.leaveCombat()
        clean("after combat")
        local b = btn(ns, "party1")
        assertEquals(st(b).h, h0 + 8, "space reserved after combat")
        assertNotNil(b.threatStrip)
        assertTrue(stripShown(b), "and the remembered red shows")
        assertTrue(sameColor(colorOf(b), FALLBACK[3]))
    end)
    it("on, off (out of combat), then on again in combat: the old strips stay hidden until the space is back", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        local b = btn(ns, "party1")
        local h = st(b).h
        setThreat("party1", 3); assertTrue(stripShown(b))
        ns.db.frames.showThreatBar = false; apply(ns)
        assertNotNil(b.threatStrip, "the textures stay (hidden)"); assertFalse(stripShown(b))
        H.enterCombat()
        ns.db.frames.showThreatBar = true; apply(ns)
        setThreat("party1", 3)
        assertFalse(stripShown(b), "not drawn over the health bar while the frame has no room for it")
        assertEquals(st(b).h, h - 8)
        clean("on again in combat")
        H.leaveCombat()
        assertEquals(st(b).h, h); assertTrue(stripShown(b))
        clean()
    end)
    it("turning it on in combat with Only in combat on: shown after the next fight starts", function()
        local ns = boot({ on = false })
        H.enterCombat()
        ns.db.frames.showThreatBar = true; apply(ns)
        setThreat("party2", 2)
        H.leaveCombat()
        assertFalse(stripShown(btn(ns, "party2")))
        H.enterCombat()
        assertTrue(stripShown(btn(ns, "party2")))
        H.leaveCombat()
        clean()
    end)
    it("turning it off in combat hides the strips at once (space freed after combat), no protected calls", function()
        local ns = boot()
        local b = btn(ns, "party1")
        local h = st(b).h
        setThreat("party1", 3); H.enterCombat()
        assertTrue(stripShown(b))
        ns.db.frames.showThreatBar = false; apply(ns)
        assertFalse(stripShown(b), "hidden at once"); assertFalse(edgeShown(b))
        setThreat("party1", 2); assertFalse(stripShown(b), "stays hidden on threat updates")
        mock.fire("PLAYER_REGEN_DISABLED"); mock.flushTimers(); assertFalse(stripShown(b))
        assertEquals(st(b).h, h, "no resize in combat")
        clean("toggle off in combat")
        H.leaveCombat()
        assertEquals(st(b).h, h - 8, "space freed after combat")
        assertFalse(stripShown(b))
        clean()
    end)
    it("changing the height in combat: no protected calls, the new height applies after combat", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        local b = btn(ns, "party1")
        local h = st(b).h
        H.enterCombat()
        ns.db.frames.threatBarHeight = 6; apply(ns)
        clean("height in combat")
        assertEquals(st(b).h, h); assertEquals(st(b.threatStrip).h, 3)
        H.leaveCombat()
        assertEquals(st(b).h, h + 3); assertEquals(st(b.threatStrip).h, 6)
        clean()
    end)
    it("threat updates in combat touch only the strip textures (never protected)", function()
        local ns = boot()
        H.enterCombat()
        mock.calls = {}
        for level = 0, 3 do for _, u in ipairs(MEMBERS) do setThreat(u, level) end end
        mock.fire("PLAYER_REGEN_DISABLED"); mock.flushTimers()
        clean()
        for _, c in ipairs(mock.calls) do
            if c.method == "SetShown" or c.method == "Show" or c.method == "Hide" then
                assertFalse(c.secure == true, "secure " .. tostring(c.frame) .. ":" .. c.method)
            end
        end
        H.leaveCombat()
        assertTrue(#ns.UnitFrames.buttons > 0)
    end)
end)

-- =====================================================================================================================
describe("threat bar: range dims the strip with the health bar", function()
    it("out of range: strip and edge take the health bar's alpha; back in range: 1", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        local b = btn(ns, "party1")
        setThreat("party1", 3)
        mock.state.outOfRange.party1 = true; ns.UnitFrames:UpdateRange(b)
        assertEquals(b.rangeState, "out")
        local dim = ns.db.frames.range.dim / 100
        assertEquals(st(b.health).alpha, dim)
        assertEquals(st(b.threatStrip).alpha, dim, "strip dimmed"); assertEquals(st(b.threatEdge).alpha, dim, "edge dimmed")
        assertTrue(stripShown(b), "out of range is still visible (only dimmed)")
        mock.state.outOfRange.party1 = nil; ns.UnitFrames:UpdateRange(b)
        assertEquals(st(b.threatStrip).alpha, 1); assertEquals(st(b.threatEdge).alpha, 1)
        clean()
    end)
    it("a member already out of range when the strip is turned on gets a dimmed strip right away (live and after combat)", function()
        for _, inCombat in ipairs({ false, true }) do
            local ns = boot({ on = false, frames = { threatBarOnlyCombat = false } })
            local b = btn(ns, "party1")
            mock.state.outOfRange.party1 = true; ns.UnitFrames:UpdateRange(b)
            local dim = ns.db.frames.range.dim / 100
            if inCombat then H.enterCombat() end
            ns.db.frames.showThreatBar = true; apply(ns)
            if inCombat then H.leaveCombat() end
            setThreat("party1", 3)
            assertTrue(stripShown(b))
            assertEquals(st(b.threatStrip).alpha, dim, "strip dimmed (combat=" .. tostring(inCombat) .. ")")
            assertEquals(st(b.threatEdge).alpha, dim)
            mock.state.outOfRange.party1 = nil
            clean()
        end
    end)
    it("secret range: the strip is driven by SetAlphaFromBoolean with the health bar's values (no truth test)", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        local b = btn(ns, "party1")
        setThreat("party1", 2)
        mock.calls = {}
        mock.state.secretRange = true
        ns.UnitFrames:UpdateRange(b)
        assertEquals(b.rangeState, "secret")
        local dim = ns.db.frames.range.dim / 100
        local seen = {}
        for _, c in ipairs(mock.calls) do
            if c.method == "SetAlphaFromBoolean" then
                if c.obj == b.threatStrip then seen.strip = c end
                if c.obj == b.threatEdge then seen.edge = c end
                if c.obj == b.health then seen.health = c end
            end
        end
        assertNotNil(seen.health, "health driven")
        assertNotNil(seen.strip, "strip driven"); assertNotNil(seen.edge, "edge driven")
        for _, k in ipairs({ "strip", "edge" }) do
            assertTrue(mock.isSecret(seen[k].args[1]), k .. " gets the secret itself")
            assertEquals(seen[k].args[2], 1); assertEquals(seen[k].args[3], dim)
        end
        assertTrue(stripShown(b))
        mock.state.secretRange = false
        clean()
    end)
    it("the dim range style fades the whole button (strip included), the strip itself stays at 1", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false, range = { style = "dim", dim = 40 } } })
        local b = btn(ns, "party1")
        setThreat("party1", 3)
        mock.state.outOfRange.party1 = true; ns.UnitFrames:UpdateRange(b)
        assertEquals(st(b).alpha, 0.4)
        assertEquals(st(b.threatStrip).alpha or 1, 1)
        mock.state.outOfRange.party1 = nil
        clean()
    end)
end)

-- =====================================================================================================================
describe("threat bar: raid layout is unaffected", function()
    local function raidGeometry(ns)
        local out = {}
        for i, b in ipairs(ns.RaidFrames.buttons) do
            local s = st(b)
            out[i] = { w = s.w, h = s.h, shown = s.shown, p = s.points[#s.points] and { s.points[#s.points][1], s.points[#s.points][4], s.points[#s.points][5] } }
        end
        return out
    end
    it("with the strip on, raid buttons get no strip and the same geometry; threat events in a raid run clean", function()
        local off = boot({ on = false, raid = 25 })
        assertEquals(off.RaidFrames.active, "raid")
        local want = raidGeometry(off)
        local ns = boot({ raid = 25, frames = { threatBarOnlyCombat = false } })
        assertEquals(ns.RaidFrames.active, "raid")
        assertDeepEquals(raidGeometry(ns), want, "raid geometry")
        for _, b in ipairs(ns.RaidFrames.buttons) do assertNil(b.threatStrip); assertNil(b.threatEdge) end
        mock.state.threat = { raid3 = 3, raid5 = 1 }
        mock.fire("UNIT_THREAT_SITUATION_UPDATE", "raid3"); mock.fire("UNIT_THREAT_SITUATION_UPDATE")
        H.enterCombat(); H.leaveCombat()
        clean()
        -- party bars stay hidden in the raid layout, so no strip is visible to the player either
        for _, b in ipairs(ns.UnitFrames.buttons) do
            if b.threatStrip then assertFalse(mock.isVisible(b.threatStrip), "a party strip is visible in the raid layout") end
        end
    end)
end)

-- =====================================================================================================================
describe("threat bar: Frames & Bars pane", function()
    local function checkboxFor(text)
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "CheckButton" and f.label and st(f.label).text == text then return f end
        end
        error("checkbox '" .. text .. "' not found")
    end
    local function sliderFor(text)
        for _, f in ipairs(mock.frames) do
            if f.slider and f.label and st(f.label).text == text then return f end
        end
        error("slider '" .. text .. "' not found")
    end
    local function labelFor(text)
        for _, f in ipairs(mock.frames) do if st(f).kind == "FontString" and st(f).text == text then return f end end
    end
    local function toggle(cb, v) st(cb).checked = v; st(cb).scripts.OnClick(cb, "LeftButton"); mock.flushTimers() end
    local function setSlider(sf, v) st(sf.slider).value = v; st(sf.slider).scripts.OnValueChanged(sf.slider, v, true); mock.flushTimers() end

    it("the controls exist, start at the defaults, and apply live", function()
        local ns = H.boot({ group = 4 })
        ns.Options:Show("frames"); mock.flushTimers()
        clean()
        local show, onlyCombat, height = checkboxFor("Show threat bar"), checkboxFor("Only in combat"), sliderFor("Bar height")
        assertFalse(st(show).checked == true); assertTrue(st(onlyCombat).checked == true)
        local b = btn(ns, "party1")
        local h = st(b).h
        toggle(show, true)
        assertEquals(ns.db.frames.showThreatBar, true); assertEquals(st(b).h, h + 8)
        setSlider(height, 6)
        assertEquals(ns.db.frames.threatBarHeight, 6); assertEquals(st(b).h, h + 11); assertEquals(st(b.threatStrip).h, 6)
        setSlider(height, 9); assertEquals(ns.db.frames.threatBarHeight, 6, "clamped")
        setSlider(height, 1); assertEquals(ns.db.frames.threatBarHeight, 2, "clamped")
        setSlider(height, 3.6); assertEquals(ns.db.frames.threatBarHeight, 4, "rounded")
        setThreat("party1", 3)
        assertFalse(stripShown(b))
        toggle(onlyCombat, false)
        assertEquals(ns.db.frames.threatBarOnlyCombat, false); assertTrue(stripShown(b))
        toggle(show, false)
        assertEquals(ns.db.frames.showThreatBar, false); assertEquals(st(b).h, h); assertFalse(stripShown(b))
        clean()
    end)
    it("the section sits between the checkboxes and Range, rows do not overlap", function()
        local ns = H.boot({ group = 4 })
        ns.Options:Show("frames"); mock.flushTimers()
        local function y(f) return st(f).points[1][3] end
        local title, hint, range = labelFor("Threat bar"), nil, labelFor("Range")
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "FontString" and type(st(f).text) == "string" and st(f).text:find("thin strip above each health bar", 1, true) then hint = f end
        end
        assertNotNil(title); assertNotNil(hint); assertNotNil(range)
        local rows = { y(checkboxFor("Low-HP pulse (only when health is readable)")), y(title), y(hint), y(checkboxFor("Show threat bar")),
            y(sliderFor("Bar height")), y(checkboxFor("Only in combat")), y(range) }
        for i = 2, #rows do
            assertTrue(rows[i - 1] - rows[i] >= 18, "row " .. i .. " too close to the one above (" .. rows[i - 1] .. " -> " .. rows[i] .. ")")
        end
        clean()
    end)
    it("the Show threat bar tooltip explains every colour, and the Help tab mentions the threat bar", function()
        local ns = H.boot({ group = 4 })
        ns.Options:Show("frames"); mock.flushTimers()
        local lines, orig = {}, GameTooltip.AddLine
        GameTooltip.AddLine = function(_, text) lines[#lines + 1] = tostring(text) end
        local show = checkboxFor("Show threat bar")
        st(show).scripts.OnEnter(show)
        GameTooltip.AddLine = orig
        local all = table.concat(lines, "\n")
        for _, word in ipairs({ "Yellow", "Orange", "Red", "No strip", "every mob" }) do
            assertTrue(all:find(word, 1, true) ~= nil, "tooltip misses '" .. word .. "':\n" .. all)
        end
        assertNotNil(st(show).scripts.OnLeave, "tooltip hides on leave")
        ns.Options:Show("help"); mock.flushTimers()
        local found = false
        for _, f in ipairs(mock.frames) do
            local t = st(f).text
            if st(f).kind == "FontString" and type(t) == "string" and t:find("Threat bar (Frames & Bars)", 1, true) then found = true end
        end
        assertTrue(found, "Help tab has the threat bar line")
        clean()
    end)
end)

-- =====================================================================================================================
-- frames.threatBarShowSafe: level 0 (in the fight, less threat than the tank) draws a green strip; nil (not on any
-- threat table) never draws anything. 0 and nil are kept apart in UF.threatLevel.
local function setNil(u)
    mock.state.threatNil = mock.state.threatNil or {}
    mock.state.threatNil[u] = true
    mock.fire("UNIT_THREAT_SITUATION_UPDATE", u); mock.flushTimers()
    mock.state.threatNil[u] = nil
end
local function bootSafe(extra)
    local frames = { threatBarShowSafe = true, threatBarOnlyCombat = false }
    for k, v in pairs(extra or {}) do frames[k] = v end
    return boot({ frames = frames })
end

describe("threat bar: green when below the tank (threatBarShowSafe)", function()
    it("default off: level 0 draws nothing, the level is stored as 0", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        assertEquals(ns.db.frames.threatBarShowSafe, false)
        local b = btn(ns, "party1")
        setThreat("party1", 0)
        assertFalse(stripShown(b), "no strip for 0 while the option is off"); assertFalse(edgeShown(b))
        assertEquals(ns.UnitFrames.threatLevel[b], 0)
        H.enterCombat(); setThreat("party1", 0)
        assertFalse(stripShown(b), "not in combat either")
        H.leaveCombat()
        clean()
    end)
    it("the colour constant is the agreed green (0.25 / 0.8 / 0.3), not the game's grey for 0", function()
        local ns = bootSafe()
        assertTrue(sameColor(ns.UnitFrames.THREAT_SAFE_COLOR, SAFE))
        assertNil(ns.UnitFrames.THREAT_COLORS[0], "level 0 never takes GetThreatStatusColor(0) grey")
        clean()
    end)
    it("on: level 0 draws a green strip with its black edge", function()
        local ns = bootSafe()
        local b = btn(ns, "party1")
        setThreat("party1", 0)
        assertTrue(stripShown(b), "green strip shown"); assertTrue(edgeShown(b))
        assertTrue(sameColor(colorOf(b), SAFE), "vertex colour is the safe green")
        assertEquals(st(b.threatStrip).vertex.a, 1)
        assertEquals(ns.UnitFrames.threatLevel[b], 0)
        clean()
    end)
    it("on: nil draws nothing and is stored as nil (never mixed up with 0)", function()
        local ns = bootSafe()
        local b = btn(ns, "party1")
        setThreat("party1", 0); assertTrue(stripShown(b))
        setNil("party1")
        assertNil(ns.UnitFrames.threatLevel[b], "nil stays nil")
        assertFalse(stripShown(b), "nil -> hidden"); assertFalse(edgeShown(b))
        assertFalse(b.aggro == true)
        -- a member whose first answer is nil never shows a strip
        setNil("party2")
        assertNil(ns.UnitFrames.threatLevel[btn(ns, "party2")]); assertFalse(stripShown(btn(ns, "party2")))
        clean()
    end)
    it("on: 1 yellow, 2 orange, 3 red still, and back to green on 0", function()
        local ns = bootSafe()
        local b = btn(ns, "party1")
        for level = 1, 3 do
            setThreat("party1", level)
            assertTrue(stripShown(b), "level " .. level)
            assertTrue(sameColor(colorOf(b), FALLBACK[level]), "level " .. level .. " keeps its colour")
            assertFalse(sameColor(colorOf(b), SAFE))
        end
        assertTrue(b.aggro, "red border at 3")
        setThreat("party1", 0)
        assertTrue(sameColor(colorOf(b), SAFE), "back to green"); assertFalse(b.aggro)
        setThreat("party1", 4); assertFalse(stripShown(b), "an unknown level still draws nothing")
        clean()
    end)
    it("on: each member keeps its own colour (a nil-unit event)", function()
        local ns = bootSafe()
        mock.state.threat = { party1 = 0, party2 = 3, party3 = 0 }
        mock.state.threatNil = { party4 = true }
        mock.fire("UNIT_THREAT_SITUATION_UPDATE"); mock.flushTimers()
        mock.state.threatNil = nil
        assertTrue(sameColor(colorOf(btn(ns, "party1")), SAFE)); assertTrue(sameColor(colorOf(btn(ns, "party2")), FALLBACK[3]))
        assertTrue(sameColor(colorOf(btn(ns, "party3")), SAFE)); assertFalse(stripShown(btn(ns, "party4")), "nil member hidden")
        assertNil(btn(ns, "partypet1").threatStrip, "pets never get a strip")
        clean()
    end)
    it("secret after 0 keeps green; nil is green while fighting (also under a secret), hidden after combat; the secret is never stored", function()
        local ns = bootSafe({ threatBarOnlyCombat = true })
        local b, b2 = btn(ns, "party1"), btn(ns, "party2")
        setThreat("party1", 0); setNil("party2")
        mock.state.threatNil = { party2 = true } -- party2 stays off every threat list for the whole test
        H.enterCombat()
        assertTrue(stripShown(b)); assertTrue(sameColor(colorOf(b), SAFE))
        assertTrue(stripShown(b2), "no threat while fighting is green too"); assertTrue(sameColor(colorOf(b2), SAFE))
        mock.state.secretThreat = true
        for _ = 1, 3 do mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1"); mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party2"); mock.fire("UNIT_THREAT_SITUATION_UPDATE") end
        mock.flushTimers()
        assertTrue(stripShown(b), "green kept"); assertTrue(sameColor(colorOf(b), SAFE))
        assertTrue(stripShown(b2), "nil stays green under a secret while fighting"); assertTrue(sameColor(colorOf(b2), SAFE))
        assertEquals(ns.UnitFrames.threatLevel[b], 0, "0 kept")
        assertNil(ns.UnitFrames.threatLevel[b2], "nil kept")
        for _, u in ipairs(MEMBERS) do
            assertFalse(mock.isSecret(ns.UnitFrames.threatLevel[btn(ns, u)]), u .. " never stores a secret")
        end
        mock.state.secretThreat = nil
        H.leaveCombat()
        ns.db.frames.threatBarOnlyCombat = false; apply(ns)
        assertTrue(stripShown(b), "0 is green out of combat too"); assertFalse(stripShown(b2), "nil out of a fight shows nothing")
        assertFalse(edgeShown(b2))
        mock.state.threatNil = nil
        clean(); errorLogEmpty(ns)
    end)
    it("everything secret (S.secretAll) in and out of combat with the option on: no errors, green kept", function()
        local ns = bootSafe({ threatBarOnlyCombat = true })
        local S = mock.state
        setThreat("party1", 0); setThreat("party2", 2)
        H.enterCombat()
        S.secretAll = true; S.secretRange = true; S.secretTarget = true; S.secretThreat = true
        for _, ev in ipairs({ "UNIT_THREAT_SITUATION_UPDATE", "UNIT_HEALTH", "UNIT_FLAGS", "UNIT_CONNECTION", "UNIT_IN_RANGE_UPDATE", "UNIT_AURA" }) do
            for _, u in ipairs(MEMBERS) do mock.fire(ev, u) end
        end
        mock.fire("UNIT_THREAT_SITUATION_UPDATE"); mock.flushTimers(); mock.runOnUpdate(3, 0.5); mock.flushTimers()
        clean("secretAll in combat"); errorLogEmpty(ns)
        assertTrue(stripShown(btn(ns, "party1"))); assertTrue(sameColor(colorOf(btn(ns, "party1")), SAFE))
        assertTrue(sameColor(colorOf(btn(ns, "party2")), FALLBACK[2]))
        -- toggle the option off and on while everything is secret, in combat
        ns.db.frames.threatBarShowSafe = false; apply(ns)
        assertFalse(stripShown(btn(ns, "party1")), "off hides the green at once"); assertTrue(stripShown(btn(ns, "party2")))
        ns.db.frames.threatBarShowSafe = true; apply(ns)
        assertTrue(stripShown(btn(ns, "party1")))
        H.leaveCombat()
        assertFalse(stripShown(btn(ns, "party1")), "Only in combat hides it out of combat")
        ns.db.frames.threatBarOnlyCombat = false; apply(ns)
        assertTrue(stripShown(btn(ns, "party1"))); assertTrue(sameColor(colorOf(btn(ns, "party1")), SAFE))
        S.secretAll = false; S.secretRange = false; S.secretTarget = false; S.secretThreat = false
        clean("secretAll out of combat"); errorLogEmpty(ns)
    end)
    it("green is hidden when dead, offline or not visible, and comes back", function()
        local ns = bootSafe()
        local S, b = mock.state, btn(ns, "party1")
        setThreat("party1", 0); assertTrue(stripShown(b))
        S.dead.party1 = true; mock.fire("UNIT_FLAGS", "party1"); mock.flushTimers()
        assertFalse(stripShown(b), "dead"); assertFalse(edgeShown(b))
        setThreat("party1", 0); assertFalse(stripShown(b), "still dead")
        S.dead.party1 = nil; mock.fire("UNIT_FLAGS", "party1"); mock.flushTimers()
        assertTrue(stripShown(b)); assertTrue(sameColor(colorOf(b), SAFE))
        S.offline.party1 = true; mock.fire("UNIT_CONNECTION", "party1"); mock.flushTimers()
        assertFalse(stripShown(b), "offline")
        S.offline.party1 = nil; mock.fire("UNIT_CONNECTION", "party1"); mock.flushTimers()
        S.invisible = { party1 = true }; ns.UnitFrames:UpdateRange(b)
        assertFalse(stripShown(b), "not visible"); assertFalse(edgeShown(b))
        S.invisible = nil; ns.UnitFrames:UpdateRange(b)
        assertTrue(stripShown(b), "visible again")
        clean()
    end)
    it("Only in combat: green hidden out of combat, shown while fighting, hidden again after", function()
        local ns = bootSafe({ threatBarOnlyCombat = true })
        local b = btn(ns, "party2")
        setThreat("party2", 0)
        assertFalse(stripShown(b), "not fighting")
        H.enterCombat(); assertTrue(stripShown(b)); assertTrue(sameColor(colorOf(b), SAFE))
        H.leaveCombat(); assertFalse(stripShown(b))
        clean()
    end)
    it("green dims with range like the health bar (readable and secret range)", function()
        local ns = bootSafe()
        local b = btn(ns, "party1")
        setThreat("party1", 0)
        local dim = ns.db.frames.range.dim / 100
        mock.state.outOfRange.party1 = true; ns.UnitFrames:UpdateRange(b)
        assertTrue(stripShown(b), "still shown out of range")
        assertEquals(st(b.threatStrip).alpha, dim); assertEquals(st(b.threatEdge).alpha, dim)
        assertTrue(sameColor(colorOf(b), SAFE))
        mock.state.outOfRange.party1 = nil; ns.UnitFrames:UpdateRange(b)
        assertEquals(st(b.threatStrip).alpha, 1)
        mock.calls = {}
        mock.state.secretRange = true; ns.UnitFrames:UpdateRange(b)
        local driven
        for _, c in ipairs(mock.calls) do
            if c.method == "SetAlphaFromBoolean" and c.obj == b.threatStrip then driven = c end
        end
        assertNotNil(driven, "secret range drives the green strip")
        assertTrue(mock.isSecret(driven.args[1])); assertEquals(driven.args[3], dim)
        assertTrue(stripShown(b))
        mock.state.secretRange = false
        clean()
    end)
    it("toggling the option in combat updates the strip at once, without protected calls or a resize", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false } })
        local b = btn(ns, "party1")
        local h, y = st(b).h, healthY(b)
        setThreat("party1", 0); setThreat("party2", 3)
        H.enterCombat()
        mock.calls = {}
        assertFalse(stripShown(b))
        ns.db.frames.threatBarShowSafe = true; apply(ns)
        assertTrue(stripShown(b), "green at once in combat"); assertTrue(sameColor(colorOf(b), SAFE))
        assertTrue(sameColor(colorOf(btn(ns, "party2")), FALLBACK[3]), "red untouched")
        ns.db.frames.threatBarShowSafe = false; apply(ns)
        assertFalse(stripShown(b), "hidden at once in combat"); assertFalse(edgeShown(b))
        assertTrue(stripShown(btn(ns, "party2")))
        clean("toggle green in combat")
        assertEquals(st(b).h, h, "no resize: green needs no extra space"); assertEquals(healthY(b), y)
        H.leaveCombat()
        assertEquals(st(b).h, h); assertEquals(healthY(b), y)
        clean()
    end)
    it("the option alone does nothing while the threat bar is off", function()
        local ns = boot({ on = false, frames = { threatBarShowSafe = true, threatBarOnlyCombat = false } })
        setThreat("party1", 0)
        for _, b in ipairs(ns.UnitFrames.buttons) do assertNil(b.threatStrip) end
        assertNil(ns.UnitFrames.threatReserved)
        clean()
    end)
    it("geometry: green strips sit inside their frames, the layout is identical to the option off, nothing overlaps", function()
        local off = boot({ frames = { threatBarOnlyCombat = false } })
        local want = {}
        for _, u in ipairs(MEMBERS) do want[u] = { h = st(btn(off, u)).h, w = st(btn(off, u)).w, y = healthY(btn(off, u)) } end
        local ns = bootSafe()
        for _, u in ipairs(MEMBERS) do setThreat(u, 0) end
        local root = ns.UnitFrames.anchor
        for _, u in ipairs(MEMBERS) do
            local b = btn(ns, u)
            assertTrue(stripShown(b), u)
            assertEquals(st(b).h, want[u].h, u .. " height"); assertEquals(st(b).w, want[u].w); assertEquals(healthY(b), want[u].y)
            local rb, re, rs = G.rect(b, root), G.rect(b.threatEdge, root), G.rect(b.threatStrip, root)
            assertTrue(G.inside(re, rb), u .. " edge inside its frame"); assertTrue(G.inside(rs, re), u .. " strip inside its edge")
            for _, o in ipairs(MEMBERS) do
                if o ~= u then assertFalse(G.overlap(re, G.rect(btn(ns, o), root)), u .. " strip overlaps " .. o) end
            end
        end
        local problems = G.check(ns, MEMBERS, "green")
        assertEquals(#problems, 0, table.concat(problems, "\n"))
        clean()
    end)
end)

describe("threat bar: threatBarShowSafe settings", function()
    it("default false in DEFAULTS and a fresh character", function()
        local ns = H.boot({ group = 4 })
        assertEquals(ns.DEFAULTS.frames.threatBarShowSafe, false)
        assertEquals(ns.db.frames.threatBarShowSafe, false)
        clean()
    end)
    it("wrong types load as false; true is kept", function()
        for _, v in ipairs({ "yes", 1, 0, {}, "true" }) do
            local ns = boot({ frames = { threatBarShowSafe = v } })
            assertEquals(ns.db.frames.threatBarShowSafe, false, "saved " .. type(v))
            assertNil(ns:BuildSaveTable().frames.threatBarShowSafe, "a bad value is not written back (" .. type(v) .. ")")
            clean()
        end
        local ns = boot({ frames = { threatBarShowSafe = true } })
        assertEquals(ns.db.frames.threatBarShowSafe, true)
    end)
    it("sparse save: not written while false; turning it on writes only that key", function()
        local ns = H.boot({ group = 4 })
        local before = ns:BuildSaveTable()
        assertNil(before.frames and before.frames.threatBarShowSafe)
        ns.db.frames.threatBarShowSafe = true
        local after = ns:BuildSaveTable()
        assertEquals(after.frames.threatBarShowSafe, true)
        after.frames.threatBarShowSafe = nil
        if next(after.frames) == nil then after.frames = nil end
        assertDeepEquals(after, before, "only frames.threatBarShowSafe differs")
        ns.db.frames.threatBarShowSafe = false
        local back = ns:BuildSaveTable()
        assertNil(back.frames and back.frames.threatBarShowSafe, "false again -> not written")
    end)
    it("save -> reload keeps it on and the green applies", function()
        local ns = H.boot({ group = 4, party = PARTY_WITH_PET })
        ns.db.frames.showThreatBar = true; ns.db.frames.threatBarShowSafe = true; ns.db.frames.threatBarOnlyCombat = false
        apply(ns)
        local saved = save(ns)
        assertEquals(saved.frames.threatBarShowSafe, true)
        local ns2 = H.boot({ group = 4, char = saved, party = PARTY_WITH_PET })
        clean()
        assertEquals(ns2.db.frames.threatBarShowSafe, true)
        setThreat("party1", 0)
        assertTrue(stripShown(btn(ns2, "party1"))); assertTrue(sameColor(colorOf(btn(ns2, "party1")), SAFE))
        assertDeepEquals(save(ns2), saved, "stable after a second save")
    end)
    it("the owner's older fixtures load with the option off and never write it", function()
        local list = {
            { HF_TESTS .. "/fixtures/settings-v0.10.1.lua", "HealerForeverCharDB" },
            { HF_TESTS .. "/fixtures/owner-char-v3.lua", "HealerForeverCharDB" },
            { HF_TESTS .. "/fixtures/owner-char-pre-buffgroups.lua", "HealerForeverCharDB" },
            { HF_TESTS .. "/fixtures/party-golden-0.10.1.lua", "HealerForeverCharDB" },
        }
        local seen = 0
        for _, c in ipairs(list) do
            local ok, raw = pcall(Fx.loadSaved, c[1], c[2])
            if ok and type(raw) == "table" then
                seen = seen + 1
                assertNil(raw.frames and raw.frames.threatBarShowSafe, c[1] .. " has no threatBarShowSafe")
                local ns = H.boot({ group = 4, char = raw })
                clean(c[1])
                assertEquals(ns.db.frames.threatBarShowSafe, false, c[1])
                local out = ns:BuildSaveTable()
                assertNil(out.frames and out.frames.threatBarShowSafe, c[1] .. " writes no threatBarShowSafe")
            end
        end
        assertTrue(seen >= 1, "at least the 0.10.1 fixture loads")
    end)
end)

describe("threat bar: Green when below the tank checkbox", function()
    local function checkboxFor(text)
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "CheckButton" and f.label and st(f.label).text == text then return f end
        end
        error("checkbox '" .. text .. "' not found")
    end
    local function sliderFor(text)
        for _, f in ipairs(mock.frames) do
            if f.slider and f.label and st(f.label).text == text then return f end
        end
        error("slider '" .. text .. "' not found")
    end
    local function toggle(cb, v) st(cb).checked = v; st(cb).scripts.OnClick(cb, "LeftButton"); mock.flushTimers() end
    local function y(f) return st(f).points[1][3] end

    it("sits between Bar height and Only in combat, starts unchecked, rows do not overlap", function()
        local ns = H.boot({ group = 4 })
        ns.Options:Show("frames"); mock.flushTimers()
        local safe = checkboxFor("Green when below the tank")
        assertFalse(st(safe).checked == true, "unchecked by default")
        local rows = { y(checkboxFor("Show threat bar")), y(sliderFor("Bar height")), y(safe), y(checkboxFor("Only in combat")) }
        for i = 2, #rows do
            assertTrue(rows[i - 1] - rows[i] >= 18, "row " .. i .. " too close to the one above (" .. rows[i - 1] .. " -> " .. rows[i] .. ")")
        end
        assertEquals(st(safe).points[1][2], st(checkboxFor("Only in combat")).points[1][2], "same left edge as the other checkboxes")
        clean()
    end)
    it("clicking it applies live (also in combat, no protected calls)", function()
        local ns = H.boot({ group = 4 })
        ns.Options:Show("frames"); mock.flushTimers()
        toggle(checkboxFor("Show threat bar"), true)
        toggle(checkboxFor("Only in combat"), false)
        local b = btn(ns, "party1")
        setThreat("party1", 0)
        assertFalse(stripShown(b))
        local safe = checkboxFor("Green when below the tank")
        toggle(safe, true)
        assertEquals(ns.db.frames.threatBarShowSafe, true)
        assertTrue(stripShown(b)); assertTrue(sameColor(colorOf(b), SAFE))
        H.enterCombat()
        toggle(safe, false)
        assertEquals(ns.db.frames.threatBarShowSafe, false); assertFalse(stripShown(b), "off in combat hides at once")
        toggle(safe, true); assertTrue(stripShown(b), "on in combat shows at once")
        clean("checkbox in combat")
        H.leaveCombat()
        clean()
    end)
    it("the Show threat bar tooltip has the green line in the green colour", function()
        local ns = H.boot({ group = 4 })
        ns.Options:Show("frames"); mock.flushTimers()
        local lines, orig = {}, GameTooltip.AddLine
        GameTooltip.AddLine = function(_, text, r, g, b) lines[#lines + 1] = { tostring(text), r, g, b } end
        local show = checkboxFor("Show threat bar")
        st(show).scripts.OnEnter(show)
        GameTooltip.AddLine = orig
        local green
        for _, l in ipairs(lines) do if l[1]:find("Green", 1, true) then green = l end end
        assertNotNil(green, "tooltip has a Green line")
        assertTrue(green[1]:find("less threat than the tank", 1, true) ~= nil, green[1])
        assertTrue(sameColor({ green[2], green[3], green[4] }, SAFE), "drawn in the strip's green")
        assertNotNil(ns)
        clean()
    end)
end)

describe("threat bar: /hf debug threat", function()
    local function run()
        mock.printed = {}
        local ok, err = pcall(_G.SlashCmdList.HEALERFOREVER, "debug threat")
        mock.flushTimers()
        assertTrue(ok, tostring(err))
        return table.concat(mock.printed, "\n")
    end
    it("prints the game's answer, the stored level and the strip state per member", function()
        local ns = boot({ frames = { threatBarOnlyCombat = false, threatBarShowSafe = true } })
        setThreat("party1", 3)
        mock.state.threatNil = { party2 = true }; setThreat("party2", nil)
        local out = run()
        assertTrue(out:find("threat debug", 1, true) ~= nil, out)
        assertTrue(out:find("green true", 1, true) ~= nil, out)
        assertTrue(out:find("party1: game=3 stored=3", 1, true) ~= nil, out)
        assertTrue(out:find("party2: game=nil stored=nil", 1, true) ~= nil, out)
        assertTrue(out:find("strip=shown", 1, true) ~= nil, out)
        assertTrue(out:find("partypet1", 1, true) == nil, "pets are skipped:\n" .. out)
        errorLogEmpty(ns); clean()
    end)
    it("says SECRET for secret values in combat, without errors", function()
        local ns = boot()
        mock.state.combat = true; mock.state.secretAll = true
        local out = run()
        mock.state.secretAll = false; mock.state.combat = false
        assertTrue(out:find("game=SECRET", 1, true) ~= nil, out)
        errorLogEmpty(ns); clean()
    end)
end)
