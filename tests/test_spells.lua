-- Pure tests for ns.Spells.BuildList (dynamic spellbook list) and curated-hint forms.
local L = require("loader")
local mock = require("wow_mock")

mock.install()
local ns, missing, errs = L.loadContract({})
local ok, err = pcall(L.loadFile, "Data/Spells.lua", ns)

describe("spells: module loads", function()
    it("Data/Spells.lua loads and exposes ns.Spells.BuildList", function()
        assertTrue(ok, tostring(err))
        assertEquals(type(ns.Spells and ns.Spells.BuildList), "function")
    end)
end)
if not (ns.Spells and ns.Spells.BuildList) then return end
local B = ns.Spells.BuildList

local function e(id, name, extra)
    local t = { spellID = id, name = name, isPassive = false, isKnown = true, icon = id }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
local function names(list) local o = {} for _, s in ipairs(list) do o[#o + 1] = s.name end return o end
local curated = { healing = { "Flash of Light", "Holy Light" }, buffs = { "Blessing of Kings", "Blessing of Might" }, utility = { "Cleanse" } }

describe("spells: BuildList", function()
    it("returns exactly the three groups, empty, for nil / empty input", function()
        for _, input in ipairs({ false, {} }) do
            local r = B(input or nil, curated)
            assertEquals(#r.healing, 0); assertEquals(#r.buffs, 0); assertEquals(#r.other, 0)
        end
        local r = B(nil, nil)
        assertEquals(type(r.healing), "table"); assertEquals(type(r.buffs), "table"); assertEquals(type(r.other), "table")
    end)
    it("categorises by the curated hints; unknown spells go to other", function()
        local r = B({ e(1, "Flash of Light"), e(2, "Blessing of Kings"), e(3, "Cleanse"), e(4, "Light's Vigil"), e(5, "Oath of Light") }, curated)
        assertDeepEquals(names(r.healing), { "Flash of Light" })
        assertDeepEquals(names(r.buffs), { "Blessing of Kings" })
        assertDeepEquals(names(r.other), { "Cleanse", "Light's Vigil", "Oath of Light" })
    end)
    it("skips passives", function()
        local r = B({ e(1, "Flash of Light", { isPassive = true }), e(2, "Holy Light") }, curated)
        assertDeepEquals(names(r.healing), { "Holy Light" })
    end)
    it("skips entries the player does not know (isKnown == false); nil isKnown counts as known", function()
        local r = B({ e(1, "Flash of Light", { isKnown = false }), { spellID = 2, name = "Holy Light", isPassive = false } }, curated)
        assertDeepEquals(names(r.healing), { "Holy Light" })
    end)
    it("dedupes by name keeping the highest spell id", function()
        local r = B({ e(10, "Flash of Light"), e(50, "Flash of Light"), e(30, "Flash of Light") }, curated)
        assertEquals(#r.healing, 1); assertEquals(r.healing[1].spellID, 50)
        r = B({ e(50, "Holy Light"), e(10, "Holy Light") }, curated)
        assertEquals(r.healing[1].spellID, 50)
    end)
    it("a passive duplicate does not displace the active one", function()
        local r = B({ e(10, "Holy Light"), e(99, "Holy Light", { isPassive = true }) }, curated)
        assertEquals(r.healing[1].spellID, 10)
    end)
    it("each group is sorted by name (case-insensitive)", function()
        local r = B({ e(1, "zeal"), e(2, "Alpha"), e(3, "beta"), e(4, "Charlie") }, {})
        assertDeepEquals(names(r.other), { "Alpha", "beta", "Charlie", "zeal" })
        r = B({ e(1, "Holy Light"), e(2, "Flash of Light") }, curated)
        assertDeepEquals(names(r.healing), { "Flash of Light", "Holy Light" })
    end)
    it("entries carry spellID, name and icon", function()
        local r = B({ e(7, "Cleanse", { icon = 4242 }) }, curated)
        assertEquals(r.other[1].spellID, 7); assertEquals(r.other[1].name, "Cleanse"); assertEquals(r.other[1].icon, 4242)
    end)
    it("curated = nil or with missing entries: everything lands in other without error", function()
        local r = B({ e(1, "Flash of Light") }, nil)
        assertEquals(#r.other, 1)
        r = B({ e(1, "Flash of Light") }, { healing = nil, buffs = {} })
        assertEquals(#r.other, 1)
        r = B({ e(1, "Flash of Light") }, { utility = { "Cleanse" } })
        assertEquals(#r.other, 1)
    end)
    it("curated accepts strings, {name=} tables and name sets", function()
        local r = B({ e(1, "A"), e(2, "B"), e(3, "C"), e(4, "D") }, {
            healing = { "A" }, buffs = { { name = "B" } }, utility = { C = true } })
        assertDeepEquals(names(r.healing), { "A" })
        assertDeepEquals(names(r.buffs), { "B" })
        assertDeepEquals(names(r.other), { "C", "D" })
        r = B({ e(1, "A"), e(2, "B") }, { healing = { A = true }, buffs = { B = true } })
        assertEquals(#r.healing, 1); assertEquals(#r.buffs, 1)
    end)
    it("a name in both healing and buffs goes to healing", function()
        local r = B({ e(1, "X") }, { healing = { "X" }, buffs = { "X" } })
        assertEquals(#r.healing, 1); assertEquals(#r.buffs, 0)
    end)
    it("malformed entries are ignored (non-table, missing/empty/non-string name)", function()
        local r = B({ 5, "x", {}, { name = "" }, { name = 5 }, { name = false }, e(1, "Real") }, {})
        assertDeepEquals(names(r.other), { "Real" })
    end)
    it("missing / string spell ids in duplicates do not raise", function()
        assertTrue(pcall(B, { { name = "A" }, { name = "A", spellID = "7" }, { name = "A", spellID = 3 } }, {}))
    end)
    it("does not mutate its inputs", function()
        local raw = { e(1, "Flash of Light"), e(2, "Zed") }
        local cur = { healing = { "Flash of Light" } }
        local a, b = ns.Util.DeepCopy(raw), ns.Util.DeepCopy(cur)
        B(raw, cur)
        assertDeepEquals(raw, a); assertDeepEquals(cur, b)
    end)
    it("large input is processed quickly and totals are preserved", function()
        local raw = {}
        for i = 1, 2000 do raw[#raw + 1] = e(i, "Spell " .. i) end
        local r = B(raw, curated)
        assertEquals(#r.other, 2000)
    end)
end)

describe("spells: Curated hints per class", function()
    for _, c in ipairs({ "PALADIN", "PRIEST", "DRUID", "SHAMAN", "WARRIOR", "MAGE" }) do
        it(c .. " returns the three hint lists of strings", function()
            local h = ns.Spells.Curated(c)
            for _, k in ipairs({ "healing", "buffs", "utility" }) do
                assertEquals(type(h[k]), "table")
                for _, s in ipairs(h[k]) do assertEquals(type(s), "string") end
            end
        end)
    end
    it("unknown class gives empty hints", function()
        local h = ns.Spells.Curated("BOGUS")
        assertEquals(#h.healing + #h.buffs + #h.utility, 0)
    end)
    it("PALADIN hints contain its blessings and its res spell", function()
        local h = ns.Spells.Curated("PALADIN")
        assertTrue(#h.buffs > 0)
        local u = {}
        for _, s in ipairs(h.utility) do u[s] = true end
        assertTrue(u["Redemption"])
    end)
end)
