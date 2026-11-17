-- Class + role buff presets with SELF override: pure-function tests (smoke part is in test_roles_smoke.lua).
local L = require("loader")
local mock = require("wow_mock")

mock.install()
local ns, missing, errs = L.loadContract({})

local ROLES = {
    WARRIOR = { "TANK", "DAMAGER" }, PALADIN = { "TANK", "HEALER", "DAMAGER" }, HUNTER = { "DAMAGER" },
    ROGUE = { "DAMAGER" }, PRIEST = { "HEALER", "DAMAGER" }, SHAMAN = { "HEALER", "DAMAGER" },
    MAGE = { "DAMAGER" }, WARLOCK = { "DAMAGER" }, DRUID = { "TANK", "HEALER", "DAMAGER" },
}
local ALL_ROLES = { "TANK", "HEALER", "DAMAGER" }
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local P = ns.Presets

describe("roles: contract files load", function()
    it("load without errors", function()
        local m = {}
        for f, e in pairs(errs) do m[#m + 1] = f .. ": " .. e end
        assertEquals(#m, 0, table.concat(m, "\n"))
        assertEquals(#missing, 0)
    end)
    it("Presets.ResolveBuff / MigratePreset / SetRule / SetSelf exist", function()
        for _, f in ipairs({ "ResolveBuff", "MigratePreset", "SetRule", "SetSelf" }) do
            assertEquals(type(P and P[f]), "function", "ns.Presets." .. f)
        end
    end)
end)

if not (P and P.ResolveBuff) then return end

describe("roles: Classes.ROLES", function()
    for _, c in ipairs(CLASSES) do
        it(c .. " valid roles", function()
            local got = {}
            for _, r in ipairs(ns.Classes.ROLES[c] or {}) do got[r] = true end
            local want = {}
            for _, r in ipairs(ROLES[c]) do want[r] = true end
            assertDeepEquals(got, want)
        end)
    end
end)

describe("roles: ResolveBuff", function()
    local R = P.ResolveBuff
    -- reference implementation of the contract
    local function ref(preset, class, role, isSelf)
        if not preset or not preset.map or not preset.map[class] then return nil end
        local key
        if isSelf and preset.self then key = preset.self
        else
            local entry = preset.map[class]
            local valid = false
            for _, r in ipairs(ROLES[class]) do if r == role then valid = true end end
            key = (valid and entry[role]) or entry.DEFAULT
        end
        if key == "none" then return nil end
        return key
    end

    it("full matrix: class x role x isSelf x self set/unset x role-entry set/unset", function()
        local n = 0
        for _, class in ipairs(CLASSES) do
            for _, role in ipairs({ "TANK", "HEALER", "DAMAGER", "NONE", "BOGUS" }) do
                for _, isSelf in ipairs({ true, false }) do
                    for _, selfKey in ipairs({ "kings", false }) do
                        for _, roleSet in ipairs({ "might", "none", false }) do
                            local entry = { DEFAULT = "wisdom" }
                            for _, r in ipairs(ROLES[class]) do if roleSet then entry[r] = roleSet end end
                            local preset = { name = "T", self = selfKey or nil, map = { [class] = entry } }
                            local got = R(preset, class, role, isSelf)
                            local want = ref(preset, class, role, isSelf)
                            if got ~= want then
                                error(string.format("class=%s role=%s isSelf=%s self=%s roleSet=%s: want %s got %s", class, role,
                                    tostring(isSelf), tostring(selfKey), tostring(roleSet), tostring(want), tostring(got)))
                            end
                            n = n + 1
                        end
                    end
                end
            end
        end
        assertTrue(n > 500)
    end)
    it("self used only when isSelf and preset.self set", function()
        local p = { self = "kings", map = { PALADIN = { DEFAULT = "might", HEALER = "wisdom" } } }
        assertEquals(R(p, "PALADIN", "HEALER", true), "kings")
        assertEquals(R(p, "PALADIN", "HEALER", false), "wisdom")
        assertEquals(R(p, "PALADIN", "HEALER", nil), "wisdom")
        p.self = nil
        assertEquals(R(p, "PALADIN", "HEALER", true), "wisdom")
    end)
    it("role entry beats DEFAULT; DEFAULT used when role entry unset", function()
        local p = { map = { PALADIN = { DEFAULT = "might", TANK = "kings" } } }
        assertEquals(R(p, "PALADIN", "TANK"), "kings")
        assertEquals(R(p, "PALADIN", "HEALER"), "might")
        assertEquals(R(p, "PALADIN", "DAMAGER"), "might")
    end)
    it("role nil / NONE / unknown -> DEFAULT", function()
        local p = { map = { PALADIN = { DEFAULT = "might", TANK = "kings" } } }
        assertEquals(R(p, "PALADIN", nil), "might")
        assertEquals(R(p, "PALADIN", "NONE"), "might")
        assertEquals(R(p, "PALADIN", "WHATEVER"), "might")
        assertEquals(R(p, "PALADIN", ""), "might")
    end)
    it("a role entry for a role invalid for the class is ignored (DEFAULT used)", function()
        local p = { map = { HUNTER = { DEFAULT = "might", TANK = "kings", HEALER = "wisdom" } } }
        assertEquals(R(p, "HUNTER", "TANK"), "might")
        assertEquals(R(p, "HUNTER", "HEALER"), "might")
        assertEquals(R(p, "HUNTER", "DAMAGER"), "might")
    end)
    it("'none' -> nil (role entry, DEFAULT, and none overriding DEFAULT)", function()
        local p = { map = { PALADIN = { DEFAULT = "might", TANK = "none" }, MAGE = { DEFAULT = "none" } } }
        assertNil(R(p, "PALADIN", "TANK"))
        assertEquals(R(p, "PALADIN", "HEALER"), "might")
        assertNil(R(p, "MAGE", "DAMAGER")); assertNil(R(p, "MAGE", nil))
    end)
    it("unknown class / nil class -> nil", function()
        local p = { map = { PALADIN = { DEFAULT = "might" } } }
        assertNil(R(p, "BOGUS", "TANK")); assertNil(R(p, nil, "TANK")); assertNil(R(p, "WARRIOR", "TANK"))
    end)
    it("nil preset / nil map -> nil, no raise", function()
        assertNil(R(nil, "PALADIN", "TANK", true))
        assertNil(R({}, "PALADIN", "TANK", false))
        assertNil(R({ name = "x" }, "PALADIN", nil, nil))
    end)
    it("corrupted map values (number/string/boolean) do not raise", function()
        for _, bad in ipairs({ 5, "kings", true, false }) do
            local ok, r = pcall(R, { map = { PALADIN = bad } }, "PALADIN", "TANK", false)
            assertTrue(ok, tostring(bad) .. ": " .. tostring(r))
            assertTrue(r == nil or type(r) == "string")
        end
        local ok = pcall(R, { map = "x" }, "PALADIN", "TANK")
        assertTrue(ok)
        ok = pcall(R, { map = { PALADIN = { DEFAULT = 5, TANK = {} } } }, "PALADIN", "TANK")
        assertTrue(ok)
    end)
    it("does not mutate the preset", function()
        local p = { self = "kings", map = { PALADIN = { DEFAULT = "might", TANK = "none" } } }
        local snap = ns.Util.DeepCopy(p)
        R(p, "PALADIN", "TANK", true); R(p, "PALADIN", "HEALER", false)
        assertDeepEquals(p, snap)
    end)
end)

describe("roles: GetMissingBuff with role / isSelf", function()
    local defs = {
        might = { spellIds = { 19740 }, names = { "Blessing of Might" } },
        wisdom = { spellIds = { 19742 }, names = { "Blessing of Wisdom" } },
        kings = { spellIds = { 20217 }, names = { "Blessing of Kings" } },
    }
    local preset = { name = "T", self = "kings", map = { PALADIN = { DEFAULT = "might", TANK = "might", HEALER = "wisdom" }, WARRIOR = { DEFAULT = "kings" } } }
    local now = 1000
    local function miss(class, auras, role, isSelf, thr) return P.GetMissingBuff(class, auras, preset, now, defs, thr, role, isSelf) end
    it("old 6-arg calls use DEFAULT", function()
        assertEquals(P.GetMissingBuff("PALADIN", {}, preset, now, defs), "might")
        assertEquals(P.GetMissingBuff("PALADIN", {}, preset, now, defs, 60), "might")
    end)
    it("role selects the buff", function()
        assertEquals(miss("PALADIN", {}, "HEALER"), "wisdom")
        assertEquals(miss("PALADIN", {}, "TANK"), "might")
        assertEquals(miss("PALADIN", {}, "DAMAGER"), "might")
    end)
    it("self override wins only for isSelf", function()
        assertEquals(miss("PALADIN", {}, "HEALER", true), "kings")
        assertEquals(miss("PALADIN", {}, "HEALER", false), "wisdom")
    end)
    it("having the resolved buff -> nil; having a different one still missing", function()
        local wis = { { spellId = 19742, name = "Blessing of Wisdom", expirationTime = 0 } }
        assertNil(miss("PALADIN", wis, "HEALER"))
        assertEquals(miss("PALADIN", wis, "TANK"), "might")
        assertEquals(miss("PALADIN", wis, "HEALER", true), "kings")
    end)
    it("expiring resolved buff -> key", function()
        assertEquals(miss("PALADIN", { { spellId = 19742, name = "x", expirationTime = now + 10 } }, "HEALER"), "wisdom")
    end)
    it("'none' resolution -> nil", function()
        local p2 = { map = { PALADIN = { DEFAULT = "none" } } }
        assertNil(P.GetMissingBuff("PALADIN", {}, p2, now, defs, 60, "TANK", false))
    end)
    it("role given but class has no entry -> nil", function() assertNil(miss("MAGE", {}, "DAMAGER")) end)
end)

describe("roles: MigratePreset", function()
    local M = P.MigratePreset
    it("old string map becomes { DEFAULT = string }", function()
        local p = { name = "Old", map = { PALADIN = "kings", WARRIOR = "might" } }
        M(p)
        assertEquals(type(p.map.PALADIN), "table"); assertDeepEquals(p.map.PALADIN.DEFAULT, { "kings" })
        assertDeepEquals(p.map.WARRIOR.DEFAULT, { "might" })
        assertDeepEquals(p.map.PALADIN, { DEFAULT = { "kings" } }, "migration must not invent role overrides")
        assertDeepEquals(p.map.WARRIOR, { DEFAULT = { "might" } })
    end)
    it("fills a missing DEFAULT for every class", function()
        local p = { name = "Old", map = { PALADIN = "kings" } }
        M(p)
        for _, c in ipairs(CLASSES) do
            assertEquals(type(p.map[c]), "table", c)
            assertNotNil(p.map[c].DEFAULT, c .. " DEFAULT")
        end
        assertDeepEquals(p.map.PALADIN.DEFAULT, { "kings" })
    end)
    it("missing DEFAULT fills with 'none' (no buff) in a table entry that lacks it", function()
        local p = { name = "x", map = { PALADIN = { TANK = "might" } } }
        M(p)
        assertDeepEquals(p.map.PALADIN.DEFAULT, {}, "an empty set = no buff")
        assertDeepEquals(p.map.PALADIN.TANK, { "might" })
        assertNil(P.ResolveBuff(p, "PALADIN", "HEALER"), "unset DEFAULT must not invent a buff")
    end)
    it("is idempotent", function()
        local p = { name = "Old", self = "kings", map = { PALADIN = "kings", DRUID = { DEFAULT = "wisdom", TANK = "might" } } }
        M(p)
        local once = ns.Util.DeepCopy(p)
        M(p)
        assertDeepEquals(p, once)
        M(p); assertDeepEquals(p, once)
    end)
    it("preserves valid role overrides and self, and the name", function()
        local p = { name = "N", self = "light", map = { PALADIN = { DEFAULT = "might", HEALER = "wisdom" } } }
        M(p)
        assertEquals(p.name, "N"); assertDeepEquals(p.self, { "light" })
        assertDeepEquals(p.map.PALADIN.HEALER, { "wisdom" }); assertDeepEquals(p.map.PALADIN.DEFAULT, { "might" })
    end)
    it("nil / garbage input does not raise", function()
        assertTrue(pcall(M, nil)); assertTrue(pcall(M, {})); assertTrue(pcall(M, { map = "x" }))
        assertTrue(pcall(M, { map = { PALADIN = 5, WARRIOR = true } }))
        assertTrue(pcall(M, "str"))
    end)
    it("corrupted class values become usable tables", function()
        local p = { name = "x", map = { PALADIN = 5, WARRIOR = false } }
        M(p)
        assertEquals(type(p.map.PALADIN), "table"); assertEquals(type(p.map.WARRIOR), "table")
    end)
    it("missing map gets created", function()
        local p = { name = "x" }
        M(p)
        assertEquals(type(p.map), "table")
        assertNotNil(p.map.PALADIN)
    end)
end)

describe("roles: SetRule / SetSelf", function()
    local function mk() local p = { name = "x", map = {} }; P.MigratePreset(p); return p end
    it("sets a role override on a valid role", function()
        local p = mk()
        assertTrue(P.SetRule(p, "PALADIN", "TANK", "might"))
        assertDeepEquals(p.map.PALADIN.TANK, { "might" })
        assertEquals(P.ResolveBuff(p, "PALADIN", "TANK"), "might")
    end)
    it("sets DEFAULT", function()
        local p = mk()
        assertTrue(P.SetRule(p, "MAGE", "DEFAULT", "kings"))
        assertDeepEquals(p.map.MAGE.DEFAULT, { "kings" })
    end)
    for _, c in ipairs(CLASSES) do
        for _, r in ipairs(ALL_ROLES) do
            local valid = false
            for _, v in ipairs(ROLES[c]) do if v == r then valid = true end end
            it("SetRule(" .. c .. ", " .. r .. ") " .. (valid and "accepted" or "refused (false), unchanged"), function()
                local p = mk()
                local snap = ns.Util.DeepCopy(p)
                local res = P.SetRule(p, c, r, "kings")
                if valid then assertTrue(res); assertDeepEquals(p.map[c][r], { "kings" })
                else assertEquals(res, false); assertDeepEquals(p, snap) end
            end)
        end
    end
    it("nil or 'none' clears a role override", function()
        local p = mk()
        P.SetRule(p, "PALADIN", "TANK", "might")
        P.SetRule(p, "PALADIN", "TANK", nil)
        assertNil(p.map.PALADIN.TANK)
        P.SetRule(p, "PALADIN", "HEALER", "wisdom")
        P.SetRule(p, "PALADIN", "HEALER", "none")
        assertNil(p.map.PALADIN.HEALER, "'none' must clear (not store) a role override")
    end)
    it("clearing DEFAULT stores an empty set (no buff)", function()
        local p = mk()
        P.SetRule(p, "PALADIN", "DEFAULT", "might")
        P.SetRule(p, "PALADIN", "DEFAULT", nil)
        assertDeepEquals(p.map.PALADIN.DEFAULT, {}, "an empty set means 'no buff'")
        P.SetRule(p, "PALADIN", "DEFAULT", "might")
        P.SetRule(p, "PALADIN", "DEFAULT", "none")
        assertDeepEquals(p.map.PALADIN.DEFAULT, {})
        assertNil(P.ResolveBuff(p, "PALADIN", nil))
    end)
    it("unknown class / role / nil args do not raise", function()
        local p = mk()
        for _, args in ipairs({ { "BOGUS", "TANK", "x" }, { "PALADIN", "BOGUS", "x" }, { nil, nil, nil }, { "PALADIN", nil, "x" } }) do
            local ok, r = pcall(P.SetRule, p, args[1], args[2], args[3])
            assertTrue(ok, tostring(r)); assertTrue(not r)
        end
        assertTrue(pcall(P.SetRule, nil, "PALADIN", "TANK", "x"))
    end)
    it("SetSelf sets and clears", function()
        local p = mk()
        P.SetSelf(p, "kings"); assertDeepEquals(p.self, { "kings" })
        P.SetSelf(p, nil); assertNil(p.self)
        assertTrue(pcall(P.SetSelf, nil, "x"))
    end)
    it("SetSelf('none') either clears or stores an empty set and resolves to no buff", function()
        local p = mk()
        P.SetRule(p, "PALADIN", "DEFAULT", "might")
        P.SetSelf(p, "none")
        assertTrue(p.self == nil or (type(p.self) == "table" and #p.self == 0), "cleared or an empty set")
        if p.self ~= nil then assertNil(P.ResolveBuff(p, "PALADIN", nil, true), "an empty self set resolves to no buff") end
    end)
end)

describe("roles: shipped defaults are blank; the Paladin example carries the old 5-man rules", function()
    local function validEntry(c, e, buffs)
        assertEquals(type(e), "table", c)
        for role, key in pairs(e) do
            assertTrue(role == "DEFAULT" or (function() for _, r in ipairs(ROLES[c]) do if r == role then return true end end end)(),
                "invalid role " .. tostring(role) .. " for " .. c)
            assertEquals(type(key), "table", "a cell is a set of buff keys")
            for _, k in ipairs(key) do assertTrue(buffs[k] ~= nil, "unknown buff key " .. tostring(k)) end
        end
    end
    it("the shipped default is one blank preset that assigns no buff to anyone", function()
        assertEquals(#P.DEFAULTS, 1)
        assertEquals(next(P.DEFAULTS[1].map), nil)
        for _, c in ipairs(CLASSES) do
            assertNil(P.ResolveBuff(P.DEFAULTS[1], c, nil, false), c)
            for _, r in ipairs(ROLES[c]) do assertNil(P.ResolveBuff(P.DEFAULTS[1], c, r, true)) end
        end
    end)
    it("after Init the default preset has a 'none' DEFAULT for every class (no buff anywhere)", function()
        mock.install()
        local n = L.loadContract({})
        mock.fire("ADDON_LOADED", "HealerForever")
        for _, c in ipairs(CLASSES) do assertDeepEquals(n.db.presets[1].map[c].DEFAULT, {}, c) end
    end)
    it("ExamplePaladin: v2 tables with DEFAULT for every class and valid roles/buff keys", function()
        local buffs = ns.Classes.BUFFS
        local p = P.ExamplePaladin()
        for _, c in ipairs(CLASSES) do
            validEntry(c, p.map[c], buffs)
            assertNotNil(p.map[c].DEFAULT, c .. " DEFAULT")
        end
        if p.self then for _, k in ipairs(p.self) do assertTrue(buffs[k] ~= nil, k) end end
    end)
    it("in the Paladin example PALADIN TANK resolves to might and PALADIN HEALER to wisdom", function()
        local p = P.ExamplePaladin()
        assertEquals(P.ResolveBuff(p, "PALADIN", "TANK"), "might")
        assertEquals(P.ResolveBuff(p, "PALADIN", "HEALER"), "wisdom")
        assertNotNil(p.name:find("5"))
    end)
    it("ExamplePaladin returns a NEW table every call (mutating one never changes the template)", function()
        local a, b = P.ExamplePaladin(), P.ExamplePaladin()
        assertTrue(a ~= b and a.map ~= b.map and a.map.PALADIN ~= b.map.PALADIN)
        a.map.PALADIN.TANK = { "kings" }; a.name = "x"
        assertDeepEquals(b.map.PALADIN.TANK, { "might" }); assertDeepEquals(P.ExamplePaladin().map.PALADIN.TANK, { "might" })
    end)
end)

-- ------------------------------------------------------------------ Init migration (v1 -> v2)
describe("roles: Init migrates a v1 DB", function()
    local function doInit(db)
        mock.install()
        local n, _, e = L.loadContract({})
        if next(e) then error(select(2, next(e))) end
        _G.HealerForeverCharDB = db
        mock.fire("ADDON_LOADED", "HealerForever")
        assertEquals(#mock.errors, 0, table.concat(mock.errors, "\n"))
        return n
    end
    local function v1()
        return { version = 1, activePreset = 1, presets = {
            { name = "Old A", map = { PALADIN = "kings", WARRIOR = "might", MAGE = "wisdom" } },
            { name = "Old B", map = { PALADIN = "light" } },
        } }
    end
    it("string maps become v2 tables, user values kept", function()
        local n = doInit(v1())
        local db = _G.HealerForeverCharDB
        assertEquals(type(db.presets[1].map.PALADIN), "table")
        assertDeepEquals(db.presets[1].map.PALADIN.DEFAULT, { "kings" })
        assertDeepEquals(db.presets[1].map.WARRIOR.DEFAULT, { "might" })
        assertEquals(db.presets[2].name, "Old B")
        assertDeepEquals(db.presets[2].map.PALADIN.DEFAULT, { "light" })
        assertEquals(n.Presets.ResolveBuff(db.presets[1], "PALADIN", "TANK"), "kings")
    end)
    it("version is bumped past 1", function()
        doInit(v1())
        assertTrue(_G.HealerForeverCharDB.version > 1)
    end)
    it("every class has a DEFAULT after migration", function()
        doInit(v1())
        for _, p in ipairs(_G.HealerForeverCharDB.presets) do
            for _, c in ipairs(CLASSES) do assertNotNil(p.map[c] and p.map[c].DEFAULT, c) end
        end
    end)
    it("invalid role keys and unknown buff keys are dropped", function()
        local db = { version = 2, presets = { { name = "X", self = "bogusbuff", map = {
            PALADIN = { DEFAULT = "kings", TANK = "nonexistent", HEALER = "wisdom", BOGUSROLE = "might" },
            HUNTER = { DEFAULT = "might", TANK = "kings", HEALER = "wisdom" },
            MAGE = { DEFAULT = "doesnotexist" },
            BOGUSCLASS = { DEFAULT = "kings" },
        } } } }
        doInit(db)
        local p = _G.HealerForeverCharDB.presets[1]
        assertNil(p.map.PALADIN.TANK, "unknown buff key must be dropped")
        assertNil(p.map.PALADIN.BOGUSROLE, "invalid role key must be dropped")
        assertDeepEquals(p.map.PALADIN.HEALER, { "wisdom" })
        assertNil(p.map.HUNTER.TANK); assertNil(p.map.HUNTER.HEALER)
        for _, k in ipairs(p.map.MAGE.DEFAULT or {}) do assertTrue(ns.Classes.BUFFS[k] ~= nil, "unknown buff key must be dropped: " .. tostring(k)) end
        for _, k in ipairs(p.self or {}) do assertTrue(ns.Classes.BUFFS[k] ~= nil, "unknown self key must be dropped: " .. tostring(k)) end
    end)
    it("migration is idempotent across a second Init", function()
        local n = doInit(v1())
        local snap = n.Util.DeepCopy(_G.HealerForeverCharDB)
        n:Init()
        assertDeepEquals(_G.HealerForeverCharDB, snap)
    end)
    it("corrupted preset maps (class value number/string) recover without error", function()
        doInit({ version = 1, presets = { { name = "C", map = { PALADIN = 5, WARRIOR = {}, MAGE = "kings", HUNTER = true } } } })
        local p = _G.HealerForeverCharDB.presets[1]
        for _, c in ipairs(CLASSES) do assertEquals(type(p.map[c]), "table", c) end
        assertDeepEquals(p.map.MAGE.DEFAULT, { "kings" })
    end)
    it("roleOverrides is a table after Init and survives corruption", function()
        doInit({ roleOverrides = "x" })
        assertTrue(_G.HealerForeverCharDB.roleOverrides == nil or type(_G.HealerForeverCharDB.roleOverrides) == "table")
        doInit({ roleOverrides = { ["Bob-Realm"] = "TANK" } })
        assertEquals(_G.HealerForeverCharDB.roleOverrides["Bob-Realm"], "TANK")
    end)
end)

-- ------------------------------------------------------------------ role buffs (extras)
describe("extras: ResolveExtras", function()
    local R = P.ResolveExtras
    local oath = { spell = "Oath of Light", roles = { TANK = true }, single = true }
    local both = { spell = "Both", roles = { TANK = true, HEALER = true } }
    local selfOnly = { spell = "Mine", roles = { SELF = true } }
    local preset = { extras = { oath, both, selfOnly } }
    local function spells(list) local o = {} for _, e in ipairs(list) do o[#o + 1] = e.spell end return o end
    it("returns the entries matching the role", function()
        assertDeepEquals(spells(R(preset, "TANK", false)), { "Oath of Light", "Both" })
        assertDeepEquals(spells(R(preset, "HEALER", false)), { "Both" })
        assertDeepEquals(spells(R(preset, "DAMAGER", false)), {})
    end)
    it("SELF only when roles.SELF is set", function()
        assertDeepEquals(spells(R(preset, "HEALER", true)), { "Mine" })
        assertDeepEquals(spells(R({ extras = { oath } }, "TANK", true)), {}, "TANK-only entry must not match isSelf")
        assertDeepEquals(spells(R({ extras = { selfOnly } }, "TANK", false)), {}, "SELF entry must not match other members")
    end)
    it("role nil / NONE / unknown matches nothing", function()
        for _, r in ipairs({ "NONE", "BOGUS", "" }) do assertEquals(#R(preset, r, false), 0) end
        assertEquals(#R(preset, nil, false), 0)
    end)
    it("returns the entry objects themselves (identity preserved)", function()
        assertTrue(R(preset, "TANK", false)[1] == oath)
    end)
    it("nil preset / missing extras / corrupted entries -> empty, no raise", function()
        assertEquals(#R(nil, "TANK", false), 0); assertEquals(#R({}, "TANK", false), 0)
        assertEquals(#R({ extras = "x" }, "TANK", false), 0)
        local ok, r = pcall(R, { extras = { 5, "x", {}, { roles = "TANK" }, { roles = { TANK = true } } } }, "TANK", false)
        assertTrue(ok, tostring(r)); assertEquals(#r, 1)
    end)
    it("always returns a table", function() assertEquals(type(R(nil, nil, nil)), "table") end)
end)

describe("extras: GetMissingExtra", function()
    local G = P.GetMissingExtra
    local now = 1000
    local entry = { spell = "Oath of Light", roles = { TANK = true }, single = false }
    local function aura(id, name, exp) return { spellId = id, name = name, expirationTime = exp } end
    it("no aura / nil auras -> missing", function() assertTrue(G(entry, {}, now, 60)); assertTrue(G(entry, nil, now, 60)) end)
    it("matches by name", function() assertFalse(G(entry, { aura(1, "Oath of Light", now + 500) }, now, 60)) end)
    it("matches by spellId", function()
        local e = { spell = "Other Name", spellId = 77, roles = {} }
        assertFalse(G(e, { aura(77, "whatever", now + 500) }, now, 60))
    end)
    it("same threshold rules: <60s missing, >=60s present, 0 = permanent", function()
        assertTrue(G(entry, { aura(1, "Oath of Light", now + 30) }, now, 60))
        assertFalse(G(entry, { aura(1, "Oath of Light", now + 120) }, now, 60))
        assertFalse(G(entry, { aura(1, "Oath of Light", 0) }, now, 60))
        assertTrue(G(entry, { aura(1, "Oath of Light", now - 5) }, now, 60), "already expired")
    end)
    it("exactly at the threshold counts as present (>=), one second less as missing", function()
        assertFalse(G(entry, { aura(1, "Oath of Light", now + 60) }, now, 60))
        assertTrue(G(entry, { aura(1, "Oath of Light", now + 59) }, now, 60))
    end)
    it("default threshold is 60 and a custom threshold is honoured", function()
        assertTrue(G(entry, { aura(1, "Oath of Light", now + 59) }, now))
        assertFalse(G(entry, { aura(1, "Oath of Light", now + 61) }, now))
        assertTrue(G(entry, { aura(1, "Oath of Light", now + 100) }, now, 120))
        assertFalse(G(entry, { aura(1, "Oath of Light", now + 100) }, now, 30))
    end)
    it("a different aura does not satisfy", function() assertTrue(G(entry, { aura(1, "Something Else", 0) }, now, 60)) end)
    it("single + castByMeElsewhere -> false (not needed here)", function()
        local single = { spell = "Oath of Light", roles = { TANK = true }, single = true }
        assertFalse(G(single, {}, now, 60, true))
        assertTrue(G(single, {}, now, 60, false))
        assertTrue(G(single, {}, now, 60, nil))
    end)
    it("castByMeElsewhere is ignored for non-single entries", function()
        assertTrue(G(entry, {}, now, 60, true))
    end)
    it("non-table entry / garbage auras do not raise", function()
        assertEquals(G(nil, {}, now, 60), false)
        assertTrue(pcall(G, entry, { {}, { name = 5 } }, now, 60))
    end)
end)

describe("extras: AddExtra / RemoveExtra / MigratePreset", function()
    it("AddExtra appends a copy with trimmed spell, boolean single and truthy roles only", function()
        local p = { name = "x", map = {} }
        local roles = { TANK = true, HEALER = false }
        local idx = P.AddExtra(p, "  Oath of Light  ", roles, 1)
        assertEquals(idx, 1)
        assertEquals(p.extras[1].spell, "Oath of Light")
        assertEquals(p.extras[1].single, true)
        assertEquals(p.extras[1].roles.TANK, true); assertNil(p.extras[1].roles.HEALER)
        roles.TANK = false
        assertEquals(p.extras[1].roles.TANK, true, "roles must be copied")
        assertEquals(P.AddExtra(p, "Second", nil, nil), 2)
        assertEquals(p.extras[2].single, false); assertEquals(type(p.extras[2].roles), "table")
    end)
    it("AddExtra rejects empty / non-string spells and non-table presets", function()
        local p = { name = "x", map = {} }
        assertNil(P.AddExtra(p, "", {})); assertNil(P.AddExtra(p, "   ", {})); assertNil(P.AddExtra(p, 5, {})); assertNil(P.AddExtra(nil, "X", {}))
        assertEquals(p.extras == nil or #p.extras == 0, true)
    end)
    it("AddExtra creates extras when missing or corrupted", function()
        local p = { name = "x", extras = "bad" }
        assertEquals(P.AddExtra(p, "A", {}), 1)
        assertEquals(type(p.extras), "table")
    end)
    it("RemoveExtra removes by index; invalid index returns false", function()
        local p = { extras = { { spell = "A", roles = {} }, { spell = "B", roles = {} } } }
        assertTrue(P.RemoveExtra(p, 1)); assertEquals(#p.extras, 1); assertEquals(p.extras[1].spell, "B")
        for _, i in ipairs({ 0, 2, 99, -1 }) do assertFalse(P.RemoveExtra(p, i)) end
        assertEquals(#p.extras, 1)
        assertFalse(P.RemoveExtra({}, 1)); assertFalse(P.RemoveExtra(nil, 1)); assertFalse(P.RemoveExtra({ extras = "x" }, 1))
    end)
    it("MigratePreset ensures extras exists and is idempotent", function()
        local p = { name = "x", map = {} }
        P.MigratePreset(p)
        assertEquals(type(p.extras), "table")
        local snap = ns.Util.DeepCopy(p)
        P.MigratePreset(p); assertDeepEquals(p, snap)
    end)
    it("MigratePreset keeps existing extras", function()
        local p = { name = "x", map = {}, extras = { { spell = "A", roles = { TANK = true }, single = true } } }
        P.MigratePreset(p)
        assertEquals(p.extras[1].spell, "A"); assertEquals(p.extras[1].roles.TANK, true)
    end)
    it("MigratePreset replaces a corrupted extras value with a table", function()
        local p = { name = "x", map = {}, extras = "garbage" }
        P.MigratePreset(p)
        assertEquals(type(p.extras), "table")
    end)
    it("Presets.Add copies extras deeply", function()
        local l = { { name = "A", map = {}, extras = { { spell = "S", roles = { TANK = true } } } } }
        P.Add(l, "B", 1)
        l[2].extras[1].roles.TANK = false; l[2].extras[1].spell = "T"
        assertEquals(l[1].extras[1].roles.TANK, true); assertEquals(l[1].extras[1].spell, "S")
    end)
    it("Init sanitises extras in a saved DB (bad entries dropped, valid kept)", function()
        mock.install()
        local n, _, e = L.loadContract({})
        assertEquals(next(e), nil)
        _G.HealerForeverCharDB = { version = 2, presets = { { name = "X", map = {}, extras = {
            { spell = "Oath of Light", roles = { TANK = true, BOGUS = true }, single = true }, 5, { spell = 5 }, { roles = { TANK = true } } } } } }
        mock.fire("ADDON_LOADED", "HealerForever")
        assertEquals(#mock.errors, 0, table.concat(mock.errors, "\n"))
        local ex = _G.HealerForeverCharDB.presets[1].extras
        assertEquals(type(ex), "table")
        assertEquals(ex[1].spell, "Oath of Light"); assertEquals(ex[1].roles.TANK, true)
        for _, entry in ipairs(ex) do assertEquals(type(entry.spell), "string") end
    end)
end)

describe("extras: PickNext", function()
    local N = P.PickNext
    local function pend(unit, role, kind, spell) return { unit = unit, role = role, kind = kind or "blessing", spell = spell or (unit .. "-spell") } end
    it("nil / empty / non-table -> nil", function()
        assertNil(N(nil)); assertNil(N({})); assertNil(N("x")); assertNil(N(5))
    end)
    it("a single entry is returned with its index", function()
        local e, i = N({ pend("party1", "DAMAGER") })
        assertEquals(e.unit, "party1"); assertEquals(i, 1)
    end)
    it("priority: extra > tank > healer > dps > other role > self", function()
        local order = {
            pend("player", "HEALER"), pend("party4", "NONE"), pend("party3", "DAMAGER"), pend("party2", "HEALER"),
            pend("party1", "TANK"), pend("party4", "DAMAGER", "extra", "Oath"),
        }
        local expected = { "Oath", "party1-spell", "party2-spell", "party3-spell", "party4-spell", "player-spell" }
        for step = 1, #expected do
            local e, i = N(order)
            assertEquals(e.spell, expected[step], "step " .. step)
            table.remove(order, i)
        end
        assertNil(N(order))
    end)
    it("an extra on a non-tank still outranks any blessing", function()
        local e = N({ pend("party1", "TANK"), pend("party3", "DAMAGER", "extra", "Oath") })
        assertEquals(e.kind, "extra")
    end)
    it("self (unit == player or isSelf) ranks last even when the player is the tank", function()
        local e = N({ pend("player", "TANK"), pend("party2", "DAMAGER") })
        assertEquals(e.unit, "party2")
        e = N({ { unit = "party1", role = "TANK", kind = "blessing", spell = "s", isSelf = true }, pend("party2", "DAMAGER") })
        assertEquals(e.unit, "party2")
    end)
    it("ties are ordered by unit token (stable regardless of list order)", function()
        for _, list in ipairs({
            { pend("party3", "DAMAGER"), pend("party2", "DAMAGER"), pend("party4", "DAMAGER") },
            { pend("party4", "DAMAGER"), pend("party3", "DAMAGER"), pend("party2", "DAMAGER") },
        }) do assertEquals(N(list).unit, "party2") end
    end)
    it("same unit and rank: first in list wins", function()
        local e, i = N({ pend("party2", "DAMAGER", "blessing", "first"), pend("party2", "DAMAGER", "blessing", "second") })
        assertEquals(e.spell, "first"); assertEquals(i, 1)
    end)
    it("two tanks: lower unit token first", function()
        assertEquals(N({ pend("party2", "TANK"), pend("party1", "TANK") }).unit, "party1")
    end)
    it("unknown / nil roles are 'other' (after dps, before self)", function()
        assertEquals(N({ pend("player", "HEALER"), pend("party1", nil) }).unit, "party1")
        assertEquals(N({ pend("party1", nil), pend("party2", "DAMAGER") }).unit, "party2")
    end)
    it("non-table entries are skipped without error", function()
        local e = N({ 5, "x", pend("party1", "TANK") })
        assertEquals(e.unit, "party1")
    end)
    it("does not mutate the list", function()
        local list = { pend("party2", "DAMAGER"), pend("party1", "TANK") }
        local snap = ns.Util.DeepCopy(list)
        N(list); assertDeepEquals(list, snap)
    end)
    it("exhaustive: every kind/role/unit permutation is stable under reordering", function()
        local roles = { "TANK", "HEALER", "DAMAGER", "NONE" }
        local units = { "player", "party1", "party2", "party3", "party4" }
        local entries = {}
        for _, u in ipairs(units) do for _, r in ipairs(roles) do entries[#entries + 1] = pend(u, r) end end
        local ref = N(entries)
        for s = 1, 20 do
            local copy = {}
            for _, e in ipairs(entries) do copy[#copy + 1] = e end
            for i = #copy, 2, -1 do local j = (i * s) % i + 1; copy[i], copy[j] = copy[j], copy[i] end
            local e = N(copy)
            assertEquals(e.unit, ref.unit); assertEquals(e.role, ref.role)
        end
        assertEquals(ref.unit, "party1"); assertEquals(ref.role, "TANK")
    end)
end)
