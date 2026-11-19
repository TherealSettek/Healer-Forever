-- Role rows FOLLOW the class row: an empty or missing role set (TANK / HEALER / DAMAGER) resolves to the class row (DEFAULT), while an
-- empty class row or Self set still means "no buff". Covers CellBuffs/ResolveBuff, RoleInherits, ResetRole, the editors never storing an
-- empty role set, MigratePreset, the examples (unchanged effective buffs), the owner's real scenario end to end (None on every Paladin row
-- under the old code, then Might on the class row only), and the pane ("Use class row", "= default", header, sparse save, combat, secrets).
local L = require("loader")
local mock = require("wow_mock")
local BU = require("buff_ui")
local geo = require("aura_geo")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

mock.install()
local cns = {}
local _, _, cerrs = L.loadContract(cns)
if next(cerrs) then it("contract loads", function() error(tostring(select(2, next(cerrs)))) end) return end
local P, C = cns.Presets, cns.Classes
local F = require("framework")

local ALL = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local ROLE_NAMES = { "TANK", "HEALER", "DAMAGER" }
local function dc(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = dc(v) end return o end
local function mk() local p = { name = "x", map = {} }; P.MigratePreset(p); return p end

-- ======================================================================== CellBuffs / ResolveBuff
describe("role inherit: CellBuffs and ResolveBuff", function()
    it("a role set that is {}, nil, 'none' or '' follows the class row (DEFAULT), for every class and valid role", function()
        for _, class in ipairs(ALL) do
            for _, role in ipairs(C.ROLES[class]) do
                for _, v in ipairs({ "nil", {}, "none", "", { "none", "" } }) do
                    local entry = { DEFAULT = { "kings", "fortitude" } }
                    if v ~= "nil" then entry[role] = dc(v) end
                    local p = { name = "x", map = { [class] = entry } }
                    assertDeepEquals(P.CellBuffs(p, class, role, false), { "kings", "fortitude" }, class .. " " .. role .. " " .. F.repr(v))
                    assertEquals(P.ResolveBuff(p, class, role, false), "kings", class .. " " .. role)
                end
            end
        end
    end)
    it("a non-empty role set is an override and wins over the class row", function()
        local p = { map = { PALADIN = { DEFAULT = { "wisdom" }, TANK = { "might" }, HEALER = "kings" } } }
        assertDeepEquals(P.CellBuffs(p, "PALADIN", "TANK"), { "might" }); assertEquals(P.ResolveBuff(p, "PALADIN", "HEALER"), "kings")
        assertEquals(P.ResolveBuff(p, "PALADIN", "DAMAGER"), "wisdom")
    end)
    it("an empty class row (DEFAULT {} / 'none') means no buff, and a following role row then also gets nothing", function()
        for _, d in ipairs({ {}, "none", "" }) do
            local p = { map = { PALADIN = { DEFAULT = dc(d), TANK = {} } } }
            assertDeepEquals(P.CellBuffs(p, "PALADIN", "DEFAULT"), {}); assertNil(P.ResolveBuff(p, "PALADIN", "DEFAULT"))
            assertNil(P.ResolveBuff(p, "PALADIN", "TANK")); assertNil(P.ResolveBuff(p, "PALADIN", "HEALER"))
        end
    end)
    it("an empty Self set means no buff for the player even when the class and role rows have buffs; self nil uses the rules", function()
        local p = { self = {}, map = { PALADIN = { DEFAULT = { "might" }, TANK = { "kings" } } } }
        for _, role in ipairs({ "DEFAULT", "TANK", "HEALER", "DAMAGER" }) do
            assertDeepEquals(P.CellBuffs(p, "PALADIN", role, true), {}, role); assertNil(P.ResolveBuff(p, "PALADIN", role, true))
        end
        p.self = nil
        assertEquals(P.ResolveBuff(p, "PALADIN", "TANK", true), "kings"); assertEquals(P.ResolveBuff(p, "PALADIN", "HEALER", true), "might")
    end)
    it("a role entry on a role the class cannot have is ignored even when non-empty (DEFAULT used)", function()
        local p = { map = { MAGE = { DEFAULT = { "arcaneint" }, TANK = { "dampen" } } } }
        assertDeepEquals(P.CellBuffs(p, "MAGE", "TANK"), { "arcaneint" })
    end)
    it("a legacy string class entry gives every role the same buff", function()
        local p = { map = { PALADIN = "kings" } }
        for _, role in ipairs({ "DEFAULT", "TANK", "HEALER", "DAMAGER" }) do assertEquals(P.ResolveBuff(p, "PALADIN", role), "kings") end
    end)
    it("the result is a fresh array: changing it never writes into the preset", function()
        local p = { map = { PALADIN = { DEFAULT = { "might" } } } }
        local got = P.CellBuffs(p, "PALADIN", "TANK"); got[1] = "kings"; got[2] = "wisdom"
        assertDeepEquals(p.map.PALADIN.DEFAULT, { "might" }); assertNil(p.map.PALADIN.TANK)
    end)
end)

-- ======================================================================== RoleInherits / ResetRole
describe("role inherit: RoleInherits", function()
    local function ri(entry, role, class) return P.RoleInherits({ map = { [class or "PALADIN"] = entry } }, class or "PALADIN", role) end
    it("matrix: nil / {} / 'none' / '' -> true, a set -> false, DEFAULT always false, nil role false", function()
        assertTrue(ri({ DEFAULT = { "might" } }, "TANK"), "nil")
        assertTrue(ri({ DEFAULT = { "might" }, TANK = {} }, "TANK"), "{}")
        assertTrue(ri({ DEFAULT = { "might" }, TANK = "none" }, "TANK"), "'none'")
        assertTrue(ri({ DEFAULT = { "might" }, TANK = "" }, "TANK"), "''")
        assertTrue(ri({ DEFAULT = { "might" }, TANK = { "none", "" } }, "TANK"), "only junk keys")
        assertFalse(ri({ DEFAULT = { "might" }, TANK = { "kings" } }, "TANK"), "a set")
        assertFalse(ri({ DEFAULT = { "might" }, TANK = "kings" }, "TANK"), "legacy string key")
        assertFalse(ri({ DEFAULT = { "might" }, TANK = { "might" } }, "TANK"), "an override equal to DEFAULT is still an override")
        for _, d in ipairs({ { "might" }, {}, "none" }) do
            assertFalse(ri({ DEFAULT = d }, "DEFAULT"), "DEFAULT never inherits: " .. F.repr(d))
        end
        assertFalse(ri({ DEFAULT = {} }, nil), "nil role")
    end)
    it("a missing class entry, a legacy string class entry, a nil map and a nil preset all inherit", function()
        assertTrue(P.RoleInherits({ map = {} }, "PALADIN", "TANK"))
        assertTrue(P.RoleInherits({ map = { PALADIN = "kings" } }, "PALADIN", "TANK"))
        assertTrue(P.RoleInherits({}, "PALADIN", "HEALER"))
        assertTrue(P.RoleInherits(nil, "PALADIN", "HEALER"))
        assertFalse(P.RoleInherits(nil, "PALADIN", "DEFAULT"))
    end)
    it("RoleInherits agrees with CellBuffs for every class and valid role (inherits <=> resolves exactly to DEFAULT's set)", function()
        for _, class in ipairs(ALL) do
            for _, role in ipairs(C.ROLES[class]) do
                for _, v in ipairs({ "nil", {}, "none", { "kings" }, { "might", "fortitude" } }) do
                    local entry = { DEFAULT = { "might" } }
                    if v ~= "nil" then entry[role] = dc(v) end
                    local p = { map = { [class] = entry } }
                    local inherits = P.RoleInherits(p, class, role)
                    if inherits then assertDeepEquals(P.CellBuffs(p, class, role), { "might" }, class .. role)
                    else assertDeepEquals(P.CellBuffs(p, class, role), P.CellBuffs({ map = { X = { DEFAULT = dc(v) } } }, "X", "DEFAULT")) end
                end
            end
        end
    end)
end)

describe("role inherit: ResetRole", function()
    it("drops the role's own set (the WHOLE cell) so it follows the class row again; DEFAULT and other roles untouched", function()
        local p = mk()
        P.SetCellBuff(p, "MAGE", "DEFAULT", "arcaneint", true)
        P.SetCellBuff(p, "PALADIN", "DEFAULT", "wisdom", true)
        P.SetCellBuff(p, "PALADIN", "TANK", "might", true); P.SetCellBuff(p, "PALADIN", "HEALER", "kings", true)
        assertTrue(P.ResetRole(p, "PALADIN", "TANK"))
        assertNil(p.map.PALADIN.TANK); assertTrue(P.RoleInherits(p, "PALADIN", "TANK"))
        assertEquals(P.ResolveBuff(p, "PALADIN", "TANK"), "wisdom")
        assertDeepEquals(p.map.PALADIN.HEALER, { "kings" }); assertDeepEquals(p.map.PALADIN.DEFAULT, { "wisdom" })
        assertTrue(P.ResetRole(p, "PALADIN", "TANK"), "resetting an inheriting role is a harmless no-op")
        assertNil(p.map.PALADIN.TANK)
    end)
    it("a multi-buff override (Priest) is reset as a whole", function()
        local p = mk()
        P.SetCellBuff(p, "WARRIOR", "DEFAULT", "fortitude", true)
        P.SetCellBuff(p, "WARRIOR", "TANK", "shadowprot", true); P.SetCellBuff(p, "WARRIOR", "TANK", "spirit", true)
        assertDeepEquals(p.map.WARRIOR.TANK, { "fortitude", "spirit", "shadowprot" })
        P.ResetRole(p, "WARRIOR", "TANK")
        assertNil(p.map.WARRIOR.TANK); assertDeepEquals(P.CellBuffs(p, "WARRIOR", "TANK"), { "fortitude" })
    end)
    it("works on a class without an entry yet and on a legacy string class entry", function()
        local p = { name = "x", map = { PALADIN = "kings" } }
        assertTrue(P.ResetRole(p, "PALADIN", "TANK"))
        assertEquals(type(p.map.PALADIN), "table"); assertDeepEquals(p.map.PALADIN.DEFAULT, { "kings" }); assertNil(p.map.PALADIN.TANK)
        local q = { name = "y", map = {} }
        assertTrue(P.ResetRole(q, "DRUID", "HEALER")); assertDeepEquals(q.map.DRUID.DEFAULT, {}); assertNil(q.map.DRUID.HEALER)
    end)
    it("refuses DEFAULT, roles the class cannot have, unknown classes, nil role and a nil / non-table preset, changing nothing", function()
        local p = mk()
        P.SetCellBuff(p, "PALADIN", "DEFAULT", "might", true)
        local snap = dc(p)
        assertFalse(P.ResetRole(p, "PALADIN", "DEFAULT"))
        assertFalse(P.ResetRole(p, "MAGE", "TANK")); assertFalse(P.ResetRole(p, "WARRIOR", "HEALER"))
        assertFalse(P.ResetRole(p, "BOGUS", "TANK")); assertFalse(P.ResetRole(p, nil, "TANK"))
        assertFalse(P.ResetRole(p, "PALADIN", nil)); assertFalse(P.ResetRole(p, "PALADIN", "NONE"))
        assertFalse(P.ResetRole(nil, "PALADIN", "TANK")); assertFalse(P.ResetRole("x", "PALADIN", "TANK"))
        assertTrue(F.deepEq(snap, p), "nothing changed: " .. F.repr(p.map.PALADIN))
    end)
end)

-- ======================================================================== the editors never store an empty role set
describe("role inherit: editors store nil for an empty role set", function()
    it("ClearGroup on an INHERITING role stores nothing, even when the class row has other groups (Mage {arcaneint, dampen})", function()
        local p = mk()
        P.SetCellBuff(p, "PALADIN", "DEFAULT", "arcaneint", true); P.SetCellBuff(p, "PALADIN", "DEFAULT", "dampen", true)
        assertDeepEquals(p.map.PALADIN.DEFAULT, { "arcaneint", "dampen" })
        assertTrue(P.ClearGroup(p, "PALADIN", "HEALER", "magic"))
        assertNil(p.map.PALADIN.HEALER, "nothing stored on an inheriting role")
        assertDeepEquals(P.CellBuffs(p, "PALADIN", "HEALER"), { "arcaneint", "dampen" })
        P.ClearGroup(p, "PALADIN", "HEALER", "intellect"); assertNil(p.map.PALADIN.HEALER)
        assertDeepEquals(p.map.PALADIN.DEFAULT, { "arcaneint", "dampen" }, "DEFAULT untouched")
    end)
    it("ClearGroup on a role stored as {} or 'none' (old saves) normalises it to nil", function()
        for _, v in ipairs({ {}, "none" }) do
            local p = { name = "x", map = { MAGE = { DEFAULT = { "arcaneint" }, DAMAGER = dc(v) } } }
            P.ClearGroup(p, "MAGE", "DAMAGER", "magic")
            assertNil(p.map.MAGE.DAMAGER, F.repr(v))
        end
    end)
    it("ClearGroup on an override removes only that group; emptying the override stores nil (follows the class row)", function()
        local p = mk()
        P.SetCellBuff(p, "PRIEST", "DEFAULT", "arcaneint", true)
        P.SetCellBuff(p, "PRIEST", "HEALER", "amplify", true)
        assertDeepEquals(p.map.PRIEST.HEALER, { "arcaneint", "amplify" })
        P.ClearGroup(p, "PRIEST", "HEALER", "magic"); assertDeepEquals(p.map.PRIEST.HEALER, { "arcaneint" }, "still an override (equal to DEFAULT)")
        P.ClearGroup(p, "PRIEST", "HEALER", "intellect"); assertNil(p.map.PRIEST.HEALER)
        assertEquals(P.ResolveBuff(p, "PRIEST", "HEALER"), "arcaneint")
    end)
    it("ClearGroup on the class row still stores an empty set (no buff)", function()
        local p = mk()
        P.SetCellBuff(p, "PALADIN", "DEFAULT", "might", true); P.ClearGroup(p, "PALADIN", "DEFAULT", "blessing")
        assertDeepEquals(p.map.PALADIN.DEFAULT, {}); assertNil(P.ResolveBuff(p, "PALADIN", "TANK"))
    end)
    it("SetCellBuff: toggling the last checkbox of a Priest role override off stores nil", function()
        local p = mk()
        P.SetCellBuff(p, "MAGE", "DEFAULT", "fortitude", true)
        P.SetCellBuff(p, "MAGE", "DAMAGER", "fortitude", false)
        assertNil(p.map.MAGE.DAMAGER, "toggling an inherited buff off empties the copy -> nil")
        local q = mk()
        P.SetCellBuff(q, "WARRIOR", "TANK", "shadowprot", true); P.SetCellBuff(q, "WARRIOR", "TANK", "spirit", true)
        assertDeepEquals(q.map.WARRIOR.TANK, { "spirit", "shadowprot" })
        P.SetCellBuff(q, "WARRIOR", "TANK", "spirit", false); assertDeepEquals(q.map.WARRIOR.TANK, { "shadowprot" })
        P.SetCellBuff(q, "WARRIOR", "TANK", "shadowprot", false); assertNil(q.map.WARRIOR.TANK)
        assertDeepEquals(q.map.WARRIOR.DEFAULT, {})
    end)
    it("SetCellBuff: toggling the last checkbox of the class row off keeps an empty set", function()
        local p = mk()
        P.SetCellBuff(p, "MAGE", "DEFAULT", "fortitude", true); P.SetCellBuff(p, "MAGE", "DEFAULT", "fortitude", false)
        assertDeepEquals(p.map.MAGE.DEFAULT, {})
    end)
    it("SetRule(role, nil / 'none' / '' / {}) stores nil; SetRule(DEFAULT, nil / 'none') stores {}", function()
        for _, v in ipairs({ "nil", "none", "", {} }) do
            local p = mk()
            P.SetRule(p, "PALADIN", "TANK", "kings")
            assertDeepEquals(p.map.PALADIN.TANK, { "kings" })
            P.SetRule(p, "PALADIN", "TANK", v ~= "nil" and dc(v) or nil)
            assertNil(p.map.PALADIN.TANK, "SetRule(TANK, " .. F.repr(v) .. ")")
        end
        local p = mk()
        P.SetRule(p, "PALADIN", "DEFAULT", "kings"); P.SetRule(p, "PALADIN", "DEFAULT", nil); assertDeepEquals(p.map.PALADIN.DEFAULT, {})
        P.SetRule(p, "PALADIN", "DEFAULT", "kings"); P.SetRule(p, "PALADIN", "DEFAULT", "none"); assertDeepEquals(p.map.PALADIN.DEFAULT, {})
    end)
    it("fuzz: no editor sequence ever leaves an empty role set stored, and the class row is always a table", function()
        local keys = { "might", "wisdom", "kings", "fortitude", "spirit", "shadowprot", "arcaneint", "dampen", "amplify", "motw", "thorns" }
        local groups = { "blessing", "fortitude", "spirit", "shadowprot", "intellect", "magic", "motw", "thorns" }
        local seed = 12345
        local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n + 1 end
        local p = mk()
        for step = 1, 3000 do
            local class = ALL[rnd(#ALL)]
            local roles = { "DEFAULT" }
            for _, r in ipairs(C.ROLES[class]) do roles[#roles + 1] = r end
            local role = roles[rnd(#roles)]
            local op = rnd(5)
            if op == 1 or op == 2 then P.SetCellBuff(p, class, role, keys[rnd(#keys)], op == 1)
            elseif op == 3 then P.ClearGroup(p, class, role, groups[rnd(#groups)])
            elseif op == 4 then P.ResetRole(p, class, role)
            else P.SetRule(p, class, role, rnd(3) == 1 and "none" or keys[rnd(#keys)]) end
            for c, entry in pairs(p.map) do
                assertEquals(type(entry.DEFAULT), "table", "step " .. step .. " " .. c)
                for _, r in ipairs(ROLE_NAMES) do
                    if entry[r] ~= nil then assertTrue(#entry[r] > 0, "step " .. step .. ": empty " .. c .. "." .. r .. " stored") end
                end
            end
        end
    end)
end)

-- ======================================================================== MigratePreset
describe("role inherit: MigratePreset", function()
    it("{} / 'none' / '' / junk-only role sets become nil; DEFAULT {} stays {}; overrides stay", function()
        local p = { name = "x", map = {
            PALADIN = { DEFAULT = {}, TANK = {}, HEALER = "none", DAMAGER = { "none", "" } },
            DRUID = { DEFAULT = { "motw" }, TANK = { "thorns" }, HEALER = "", DAMAGER = {} },
        } }
        P.MigratePreset(p)
        assertDeepEquals(p.map.PALADIN, { DEFAULT = {} })
        assertDeepEquals(p.map.DRUID, { DEFAULT = { "motw" }, TANK = { "thorns" } })
    end)
    it("is idempotent (twice == once) on a mix of every role shape", function()
        local p = { name = "x", self = {}, map = {
            PALADIN = { DEFAULT = "kings", TANK = {}, HEALER = { "wisdom" }, DAMAGER = "none" },
            MAGE = "none", PRIEST = { HEALER = {} },
        } }
        P.MigratePreset(p)
        local once = dc(p)
        P.MigratePreset(p)
        assertTrue(F.deepEq(once, p), F.repr(p.map))
        assertNil(p.map.PALADIN.TANK); assertNil(p.map.PALADIN.DAMAGER); assertNil(p.map.PRIEST.HEALER)
        assertDeepEquals(p.self, {}, "an empty Self set is kept (no buff for me)")
        assertDeepEquals(p.map.MAGE.DEFAULT, {})
    end)
    it("the owner's real presets (fixtures) resolve exactly per the reference rule after migration", function()
        local Fx = require("fixtures")
        local sources = { Fx.userChar(), Fx.loadSaved(HF_TESTS .. "/fixtures/owner-char-pre-buffgroups.lua", "HealerForeverCharDB"), Fx.userAccount() }
        local n = 0
        for _, db in ipairs(sources) do
            for _, raw in ipairs(db and db.presets or {}) do
                local p = P.MigratePreset(dc(raw))
                for class, entry in pairs(type(raw.map) == "table" and raw.map or {}) do
                    if type(entry) == "table" and C.ROLES[class] then
                        for _, role in ipairs(C.ROLES[class]) do
                            local own = entry[role]
                            local expectKey = (own ~= nil and own ~= "none" and own ~= "" and not (type(own) == "table" and own[1] == nil)) and own or entry.DEFAULT
                            if type(expectKey) == "table" then expectKey = expectKey[1] end
                            if expectKey == "none" then expectKey = nil end
                            assertEquals(P.ResolveBuff(p, class, role), expectKey, class .. " " .. role)
                            n = n + 1
                        end
                    end
                end
            end
        end
        assertTrue(n > 10, "fixtures had role cells: " .. n)
    end)
end)

-- ======================================================================== examples resolve exactly as before
describe("role inherit: every example resolves exactly as before the change", function()
    -- Captured from the code BEFORE the role-inherit change (0.10.1), for every class x row. "" = no buff.
    local EXPECTED = {
        PALADIN = {
            WARRIOR = { DEFAULT = "might", TANK = "kings", DAMAGER = "might" },
            PALADIN = { DEFAULT = "wisdom", TANK = "might", HEALER = "wisdom", DAMAGER = "might" },
            HUNTER = { DEFAULT = "might", DAMAGER = "might" }, ROGUE = { DEFAULT = "might", DAMAGER = "might" },
            PRIEST = { DEFAULT = "wisdom", HEALER = "wisdom", DAMAGER = "wisdom" }, SHAMAN = { DEFAULT = "wisdom", HEALER = "wisdom", DAMAGER = "wisdom" },
            MAGE = { DEFAULT = "wisdom", DAMAGER = "wisdom" }, WARLOCK = { DEFAULT = "wisdom", DAMAGER = "wisdom" },
            DRUID = { DEFAULT = "wisdom", TANK = "kings", HEALER = "wisdom", DAMAGER = "wisdom" },
        },
        PRIEST = {
            WARRIOR = { DEFAULT = "fortitude", TANK = "fortitude shadowprot", DAMAGER = "fortitude" },
            PALADIN = { DEFAULT = "fortitude spirit", TANK = "fortitude shadowprot", HEALER = "fortitude spirit", DAMAGER = "fortitude spirit" },
            HUNTER = { DEFAULT = "fortitude", DAMAGER = "fortitude" }, ROGUE = { DEFAULT = "fortitude", DAMAGER = "fortitude" },
            PRIEST = { DEFAULT = "fortitude spirit", HEALER = "fortitude spirit", DAMAGER = "fortitude spirit" },
            SHAMAN = { DEFAULT = "fortitude spirit", HEALER = "fortitude spirit", DAMAGER = "fortitude spirit" },
            MAGE = { DEFAULT = "fortitude spirit", DAMAGER = "fortitude spirit" }, WARLOCK = { DEFAULT = "fortitude spirit", DAMAGER = "fortitude spirit" },
            DRUID = { DEFAULT = "fortitude spirit", TANK = "fortitude shadowprot", HEALER = "fortitude spirit", DAMAGER = "fortitude spirit" },
        },
        MAGE = {
            WARRIOR = { DEFAULT = "arcaneint", TANK = "arcaneint dampen", DAMAGER = "arcaneint" },
            PALADIN = { DEFAULT = "arcaneint", TANK = "arcaneint dampen", HEALER = "arcaneint amplify", DAMAGER = "arcaneint" },
            HUNTER = { DEFAULT = "arcaneint", DAMAGER = "arcaneint" }, ROGUE = { DEFAULT = "arcaneint", DAMAGER = "arcaneint" },
            PRIEST = { DEFAULT = "arcaneint", HEALER = "arcaneint amplify", DAMAGER = "arcaneint" },
            SHAMAN = { DEFAULT = "arcaneint", HEALER = "arcaneint amplify", DAMAGER = "arcaneint" },
            MAGE = { DEFAULT = "arcaneint", DAMAGER = "arcaneint" }, WARLOCK = { DEFAULT = "arcaneint", DAMAGER = "arcaneint" },
            DRUID = { DEFAULT = "arcaneint", TANK = "arcaneint dampen", HEALER = "arcaneint amplify", DAMAGER = "arcaneint" },
        },
        DRUID = {
            WARRIOR = { DEFAULT = "motw", TANK = "motw thorns", DAMAGER = "motw" },
            PALADIN = { DEFAULT = "motw", TANK = "motw thorns", HEALER = "motw", DAMAGER = "motw" },
            HUNTER = { DEFAULT = "motw", DAMAGER = "motw" }, ROGUE = { DEFAULT = "motw", DAMAGER = "motw" },
            PRIEST = { DEFAULT = "motw", HEALER = "motw", DAMAGER = "motw" }, SHAMAN = { DEFAULT = "motw", HEALER = "motw", DAMAGER = "motw" },
            MAGE = { DEFAULT = "motw", DAMAGER = "motw" }, WARLOCK = { DEFAULT = "motw", DAMAGER = "motw" },
            DRUID = { DEFAULT = "motw", TANK = "motw thorns", HEALER = "motw", DAMAGER = "motw" },
        },
    }
    for _, caster in ipairs({ "PALADIN", "PRIEST", "MAGE", "DRUID" }) do
        it(caster .. " example: every class x row resolves to the pre-change buffs, before and after MigratePreset", function()
            local e = P.ExampleFor(caster)
            for _, pass in ipairs({ "raw", "migrated" }) do
                if pass == "migrated" then e = P.MigratePreset(e) end
                for _, target in ipairs(ALL) do
                    local rows = { "DEFAULT" }
                    for _, r in ipairs(C.ROLES[target]) do rows[#rows + 1] = r end
                    assertEquals(#rows, (function() local n = 0 for _ in pairs(EXPECTED[caster][target]) do n = n + 1 end return n end)(), target)
                    for _, r in ipairs(rows) do
                        assertEquals(table.concat(P.CellBuffs(e, target, r, false), " "), EXPECTED[caster][target][r], pass .. " " .. caster .. " -> " .. target .. " " .. r)
                    end
                end
            end
        end)
        it(caster .. " example: a role is stored only when it differs from the class row (no redundant overrides)", function()
            local e = P.ExampleFor(caster)
            for _, target in ipairs(ALL) do
                for _, r in ipairs(C.ROLES[target]) do
                    local exp = EXPECTED[caster][target]
                    if exp[r] == exp.DEFAULT then assertNil(e.map[target][r], target .. " " .. r .. " should follow the class row")
                    else assertNotNil(e.map[target][r], target .. " " .. r .. " is a real override") end
                end
            end
        end)
    end
end)

-- ======================================================================== full addon: the owner's scenario + pane
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

local function boot(class, opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.player.class = class
    S.units.party1 = unit("Tanky", "PALADIN", "TANK"); S.units.party2 = unit("Holy", "PALADIN", "HEALER")
    S.units.party3 = unit("Ret", "PALADIN", "DAMAGER"); S.units.party4 = unit("Mage", "MAGE", "DAMAGER")
    if opts.setup then opts.setup() end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.char ~= nil then _G.HealerForeverCharDB = dc(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 5)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    if not opts.noPane then ns.Options:Show("buffs"); mock.flushTimers() end
    return ns
end
local function refresh() mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers() end
local function buffBtn(u) for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverBuff%d$") and f.unit == u then return f end end end
local function active(b) return b ~= nil and b:GetAlpha() > 0 and st(b).mouse == true end
local function button(text) for _, f in ipairs(mock.frames) do if st(f).kind == "Button" and st(f).text == text and st(f).shown then return f end end end
local function click(f) st(f).scripts.OnClick(f, "LeftButton"); mock.flushTimers() end
-- the "= default" note of a role row: anchored 4px below the top of that row's cell, in the same scroll child
local function noteFor(cell)
    local cp = st(cell).points[1]
    for _, f in ipairs(mock.frames) do
        local s = st(f)
        if s.kind == "FontString" and s.text == "= default" and s.parent == st(cell).parent then
            local p = s.points[1]
            if p and math.abs((p[3] or 0) - (cp[3] - 4)) < 1e-6 then return f end
        end
    end
end
local function noteShown(cells, key) local n = noteFor(cells.byKey[key]); assertNotNil(n, "no note for " .. key); return st(n).shown and true or false end

-- the char DB the OLD code wrote when the owner chose None on the Paladin class row and all three Paladin role rows
local function oldNoneEverywhere()
    return { version = 4, activePreset = 1, presets = { { name = "Default", extras = {}, map = {
        PALADIN = { DEFAULT = {}, TANK = {}, HEALER = {}, DAMAGER = {} },
    } } } }
end

describe("role inherit: the owner's scenario (None on every Paladin row under the old code, then Might on the class row only)", function()
    it("pure: on the raw old data (no migration), Might on the class row reaches TANK, HEALER and DAMAGER", function()
        local p = oldNoneEverywhere().presets[1]
        for _, r in ipairs(ROLE_NAMES) do assertNil(P.ResolveBuff(p, "PALADIN", r), "None everywhere = no buff (" .. r .. ")") end
        p.map.PALADIN.DEFAULT = { "might" }
        for _, r in ipairs(ROLE_NAMES) do assertEquals(P.ResolveBuff(p, "PALADIN", r), "might", r) end
        assertEquals(P.ResolveBuff(p, "PALADIN", "DEFAULT"), "might")
    end)
    it("end to end: load the old save, pick Might on the Paladin CLASS row in the pane -> the Paladin tank, healer and DPS all get a Might button", function()
        local ns = boot("PALADIN", { char = oldNoneEverywhere() })
        assertEquals(#mock.errors, 0, errstr())
        local preset = ns.db.presets[ns.db.activePreset]
        for _, r in ipairs(ROLE_NAMES) do assertNil(preset.map.PALADIN[r], "the loaded empty " .. r .. " row now follows the class row") end
        assertDeepEquals(preset.map.PALADIN.DEFAULT, {})
        refresh()
        assertFalse(active(buffBtn("party1")), "no rule yet: no buff button for the tank")
        local cells = BU.cells(ns)
        BU.openCell(cells.byKey["PALADIN:DEFAULT"]); assertDeepEquals(BU.checked(), { "None" })
        assertTrue(BU.pick("Blessing of Might")); BU.close()
        assertDeepEquals(preset.map.PALADIN.DEFAULT, { "might" })
        for _, r in ipairs(ROLE_NAMES) do
            assertEquals(P.ResolveBuff(preset, "PALADIN", r), "might", r)
            assertNil(preset.map.PALADIN[r], r .. " still follows the class row")
        end
        refresh()
        for _, u in ipairs({ "party1", "party2", "party3" }) do
            local b = buffBtn(u)
            assertNotNil(b, u .. " has no buff button")
            assertEquals(b.buffKey, "might", u); assertTrue(active(b), u .. " button is clickable")
        end
        assertFalse(active(buffBtn("party4")) and buffBtn("party4").buffKey == "might", "the Mage is not a Paladin")
        -- the cells now show the Might icon on the class row AND the three role rows, with "= default" on each role
        cells = BU.cells(ns)
        for _, r in ipairs({ "DEFAULT", "TANK", "HEALER", "DAMAGER" }) do assertEquals(#BU.cellIcons(cells.byKey["PALADIN:" .. r]), 1, r) end
        for _, r in ipairs(ROLE_NAMES) do assertTrue(noteShown(cells, "PALADIN:" .. r), r .. " '= default'") end
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
    end)
    it("end to end: once the tank has Might, the button clears; a Kings override on TANK still wins over the class row", function()
        local ns = boot("PALADIN", { char = oldNoneEverywhere() })
        local preset = ns.db.presets[ns.db.activePreset]
        local cells = BU.cells(ns)
        BU.openCell(cells.byKey["PALADIN:DEFAULT"]); BU.pick("Blessing of Might"); BU.close(); refresh()
        local d = ns.Classes.BUFFS.might
        S.auras.party1 = { { spellId = d.spellIds[1] or 0, name = d.name, icon = 1, duration = 600, expirationTime = S.now + 500, applications = 0,
            isHelpful = true, sourceUnit = "player", auraInstanceID = 7001 } }
        mock.fire("UNIT_AURA", "party1"); refresh()
        local b = buffBtn("party1")
        assertFalse(active(b) and b.buffKey == "might", "Might is up on the tank: no Might button")
        BU.openCell(cells.byKey["PALADIN:TANK"]); assertDeepEquals(BU.checked(), { "Use class row" })
        BU.pick("Blessing of Kings"); BU.close(); refresh()
        assertDeepEquals(preset.map.PALADIN.TANK, { "kings" })
        assertEquals(buffBtn("party1").buffKey, "kings"); assertTrue(active(buffBtn("party1")))
        assertEquals(buffBtn("party2").buffKey, "might", "the healer still follows the class row")
    end)
    it("the same scenario with every value secret and in combat never raises or makes protected calls", function()
        local ns = boot("PALADIN", { char = oldNoneEverywhere() })
        S.secretAll = true
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local cells = BU.cells(ns)
        BU.openCell(cells.byKey["PALADIN:DEFAULT"]); BU.pick("Blessing of Might")
        BU.openCell(cells.byKey["PALADIN:TANK"]); BU.pick("Blessing of Kings"); BU.pick("Use class row"); BU.close()
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        S.secretAll = false; refresh()
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
        assertNil(ns.db.presets[1].map.PALADIN.TANK)
        assertEquals(buffBtn("party1").buffKey, "might")
    end)
end)

-- ======================================================================== the pane
describe("role inherit: the Buff Presets pane", function()
    it("a fresh preset: every role row ticks 'Use class row' and shows '= default'; the class row ticks 'None' and has no note", function()
        local ns = boot("PALADIN")
        local cells = BU.cells(ns)
        for _, row in ipairs(cells.rows) do
            BU.openCell(row.cell)
            if row.role == "DEFAULT" then
                assertDeepEquals(BU.checked(), { "None" }, row.class)
                assertNil(noteFor(row.cell), row.class .. " class row has no note")
            else
                assertDeepEquals(BU.checked(), { "Use class row" }, row.class .. " " .. row.role)
                assertTrue(noteShown(cells, row.class .. ":" .. row.role), row.class .. " " .. row.role)
            end
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Priest (no radio group): the standalone 'Use class row' row is ticked on a fresh role row and checkbox ticks show the inherited buffs", function()
        local ns = boot("PRIEST")
        local preset = ns.db.presets[1]
        P.SetCellBuff(preset, "WARRIOR", "DEFAULT", "fortitude", true); ns:Changed("presets"); mock.flushTimers()
        local cells = BU.cells(ns)
        BU.openCell(cells.byKey["WARRIOR:TANK"])
        assertDeepEquals(BU.checked(), { "Use class row", "Power Word: Fortitude" })
        BU.pick("Shadow Protection")
        assertDeepEquals(preset.map.WARRIOR.TANK, { "fortitude", "shadowprot" }, "the first edit starts from a copy of the class row")
        assertDeepEquals(BU.checked(), { "Power Word: Fortitude", "Shadow Protection" })
        BU.pick("Use class row")
        assertNil(preset.map.WARRIOR.TANK); assertDeepEquals(BU.checked(), { "Use class row", "Power Word: Fortitude" })
    end)
    it("'= default' is shown for nil and {} roles and hidden for an override; it follows edits live", function()
        local ns = boot("PALADIN")
        local preset = ns.db.presets[1]
        preset.map.PALADIN = { DEFAULT = { "wisdom" }, TANK = {}, HEALER = { "kings" } }
        ns:Changed("presets"); mock.flushTimers()
        local cells = BU.cells(ns)
        assertTrue(noteShown(cells, "PALADIN:TANK"), "{} role")
        assertFalse(noteShown(cells, "PALADIN:HEALER"), "override")
        assertTrue(noteShown(cells, "PALADIN:DAMAGER"), "nil role")
        assertEquals(#BU.cellIcons(cells.byKey["PALADIN:TANK"]), 1, "the {} role shows the class row's icon")
        BU.openCell(cells.byKey["PALADIN:DAMAGER"]); BU.pick("Blessing of Might"); BU.close()
        assertFalse(noteShown(cells, "PALADIN:DAMAGER"), "override now")
        BU.openCell(cells.byKey["PALADIN:HEALER"]); BU.pick("Use class row"); BU.close()
        assertTrue(noteShown(cells, "PALADIN:HEALER"), "reset -> follows again")
        assertNil(preset.map.PALADIN.HEALER)
    end)
    it("New and Duplicate keep role rows inheriting (no empty role sets are created)", function()
        local ns = boot("PALADIN")
        local base = ns.db.presets[1]
        base.map.PALADIN = { DEFAULT = { "might" }, TANK = {}, HEALER = { "wisdom" } }
        ns:Changed("presets"); mock.flushTimers()
        local n = #ns.db.presets
        click(button("New")); click(button("OK"))
        assertEquals(#ns.db.presets, n + 1)
        local fresh = ns.db.presets[n + 1]
        for _, class in ipairs(ALL) do
            assertDeepEquals(fresh.map[class], { DEFAULT = {} }, class .. " in a New preset")
            for _, r in ipairs(C.ROLES[class]) do assertTrue(P.RoleInherits(fresh, class, r)) end
        end
        -- duplicate preset 1 (edit the first preset first)
        ns:Changed("presets"); mock.flushTimers()
        local dd
        for _, f in ipairs(mock.frames) do local p = st(f).points[1]; if rawget(f, "Refresh") and p and p[2] == 60 and p[3] == -52 then dd = f end end
        st(dd).scripts.OnClick(dd, "LeftButton")
        if not mock.pickMenu("1. Default |cff33ff33(active)|r") then
            for _, f in ipairs(mock.frames) do local s = st(f); if s.shown and f.item and type(f.item.text) == "string" and f.item.text:find("1. Default", 1, true) then s.scripts.OnClick(f, "LeftButton") end end
        end
        mock.flushTimers()
        click(button("Duplicate")); click(button("OK"))
        local copy = ns.db.presets[#ns.db.presets]
        assertTrue(copy ~= base)
        assertDeepEquals(copy.map.PALADIN, { DEFAULT = { "might" }, HEALER = { "wisdom" } }, "the {} TANK became nil in the copy")
        assertEquals(P.ResolveBuff(copy, "PALADIN", "TANK"), "might"); assertEquals(P.ResolveBuff(copy, "PALADIN", "HEALER"), "wisdom")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("sparse save -> reload: a role reset with 'Use class row' stays inheriting and the override next to it survives", function()
        local ns = boot("PALADIN")
        local cells = BU.cells(ns)
        BU.openCell(cells.byKey["PALADIN:DEFAULT"]); BU.pick("Blessing of Wisdom")
        BU.openCell(cells.byKey["PALADIN:TANK"]); BU.pick("Blessing of Might"); BU.pick("Use class row")
        BU.openCell(cells.byKey["PALADIN:HEALER"]); BU.pick("Blessing of Light"); BU.close()
        mock.fire("PLAYER_LOGOUT")
        local saved = dc(_G.HealerForeverCharDB)
        local savedPal = saved.presets and saved.presets[1] and saved.presets[1].map and saved.presets[1].map.PALADIN
        assertNotNil(savedPal, "the edited preset is saved")
        assertNil(savedPal.TANK, "nothing is written for the reset role"); assertDeepEquals(savedPal.HEALER, { "light" })
        local ns2 = boot("PALADIN", { char = saved })
        local p2 = ns2.db.presets[1]
        assertNil(p2.map.PALADIN.TANK); assertDeepEquals(p2.map.PALADIN.HEALER, { "light" }); assertDeepEquals(p2.map.PALADIN.DEFAULT, { "wisdom" })
        local c2 = BU.cells(ns2)
        assertTrue(noteShown(c2, "PALADIN:TANK")); assertFalse(noteShown(c2, "PALADIN:HEALER"))
        BU.openCell(c2.byKey["PALADIN:TANK"]); assertDeepEquals(BU.checked(), { "Use class row" })
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a {} role saved by the old code is cleaned to nil on load and stays absent after the next save", function()
        local ns = boot("PALADIN", { char = oldNoneEverywhere() })
        mock.fire("PLAYER_LOGOUT")
        local saved = dc(_G.HealerForeverCharDB)
        local pal = saved.presets and saved.presets[1] and saved.presets[1].map and saved.presets[1].map.PALADIN
        assertNotNil(pal, "the preset differs from the default, so it is saved")
        assertDeepEquals(pal.DEFAULT, {}, "the class row None is kept")
        for _, r in ipairs(ROLE_NAMES) do assertNil(pal[r], r) end
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(P.RoleInherits(ns.db.presets[1], "PALADIN", "TANK"))
    end)
    it("the role popup works in combat (no protected calls) and with every value secret", function()
        local ns = boot("MAGE")
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        S.secretAll = true
        local cells = BU.cells(ns)
        for _, row in ipairs(cells.rows) do
            BU.openCell(row.cell)
            for _, r in ipairs((BU.rows())) do BU.click(r.frame) end
            if row.role ~= "DEFAULT" then BU.pick("Use class row") end
        end
        BU.close()
        assertEquals(#mock.violations, 0); assertEquals(#mock.softViolations, 0); assertEquals(#mock.errors, 0, errstr())
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        for _, class in ipairs(ALL) do
            for _, r in ipairs(C.ROLES[class]) do assertNil(ns.db.presets[1].map[class] and ns.db.presets[1].map[class][r], class .. " " .. r .. " reset") end
        end
    end)
    it("popup geometry: the 'Use class row' row, headers and options never overlap and fit inside the popup (every caster, role and class rows)", function()
        for _, class in ipairs({ "PALADIN", "PRIEST", "MAGE", "DRUID" }) do
            local ns = boot(class)
            local cells = BU.cells(ns)
            for _, key in ipairs({ "WARRIOR:DEFAULT", "WARRIOR:TANK", "PALADIN:HEALER" }) do
                BU.openCell(cells.byKey[key])
                local popup = BU.popup()
                local ps = st(popup)
                local root = { l = 0, t = 0, r = ps.w, b = ps.h }
                local items = {}
                for _, row in ipairs(popup.rows) do
                    if st(row).shown then
                        local p = st(row).points[1]
                        local t = -p[3]
                        items[#items + 1] = { name = "row " .. tostring(st(row.text).text), rect = { l = 6, r = ps.w - 6, t = t, b = t + 20 } }
                    end
                end
                for _, h in ipairs(popup.headers) do
                    if st(h).shown then
                        local p = st(h).points[1]
                        local t = -p[3]
                        items[#items + 1] = { name = "header " .. tostring(st(h).text), rect = { l = 8, r = ps.w - 8, t = t, b = t + 12 } }
                    end
                end
                assertTrue(#items >= 2, class .. " " .. key)
                for i = 1, #items do
                    assertTrue(geo.inside(items[i].rect, root), class .. " " .. key .. ": " .. items[i].name .. " " .. geo.fmt(items[i].rect) .. " outside " .. geo.fmt(root))
                    for j = i + 1, #items do
                        assertFalse(geo.overlap(items[i].rect, items[j].rect), class .. " " .. key .. ": " .. items[i].name .. " overlaps " .. items[j].name)
                    end
                end
            end
        end
    end)
end)

-- ======================================================================== the pane header
describe("role inherit: the pane header", function()
    local HEADER = "Pick which of YOUR buffs each class and role gets. One per group; groups stack. Role rows follow the class row unless you pick buffs; 'Use class row' resets them."
    -- Text model for GameFontDisable (Friz Quadrata 12): ~6.5 px per character (a conservative average), 14 px per line, word wrap.
    local CHAR_W, LINE_H, TITLE_H = 6.5, 14, 18
    local function wrapLines(text, width)
        local lines, cur = 0, 0
        for word in text:gmatch("%S+") do
            local w = #word * CHAR_W
            if cur == 0 then cur = w; lines = math.max(lines, 1)
            elseif cur + CHAR_W + w <= width then cur = cur + CHAR_W + w
            else lines = lines + 1; cur = w end
        end
        return lines
    end
    it("the header explains that role rows follow the class row and names 'Use class row'", function()
        local ns = boot("PALADIN")
        local hint
        for _, f in ipairs(mock.frames) do if st(f).kind == "FontString" and st(f).text == HEADER then hint = f end end
        assertNotNil(hint, "header text missing")
        assertTrue(st(hint).shown ~= false)
        assertEquals(st(hint).w, 540); assertTrue(st(hint).wordWrap and true or false, "wraps")
        local _ = ns
    end)
    it("the wrapped header fits above the Preset row (dropdown at y -52, label at -56) and inside the 540 px pane", function()
        local ns = boot("PALADIN")
        local hint, title
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.kind == "FontString" and s.text == HEADER then hint = f end
            if s.kind == "FontString" and s.text == "Buff Presets" and s.points[1] and s.points[1][2] == 0 then title = f end
        end
        assertNotNil(hint); assertNotNil(title)
        local hp = st(hint).points[1]
        assertTrue(hp[2] == title, "the hint hangs under the title"); assertEquals(hp[3], "BOTTOMLEFT"); assertEquals(hp[5], -4)
        local lines = wrapLines(HEADER, st(hint).w)
        local bottom = TITLE_H + 4 + lines * LINE_H
        assertTrue(lines <= 2, "header wraps to " .. lines .. " lines")
        assertTrue(bottom <= 52, "header bottom " .. bottom .. " overlaps the Preset row at 52")
        local _ = ns
    end)
end)
