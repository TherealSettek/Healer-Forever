-- Class-aware buff presets with stacking groups: the catalog, the one-per-group rules (radio vs checkbox groups), None, the Self set,
-- missing-buff order and threshold, the examples, and a fuzz proving at most one buff per group is ever stored.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

mock.install()
local ns = {}
local _, _, errs = L.loadContract(ns)
if next(errs) then it("contract loads", function() error(tostring(select(2, next(errs)))) end) return end
local P, C = ns.Presets, ns.Classes

local CASTERS = { "PALADIN", "PRIEST", "MAGE", "DRUID" }
local EMPTY = { "WARRIOR", "ROGUE", "HUNTER", "SHAMAN", "WARLOCK" }
local ALL = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local function groupsOf(set)
    local seen, dup = {}, nil
    for _, k in ipairs(set) do
        local g = C.BuffGroup(k)
        if g then
            if seen[g] then dup = g end
            seen[g] = true
        end
    end
    return dup
end

-- ======================================================================== catalog
describe("buff groups: the catalog", function()
    it("only the four caster classes have a catalog; Warrior, Rogue, Hunter, Shaman and Warlock are empty", function()
        for _, c in ipairs(CASTERS) do assertTrue(#C.BuffCatalog(c) > 0, c) end
        for _, c in ipairs(EMPTY) do assertEquals(#C.BuffCatalog(c), 0, c); assertEquals(#C.CatalogBuffs(c), 0, c) end
        assertEquals(#C.BuffCatalog(nil), 0); assertEquals(#C.BuffCatalog("BOGUS"), 0)
    end)
    it("Paladin: one radio group 'blessing' with six blessings in order", function()
        local cat = C.BuffCatalog("PALADIN")
        assertEquals(#cat, 1); assertEquals(cat[1].id, "blessing"); assertTrue(cat[1].multi)
        assertDeepEquals(cat[1].buffs, { "might", "wisdom", "kings", "salvation", "light", "sanctuary" })
    end)
    it("Priest: three independent checkbox groups; Mage: Intellect checkbox + Magic radio; Druid: two checkbox groups", function()
        local pr = C.BuffCatalog("PRIEST")
        assertEquals(#pr, 3)
        for _, g in ipairs(pr) do assertFalse(g.multi and true or false); assertEquals(#g.buffs, 1) end
        assertDeepEquals(C.CatalogBuffs("PRIEST"), { "fortitude", "spirit", "shadowprot" })
        local mg = C.BuffCatalog("MAGE")
        assertEquals(#mg, 2); assertFalse(mg[1].multi and true or false); assertTrue(mg[2].multi); assertDeepEquals(mg[2].buffs, { "dampen", "amplify" })
        assertDeepEquals(C.CatalogBuffs("MAGE"), { "arcaneint", "dampen", "amplify" })
        assertDeepEquals(C.CatalogBuffs("DRUID"), { "motw", "thorns" })
    end)
    it("every catalog key is a defined buff whose group matches its catalog group, and every buff is in exactly one catalog", function()
        local seen = {}
        for _, class in ipairs(CASTERS) do
            for _, group in ipairs(C.BuffCatalog(class)) do
                assertEquals(type(group.name), "string"); assertTrue(#group.buffs >= 1)
                if group.multi then assertTrue(#group.buffs >= 2, group.id .. ": a radio group needs 2+ buffs") end
                for _, key in ipairs(group.buffs) do
                    local def = C.BUFFS[key]
                    assertNotNil(def, key)
                    assertEquals(def.group, group.id, key .. " group")
                    assertNil(seen[key], key .. " listed twice"); seen[key] = class
                end
            end
        end
        for key in pairs(C.BUFFS) do assertNotNil(seen[key], key .. " is in no catalog") end
    end)
    it("buff defs: key, name, group, abbr, colour, icon, names (single + group spell), greater == groupSpell", function()
        for key, d in pairs(C.BUFFS) do
            assertEquals(d.key, key); assertEquals(type(d.name), "string"); assertEquals(type(d.group), "string"); assertEquals(type(d.abbr), "string")
            assertEquals(type(d.color.r), "number"); assertTrue(d.icon:find("Interface\\Icons\\", 1, true) == 1, key)
            assertEquals(d.names[1], d.name)
            if d.groupSpell then assertEquals(d.names[2], d.groupSpell); assertEquals(d.greater, d.groupSpell) else assertEquals(#d.names, 1, key) end
        end
        assertNil(C.BUFFS.thorns.groupSpell); assertNil(C.BUFFS.dampen.groupSpell); assertEquals(C.BUFFS.arcaneint.groupSpell, "Arcane Brilliance")
        assertEquals(C.BUFFS.motw.groupSpell, "Gift of the Wild"); assertEquals(C.BUFFS.fortitude.groupSpell, "Prayer of Fortitude")
        assertEquals(C.BUFFS.might.groupSpell, "Greater Blessing of Might")
    end)
    it("BuffGroup / BuffOrder: groups by key, a stable global order, 999 for unknown", function()
        assertEquals(C.BuffGroup("might"), "blessing"); assertEquals(C.BuffGroup("dampen"), "magic"); assertEquals(C.BuffGroup("arcaneint"), "intellect")
        assertNil(C.BuffGroup("nope")); assertNil(C.BuffGroup(nil))
        assertEquals(C.BuffOrder("nope"), 999)
        local last = 0
        for _, class in ipairs(CASTERS) do
            for _, k in ipairs(C.CatalogBuffs(class)) do assertTrue(C.BuffOrder(k) > last, k); last = C.BuffOrder(k) end
        end
    end)
    it("every class has roles and a colour; the old Paladin helpers (BUFF_ORDER) still list the six blessings", function()
        assertDeepEquals(C.BUFF_ORDER, { "might", "wisdom", "kings", "salvation", "light", "sanctuary" })
        for _, c in ipairs(ALL) do assertNotNil(C.ROLES[c], c); assertNotNil(C.COLORS[c], c) end
    end)
end)

-- ======================================================================== group rules
describe("buff groups: SetCellBuff / ClearGroup", function()
    local function mk() local p = { name = "x", map = {} }; P.MigratePreset(p); return p end
    it("radio group: picking a blessing replaces the other blessing in the cell", function()
        local p = mk()
        P.SetCellBuff(p, "PALADIN", "DEFAULT", "might", true); assertDeepEquals(p.map.PALADIN.DEFAULT, { "might" })
        P.SetCellBuff(p, "PALADIN", "DEFAULT", "kings", true); assertDeepEquals(p.map.PALADIN.DEFAULT, { "kings" })
        P.SetCellBuff(p, "PALADIN", "DEFAULT", "sanctuary", true); assertDeepEquals(p.map.PALADIN.DEFAULT, { "sanctuary" })
    end)
    it("picking the already chosen radio buff keeps it (never an empty cell by accident)", function()
        local p = mk()
        P.SetCellBuff(p, "PALADIN", "TANK", "might", true); P.SetCellBuff(p, "PALADIN", "TANK", "might", true)
        assertDeepEquals(p.map.PALADIN.TANK, { "might" })
    end)
    it("turning a buff off removes just that buff", function()
        local p = mk()
        P.SetCellBuff(p, "PRIEST", "DEFAULT", "fortitude", true); P.SetCellBuff(p, "PRIEST", "DEFAULT", "spirit", true)
        P.SetCellBuff(p, "PRIEST", "DEFAULT", "fortitude", false)
        assertDeepEquals(p.map.PRIEST.DEFAULT, { "spirit" })
    end)
    it("checkbox groups are independent: Fortitude + Spirit + Shadow Protection stack", function()
        local p = mk()
        for _, k in ipairs({ "shadowprot", "fortitude", "spirit" }) do P.SetCellBuff(p, "PRIEST", "DEFAULT", k, true) end
        assertDeepEquals(p.map.PRIEST.DEFAULT, { "fortitude", "spirit", "shadowprot" }, "kept in catalog order, whatever the click order")
    end)
    it("Mage: Arcane Intellect stacks with one of Dampen / Amplify; Dampen and Amplify exclude each other", function()
        local p = mk()
        P.SetCellBuff(p, "MAGE", "DEFAULT", "arcaneint", true); P.SetCellBuff(p, "MAGE", "DEFAULT", "dampen", true)
        assertDeepEquals(p.map.MAGE.DEFAULT, { "arcaneint", "dampen" })
        P.SetCellBuff(p, "MAGE", "DEFAULT", "amplify", true)
        assertDeepEquals(p.map.MAGE.DEFAULT, { "arcaneint", "amplify" })
    end)
    it("Druid: Mark of the Wild + Thorns stack", function()
        local p = mk()
        P.SetCellBuff(p, "DRUID", "TANK", "motw", true); P.SetCellBuff(p, "DRUID", "TANK", "thorns", true)
        assertDeepEquals(p.map.DRUID.TANK, { "motw", "thorns" })
    end)
    it("None (ClearGroup) removes every buff of that group only", function()
        local p = mk()
        P.SetCellBuff(p, "MAGE", "DEFAULT", "arcaneint", true); P.SetCellBuff(p, "MAGE", "DEFAULT", "amplify", true)
        P.ClearGroup(p, "MAGE", "DEFAULT", "magic")
        assertDeepEquals(p.map.MAGE.DEFAULT, { "arcaneint" })
        P.ClearGroup(p, "MAGE", "DEFAULT", "intellect")
        assertDeepEquals(p.map.MAGE.DEFAULT, {})
        P.ClearGroup(p, "MAGE", "DEFAULT", "magic")
        assertDeepEquals(p.map.MAGE.DEFAULT, {}, "clearing an empty group is a no-op")
    end)
    it("ClearGroup with an unknown group id changes nothing", function()
        local p = mk()
        P.SetCellBuff(p, "PRIEST", "DEFAULT", "fortitude", true)
        P.ClearGroup(p, "PRIEST", "DEFAULT", "bogus")
        assertDeepEquals(p.map.PRIEST.DEFAULT, { "fortitude" })
    end)
    it("a role cell that inherits DEFAULT starts from a COPY of the default set on its first edit", function()
        local p = mk()
        P.SetCellBuff(p, "PRIEST", "DEFAULT", "fortitude", true); P.SetCellBuff(p, "PRIEST", "DEFAULT", "spirit", true)
        assertNil(p.map.PRIEST.HEALER)
        P.SetCellBuff(p, "PRIEST", "HEALER", "shadowprot", true)
        assertDeepEquals(p.map.PRIEST.HEALER, { "fortitude", "spirit", "shadowprot" })
        assertDeepEquals(p.map.PRIEST.DEFAULT, { "fortitude", "spirit" }, "DEFAULT is untouched")
        P.ClearGroup(p, "PRIEST", "HEALER", "spirit")
        assertDeepEquals(p.map.PRIEST.HEALER, { "fortitude", "shadowprot" }); assertDeepEquals(p.map.PRIEST.DEFAULT, { "fortitude", "spirit" })
    end)
    it("an explicit empty role override stays empty (it does not fall back to DEFAULT)", function()
        local p = mk()
        P.SetCellBuff(p, "PALADIN", "DEFAULT", "kings", true)
        P.SetCellBuff(p, "PALADIN", "TANK", "might", true); P.ClearGroup(p, "PALADIN", "TANK", "blessing")
        assertDeepEquals(p.map.PALADIN.TANK, {})
        assertNil(P.ResolveBuff(p, "PALADIN", "TANK")); assertEquals(P.ResolveBuff(p, "PALADIN", "HEALER"), "kings")
    end)
    it("invalid roles / classes / args are refused and change nothing", function()
        local p = mk(); local snap = ns.Util.DeepCopy(p)
        assertEquals(P.SetCellBuff(p, "WARRIOR", "HEALER", "might", true), false)
        assertEquals(P.SetCellBuff(p, "BOGUS", "DEFAULT", "might", true), false)
        assertEquals(P.SetCellBuff(p, "PALADIN", "DEFAULT", nil, true), false)
        assertEquals(P.SetCellBuff(nil, "PALADIN", "DEFAULT", "might", true), false)
        assertEquals(P.ClearGroup(p, "WARRIOR", "HEALER", "blessing"), false)
        assertEquals(P.ClearGroup(nil, "PALADIN", "DEFAULT", "blessing"), false)
        assertTrue(ns.Util.DeepCopy(p) ~= nil); assertTrue(require("framework").deepEq(snap, p))
    end)
    it("a legacy string cell is converted when first edited", function()
        local p = { name = "x", map = { PALADIN = "kings" } }
        P.SetCellBuff(p, "PALADIN", "TANK", "might", true)
        assertEquals(type(p.map.PALADIN), "table"); assertDeepEquals(p.map.PALADIN.DEFAULT, { "kings" }); assertDeepEquals(p.map.PALADIN.TANK, { "might" })
    end)
    it("a buff with an unknown group is allowed and never evicts anything", function()
        local p = mk()
        P.SetCellBuff(p, "PALADIN", "DEFAULT", "might", true); P.SetCellBuff(p, "PALADIN", "DEFAULT", "weirdbuff", true)
        assertEquals(#p.map.PALADIN.DEFAULT, 2)
    end)
end)

describe("buff groups: the Self set", function()
    local function mk() local p = { name = "x", map = {} }; P.MigratePreset(p); return p end
    it("SetSelfBuff follows the same radio/checkbox rules and keeps catalog order", function()
        local p = mk()
        P.SetSelfBuff(p, "might", true); P.SetSelfBuff(p, "kings", true); assertDeepEquals(p.self, { "kings" })
        P.SetSelfBuff(p, "kings", false); assertDeepEquals(p.self, {})
        P.SetSelfBuff(p, "spirit", true); P.SetSelfBuff(p, "fortitude", true); assertDeepEquals(p.self, { "fortitude", "spirit" })
    end)
    it("ClearSelfGroup removes only the group", function()
        local p = mk()
        P.SetSelfBuff(p, "arcaneint", true); P.SetSelfBuff(p, "dampen", true)
        P.ClearSelfGroup(p, "magic"); assertDeepEquals(p.self, { "arcaneint" })
    end)
    it("self wins for the player and an EMPTY self set means 'no buff for me' (while nil means the class/role rules)", function()
        local p = mk()
        P.SetCellBuff(p, "PALADIN", "HEALER", "wisdom", true)
        assertEquals(P.ResolveBuff(p, "PALADIN", "HEALER", true), "wisdom", "nil self: class/role rules")
        P.SetSelfBuff(p, "kings", true)
        assertEquals(P.ResolveBuff(p, "PALADIN", "HEALER", true), "kings"); assertEquals(P.ResolveBuff(p, "PALADIN", "HEALER", false), "wisdom")
        P.ClearSelfGroup(p, "blessing")
        assertNil(P.ResolveBuff(p, "PALADIN", "HEALER", true)); assertDeepEquals(P.CellBuffs(p, "PALADIN", "HEALER", true), {})
        P.SetSelf(p, nil)
        assertEquals(P.ResolveBuff(p, "PALADIN", "HEALER", true), "wisdom")
    end)
    it("OBSERVATION: ClearSelfGroup on a preset with NO self override turns the class/role rules off for the player (self becomes {})", function()
        local p = mk()
        P.SetCellBuff(p, "PALADIN", "HEALER", "wisdom", true)
        P.ClearSelfGroup(p, "blessing")
        if p.self ~= nil then
            warn("Presets.lua ClearSelfGroup: choosing 'None' on the Self cell while self = nil (class/role rules) stores self = {} so the player gets NO buff; "
                .. "intended ('None' = no buff for me) but a one-click change from 'rules' to 'nothing'")
        end
        assertTrue(true)
    end)
    it("garbage args never raise", function()
        assertTrue(pcall(P.SetSelfBuff, nil, "might", true)); assertTrue(pcall(P.SetSelfBuff, {}, nil, true)); assertTrue(pcall(P.ClearSelfGroup, nil, "x"))
        assertEquals(P.SetSelfBuff({}, 5, true), false)
    end)
end)

-- ======================================================================== fuzz
describe("buff groups: fuzz - at most one buff per catalog group is ever stored", function()
    it("5000 random set/clear operations on random classes, roles and the Self set keep every cell valid", function()
        math.randomseed(20260116)
        local keys = {}
        for k in pairs(C.BUFFS) do keys[#keys + 1] = k end
        table.sort(keys)
        local groups = {}
        for _, k in ipairs(keys) do groups[C.BuffGroup(k)] = true end
        local groupList = {}
        for g in pairs(groups) do groupList[#groupList + 1] = g end
        table.sort(groupList)
        local p = { name = "fuzz", map = {} }; P.MigratePreset(p)
        local function checkSet(set, label)
            assertEquals(type(set), "table", label)
            local seen = {}
            for i, k in ipairs(set) do
                assertNotNil(C.BUFFS[k], label .. ": unknown key " .. tostring(k))
                assertNil(seen[k], label .. ": duplicate " .. k); seen[k] = true
                if i > 1 then assertTrue(C.BuffOrder(set[i - 1]) <= C.BuffOrder(k), label .. ": not in catalog order") end
            end
            assertNil(groupsOf(set), label .. ": two buffs of one group stored: " .. table.concat(set, ","))
        end
        for i = 1, 5000 do
            local class = ALL[math.random(#ALL)]
            local roles = { "DEFAULT" }
            for _, r in ipairs(C.ROLES[class]) do roles[#roles + 1] = r end
            local role = roles[math.random(#roles)]
            local roll = math.random(10)
            if roll <= 5 then P.SetCellBuff(p, class, role, keys[math.random(#keys)], true)
            elseif roll == 6 then P.SetCellBuff(p, class, role, keys[math.random(#keys)], false)
            elseif roll == 7 then P.ClearGroup(p, class, role, groupList[math.random(#groupList)])
            elseif roll == 8 then P.SetSelfBuff(p, keys[math.random(#keys)], math.random(2) == 1)
            elseif roll == 9 then P.ClearSelfGroup(p, groupList[math.random(#groupList)])
            else P.SetCellBuff(p, class, ({ "BOGUS", "TANK", "HEALER" })[math.random(3)], keys[math.random(#keys)], true) end
            if i % 50 == 0 then
                for c, entry in pairs(p.map) do
                    for r, set in pairs(entry) do checkSet(set, c .. "." .. r) end
                end
                if p.self then checkSet(p.self, "self") end
            end
        end
        for c, entry in pairs(p.map) do
            assertNotNil(entry.DEFAULT, c .. " keeps a DEFAULT")
            for r, set in pairs(entry) do checkSet(set, c .. "." .. r); assertTrue(P.SetRule(ns.Util.DeepCopy(p), c, r, set[1]) ~= false, c .. "." .. r .. " is a valid role") end
        end
        if p.self then checkSet(p.self, "self") end
    end)
    it("a stored preset survives the real save -> sanitise -> load path with the group rule intact (even if a bad file has two of a group)", function()
        -- the file may hold two blessings in one cell (hand-edited or older addon): loading must not crash and the resolver stays deterministic
        mock.install()
        local n = {}
        local _, _, e = L.loadContract(n)
        assertNil(next(e))
        _G.HealerForeverCharDB = { version = 4, presets = { { name = "Bad", map = { PALADIN = { DEFAULT = { "might", "kings" } } }, extras = {} } } }
        n:Init()
        local cell = n.Presets.CellBuffs(n.db.presets[1], "PALADIN", nil, false)
        assertTrue(#cell >= 1)
        assertEquals(n.Presets.ResolveBuff(n.db.presets[1], "PALADIN", nil, false), cell[1])
        assertEquals(#mock.errors, 0, table.concat(mock.errors, "\n"))
    end)
end)

-- ======================================================================== missing buffs: order + threshold
describe("buff groups: GetMissingBuffs", function()
    local now = 1000
    local function auraFor(key, remaining)
        local d = C.BUFFS[key]
        return { spellId = d.spellIds[1], name = d.name, expirationTime = remaining and (now + remaining) or 0 }
    end
    local preset = { name = "x", map = { PRIEST = { DEFAULT = { "fortitude", "spirit", "shadowprot" } }, PALADIN = { DEFAULT = { "kings" } } } }
    P.MigratePreset(preset)
    it("returns every assigned buff that is absent, in catalog order", function()
        assertDeepEquals(P.GetMissingBuffs("PRIEST", {}, preset, now, C.BUFFS, 60, nil, false), { "fortitude", "spirit", "shadowprot" })
        assertDeepEquals(P.GetMissingBuffs("PRIEST", { auraFor("spirit", 600) }, preset, now, C.BUFFS, 60, nil, false), { "fortitude", "shadowprot" })
    end)
    it("a buff matches by spell id OR by name (names-only buffs such as Priest/Mage/Druid)", function()
        assertDeepEquals(P.GetMissingBuffs("PRIEST", { { name = "Power Word: Fortitude", expirationTime = 0 } }, preset, now, C.BUFFS, 60, nil, false), { "spirit", "shadowprot" })
        assertDeepEquals(P.GetMissingBuffs("PRIEST", { { name = "Prayer of Fortitude", expirationTime = 0 } }, preset, now, C.BUFFS, 60, nil, false), { "spirit", "shadowprot" },
            "the group spell's aura counts too")
        assertDeepEquals(P.GetMissingBuffs("PALADIN", { { spellId = 20217, name = "x", expirationTime = 0 } }, preset, now, C.BUFFS, 60, nil, false), {})
    end)
    it("the 60 second threshold: 59s left counts as missing, 60s and above as present, no expiry as present", function()
        assertDeepEquals(P.GetMissingBuffs("PALADIN", { auraFor("kings", 59) }, preset, now, C.BUFFS, 60, nil, false), { "kings" })
        assertDeepEquals(P.GetMissingBuffs("PALADIN", { auraFor("kings", 60) }, preset, now, C.BUFFS, 60, nil, false), {})
        assertDeepEquals(P.GetMissingBuffs("PALADIN", { auraFor("kings", nil) }, preset, now, C.BUFFS, 60, nil, false), {})
        assertDeepEquals(P.GetMissingBuffs("PALADIN", { auraFor("kings", 10) }, preset, now, C.BUFFS, 0, nil, false), {}, "threshold 0 (warn off): only absence counts")
    end)
    it("an unrelated aura or a buff of another group does not satisfy the cell", function()
        assertDeepEquals(P.GetMissingBuffs("PALADIN", { { name = "Blessing of Might", spellId = 19740, expirationTime = 0 } }, preset, now, C.BUFFS, 60, nil, false), { "kings" })
    end)
    it("GetMissingBuff returns the first one; an empty or unassigned cell returns nothing", function()
        assertEquals(P.GetMissingBuff("PRIEST", {}, preset, now, C.BUFFS, 60, nil, false), "fortitude")
        local empty = { name = "e", map = { MAGE = { DEFAULT = {} } }, extras = {} }
        assertNil(P.GetMissingBuff("MAGE", {}, empty, now, C.BUFFS, 60, nil, false))
        assertDeepEquals(P.GetMissingBuffs("MAGE", {}, empty, now, C.BUFFS, 60, nil, false), {})
        assertDeepEquals(P.GetMissingBuffs("ROGUE", {}, empty, now, C.BUFFS, 60, nil, false), {}, "a class without an entry")
        assertDeepEquals(P.GetMissingBuffs("PRIEST", nil, nil, now, C.BUFFS, 60), {})
    end)
    it("a key missing from the buff defs counts as missing (never crashes)", function()
        local pp = { name = "x", map = { PALADIN = { DEFAULT = { "ghostbuff" } } } }
        assertDeepEquals(P.GetMissingBuffs("PALADIN", {}, pp, now, C.BUFFS, 60, nil, false), { "ghostbuff" })
        assertTrue(pcall(P.GetMissingBuffs, "PALADIN", {}, pp, now, nil, 60, nil, false))
    end)
    it("self uses the self set; the role cell wins over DEFAULT", function()
        local pp = { name = "x", self = { "wisdom" }, map = { PALADIN = { DEFAULT = { "kings" }, TANK = { "might" } } } }
        assertDeepEquals(P.GetMissingBuffs("PALADIN", {}, pp, now, C.BUFFS, 60, "TANK", true), { "wisdom" })
        assertDeepEquals(P.GetMissingBuffs("PALADIN", {}, pp, now, C.BUFFS, 60, "TANK", false), { "might" })
        assertDeepEquals(P.GetMissingBuffs("PALADIN", {}, pp, now, C.BUFFS, 60, "HEALER", false), { "kings" })
    end)
end)

-- ======================================================================== examples
describe("buff groups: Presets.ExampleFor", function()
    it("Paladin, Priest, Mage and Druid have an example; the other classes and nil do not", function()
        for _, c in ipairs(CASTERS) do assertNotNil(P.ExampleFor(c), c) end
        for _, c in ipairs(EMPTY) do assertNil(P.ExampleFor(c), c) end
        assertNil(P.ExampleFor(nil)); assertNil(P.ExampleFor("BOGUS"))
        assertDeepEquals(P.EXAMPLE_CLASSES, { "PALADIN", "PRIEST", "MAGE", "DRUID" })
    end)
    it("every example is a NEW table each call, valid in shape, one per group in every cell, with only the caster's own buffs", function()
        for _, c in ipairs(CASTERS) do
            local a, b = P.ExampleFor(c), P.ExampleFor(c)
            assertTrue(a ~= b and a.map ~= b.map, c .. " fresh copy")
            assertEquals(type(a.name), "string"); assertNotNil(a.name:find("Example", 1, true), a.name)
            local own = {}
            for _, k in ipairs(C.CatalogBuffs(c)) do own[k] = true end
            for _, target in ipairs(ALL) do
                local entry = a.map[target]
                assertEquals(type(entry), "table", c .. " example has an entry for " .. target)
                assertEquals(type(entry.DEFAULT), "table")
                for role, set in pairs(entry) do
                    assertTrue(role == "DEFAULT" or C.IsValidRole(target, role), target .. " " .. role)
                    assertNil(groupsOf(set), c .. " example " .. target .. "." .. role .. " has two buffs of one group")
                    for _, k in ipairs(set) do assertTrue(own[k], c .. " example hands out " .. k .. " which is not " .. c .. "'s own buff") end
                end
            end
        end
    end)
    it("example content: Priest gives Fortitude to everyone, Spirit to non-melee, Shadow Protection to tanks; Mage and Druid likewise", function()
        local pr = P.ExampleFor("PRIEST")
        assertDeepEquals(pr.map.WARRIOR.TANK, { "fortitude", "shadowprot" }); assertDeepEquals(pr.map.WARRIOR.DAMAGER, { "fortitude" })
        assertDeepEquals(pr.map.MAGE.DEFAULT, { "fortitude", "spirit" }); assertDeepEquals(pr.map.ROGUE.DEFAULT, { "fortitude" })
        local mg = P.ExampleFor("MAGE")
        assertDeepEquals(mg.map.PRIEST.HEALER, { "arcaneint", "amplify" }); assertDeepEquals(mg.map.WARRIOR.TANK, { "arcaneint", "dampen" }); assertDeepEquals(mg.map.MAGE.DEFAULT, { "arcaneint" })
        local dr = P.ExampleFor("DRUID")
        assertDeepEquals(dr.map.PALADIN.TANK, { "motw", "thorns" }); assertDeepEquals(dr.map.MAGE.DEFAULT, { "motw" })
        local pa = P.ExampleFor("PALADIN")
        assertEquals(P.ResolveBuff(pa, "PALADIN", "TANK"), "might"); assertEquals(P.ResolveBuff(pa, "PALADIN", "HEALER"), "wisdom")
    end)
    it("an example resolves for every class and role as the caster's buff (no silent gaps)", function()
        for _, c in ipairs({ "PRIEST", "MAGE", "DRUID" }) do
            local e = P.ExampleFor(c)
            for _, target in ipairs(ALL) do
                assertNotNil(P.ResolveBuff(e, target, nil, false), c .. " example gives " .. target .. " nothing")
                for _, r in ipairs(C.ROLES[target]) do assertNotNil(P.ResolveBuff(e, target, r, false), c .. " " .. target .. " " .. r) end
            end
        end
    end)
    it("editing one example never changes the next one", function()
        local a = P.ExampleFor("PRIEST")
        P.SetCellBuff(a, "MAGE", "DEFAULT", "shadowprot", true); a.name = "changed"
        local b = P.ExampleFor("PRIEST")
        assertEquals(b.name, "Example: Priest"); assertDeepEquals(b.map.MAGE.DEFAULT, { "fortitude", "spirit" })
    end)
end)

-- ======================================================================== MigratePreset on set shapes
describe("buff groups: MigratePreset on every cell shape", function()
    it("string -> { key }, 'none' / '' -> {}, array -> cleaned array, duplicates and 'none' entries removed, numbers dropped", function()
        local p = { name = "x", map = { PALADIN = { DEFAULT = "kings", TANK = "none", HEALER = { "wisdom", "wisdom", "none", "", 5 }, DAMAGER = "" } } }
        P.MigratePreset(p)
        assertDeepEquals(p.map.PALADIN.DEFAULT, { "kings" }); assertDeepEquals(p.map.PALADIN.TANK, {})
        assertDeepEquals(p.map.PALADIN.HEALER, { "wisdom" }); assertDeepEquals(p.map.PALADIN.DAMAGER, {})
    end)
    it("is idempotent on sets", function()
        local p = { name = "x", self = { "kings" }, map = { PRIEST = { DEFAULT = { "spirit", "fortitude" } } } }
        P.MigratePreset(p)
        assertDeepEquals(p.map.PRIEST.DEFAULT, { "fortitude", "spirit" }, "migration sorts into catalog order")
        local once = ns.Util.DeepCopy(p)
        P.MigratePreset(p); assertTrue(require("framework").deepEq(once, p))
    end)
end)
