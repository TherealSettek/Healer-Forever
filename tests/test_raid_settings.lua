-- Raid layout settings (ns.db.raid): defaults, sanitizing bad saved values on load, sparse save (an unchanged raid table is
-- not saved at all; one changed leaf saves only that leaf), the save -> reload round trip, and the hard rule that an older
-- (0.10.1, schema 4) save loads with every party setting unchanged and gets no `raid` key written back.
local mock = require("wow_mock")
local H = require("raid_helpers")
local Fx = require("fixtures")
local L = require("loader")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local deepcopy = H.deepcopy
local FIXTURE = HF_TESTS .. "/fixtures/settings-v0.10.1.lua"

local function clean()
    assertEquals(#mock.errors, 0, H.errstr())
    assertEquals(H.violations(), "")
end

-- logout -> what WoW writes
local function save(ns)
    mock.fire("PLAYER_LOGOUT")
    return deepcopy(_G.HealerForeverCharDB)
end

describe("raid settings: defaults", function()
    it("a fresh character gets ns.DEFAULTS.raid exactly (as a copy)", function()
        local ns = H.boot({ group = 0, seed = false })
        assertDeepEquals(ns.db.raid, ns.DEFAULTS.raid)
        assertTrue(ns.db.raid ~= ns.DEFAULTS.raid and ns.db.raid.point ~= ns.DEFAULTS.raid.point and ns.db.raid.buffs ~= ns.DEFAULTS.raid.buffs,
            "runtime tables are copies (a drag must not change the defaults)")
        clean()
    end)
    it("no schema bump: DEFAULTS.version stays 4", function()
        local ns = H.boot({ group = 0, seed = false })
        assertEquals(ns.DEFAULTS.version, 4)
    end)
end)

describe("raid settings: sanitizing bad saved values", function()
    it("bad values fall back to the default, good ones are kept, the addon boots clean", function()
        local char = { version = 4, raid = { layoutMode = "sometimes", onlyAbove5 = "no", scale = 999, width = "wide", height = 0 / 0,
            spacing = -1, groupArrange = "diagonal", groupsPerLine = 5, sortWithin = "class", point = { point = 5 },
            buffs = "none", debuffs = { max = 7, display = "letters", show = false } } }
        local ns = H.boot({ group = 4, char = char })
        clean()
        local r = ns.db.raid
        assertEquals(r.layoutMode, "auto"); assertEquals(r.onlyAbove5, true); assertEquals(r.scale, 150); assertEquals(r.width, 64)
        assertEquals(r.height, 24); assertEquals(r.spacing, 0); assertEquals(r.groupArrange, "columns"); assertEquals(r.groupsPerLine, 8)
        assertEquals(r.sortWithin, "class", "a good value survives next to bad ones")
        assertDeepEquals(r.point, ns.DEFAULTS.raid.point)
        assertDeepEquals(r.buffs, ns.DEFAULTS.raid.buffs)
        assertEquals(r.debuffs.max, 3); assertEquals(r.debuffs.display, "glowIcons"); assertEquals(r.debuffs.show, false)
    end)
    it("a raid key that is not a table at all is replaced by the defaults", function()
        for _, bad in ipairs({ "raid", 5, true }) do
            local ns = H.boot({ group = 0, char = { version = 4, raid = bad } })
            assertDeepEquals(ns.db.raid, ns.DEFAULTS.raid)
            clean()
        end
    end)
end)

describe("raid settings: sparse save and reload", function()
    it("unchanged raid settings are not saved (no `raid` key)", function()
        local ns = H.boot({ group = 4, raid = 10 })
        assertNil(ns:BuildSaveTable().raid)
        assertNil(save(ns).raid)
    end)
    it("one changed leaf saves only that leaf", function()
        local ns = H.boot({ group = 4 })
        ns.db.raid.width = 90
        assertDeepEquals(ns:BuildSaveTable().raid, { width = 90 })
        ns.db.raid.width = 64
        ns.db.raid.buffs.inCombat = "dim"
        assertDeepEquals(ns:BuildSaveTable().raid, { buffs = { inCombat = "dim" } })
    end)
    it("the point is atomic: a moved frame saves the whole point", function()
        local ns = H.boot({ group = 4 })
        ns.db.raid.point.x = 200
        assertDeepEquals(ns:BuildSaveTable().raid, { point = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 200, y = -330 } })
    end)
    it("save -> reload gives the same raid settings and they apply (layout mode, size, scale)", function()
        local ns = H.boot({ group = 4 })
        ns.db.raid.layoutMode = "raid"; ns.db.raid.width = 80; ns.db.raid.scale = 75; ns.db.raid.groupArrange = "rows"
        ns.db.raid.debuffs.max = 2
        local saved = save(ns)
        local want = deepcopy(ns.db.raid)
        local ns2 = H.boot({ group = 4, char = saved })
        clean()
        assertDeepEquals(ns2.db.raid, want)
        assertEquals(ns2.RaidFrames.active, "raid")
        assertEquals(rawget(ns2.RaidFrames.anchor, "__s").scale, 0.75)
        assertEquals(rawget(ns2.RaidFrames.buttons[1], "__s").w, 80)
        -- and a second reload is stable
        local ns3 = H.boot({ group = 4, char = save(ns2) })
        assertDeepEquals(ns3.db.raid, want)
        assertDeepEquals(save(ns3), saved)
    end)
    it("/hf raid party is saved and survives a reload", function()
        local ns = H.boot({ group = 4 })
        H.slash("raid party")
        local saved = save(ns)
        assertDeepEquals(saved.raid, { layoutMode = "party" })
        local ns2 = H.boot({ group = 4, char = saved, raid = 25 })
        assertEquals(ns2.RaidFrames.active, "party")
        clean()
    end)
end)

describe("raid settings: a 0.10.1 save upgrades without changes", function()
    it("the synthetic 0.10.1 fixture has no raid key and loads the raid defaults", function()
        local raw = Fx.loadSaved(FIXTURE, "HealerForeverCharDB")
        assertNil(raw.raid)
        local ns = H.boot({ group = 4, char = raw })
        clean()
        assertDeepEquals(ns.db.raid, ns.DEFAULTS.raid)
    end)
    -- 0.10.1 itself already fills missing class rows of old presets on load (Presets migration), so the written-back
    -- presets can hold MORE than the fixture; everything the fixture saved must be there with the same value, and every
    -- other top-level key must be byte-identical (checked against the 0.10.1 build by hand: same output).
    it("every saved key keeps its value and the save written back has no raid key and the same version", function()
        local raw = Fx.loadSaved(FIXTURE, "HealerForeverCharDB")
        local ns = H.boot({ group = 4, char = raw })
        local out = ns:BuildSaveTable()
        assertNil(out.raid)
        assertEquals(out.version, raw.version)
        local function subset(a, b, path)
            for k, v in pairs(a) do
                if type(v) == "table" and type(b[k]) == "table" then subset(v, b[k], path .. "." .. tostring(k))
                elseif type(v) == "table" and next(v) == nil and b[k] == nil then -- empty errorLog / marks are not written
                else assertEquals(b[k], v, path .. "." .. tostring(k)) end
            end
        end
        subset(raw, out, "")
        for k, v in pairs(out) do
            if k ~= "presets" then assertDeepEquals(v, raw[k], "top-level key " .. tostring(k) .. " changed") end
        end
        local twice = H.boot({ group = 4, char = save(ns) })
        assertDeepEquals(twice:BuildSaveTable(), out, "stable after a second reload")
        clean()
    end)
end)
