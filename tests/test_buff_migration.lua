-- Schema 4 (preset cells and Self are SETS of buff keys): migration of the owner's REAL v3 profile (a copy in
-- tests/fixtures/owner-char-pre-buffgroups.lua; the original in .settings-backup/pre-buffgroups is never touched), plus the
-- v1 / v2 / v3 formats. Every class/role/self must resolve to exactly the buff it resolved to under v3.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")
local F = require("framework")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local deepcopy = Fx.deepcopy

local function pure(char, account)
    mock.install()
    local ns = {}
    local _, _, errs = L.loadContract(ns)
    if next(errs) then error(tostring(select(2, next(errs)))) end
    if char ~= nil then _G.HealerForeverCharDB = deepcopy(char) end
    if account ~= nil then _G.HealerForeverDB = deepcopy(account) end
    mock.printed = {}
    ns:Init()
    return ns
end
local function loadFixture(name) return Fx.loadSaved(HF_TESTS .. "/fixtures/" .. name, "HealerForeverCharDB") end

-- How a v3 profile resolved a cell (the old rule, written independently of the addon): role entry if valid and present, else DEFAULT;
-- "none" = nothing; self wins for the player when preset.self is set.
local ROLES
local function v3Resolve(preset, class, role, isSelf)
    local function norm(v) if v == nil or v == "none" then return nil end return v end
    if isSelf and preset.self ~= nil then return norm(preset.self) end
    local entry = preset.map and preset.map[class]
    if type(entry) == "string" then return norm(entry) end
    if type(entry) ~= "table" then return nil end
    if role and role ~= "DEFAULT" and entry[role] ~= nil then
        local valid = false
        for _, r in ipairs(ROLES[class] or {}) do if r == role then valid = true end end
        if valid then return norm(entry[role]) end
    end
    return norm(entry.DEFAULT)
end

local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local function allCells(ns)
    ROLES = ns.Classes.ROLES
    local out = {}
    for _, c in ipairs(CLASSES) do
        local roles = { false, "DEFAULT" }
        for _, r in ipairs(ROLES[c]) do roles[#roles + 1] = r end
        for _, role in ipairs(roles) do for _, isSelf in ipairs({ false, true }) do out[#out + 1] = { c, role or nil, isSelf } end end
    end
    return out
end

-- every key of `sub` is in `full` with an equal value (tables compared recursively as subsets)
local function subsetDiff(sub, full, path)
    if type(sub) ~= "table" then if sub ~= full then return path .. ": " .. tostring(sub) .. " vs " .. tostring(full) end return nil end
    if type(full) ~= "table" then return path .. ": table vs " .. type(full) end
    for k, v in pairs(sub) do local d = subsetDiff(v, full[k], path .. "." .. tostring(k)); if d then return d end end
end

-- ======================================================================== the fixture itself
describe("buff migration: the real v3 profile copy", function()
    it("the fixture is a byte-for-byte copy of the backup, and the backup is untouched", function()
        local a = Fx.backupFile("pre-buffgroups", "char")
        if not a then return skip("backup comparison", ".settings-backup is not in git (CI / fresh clone)") end
        local b = HF_TESTS .. "/fixtures/owner-char-pre-buffgroups.lua"
        local ok = os.execute('cmp -s "' .. a .. '" "' .. b .. '"')
        assertTrue(ok == 0 or ok == true, "fixture differs from the backup")
    end)
    it("it is the real profile: schema 3, four presets, string cells, a 'kings' self, the owner's bindings and error log", function()
        local char = loadFixture("owner-char-pre-buffgroups.lua")
        assertEquals(char.version, 3); assertEquals(#char.presets, 4)
        assertEquals(char.presets[1].self, "kings"); assertEquals(type(char.presets[1].map.PALADIN.DEFAULT), "string")
        assertEquals(char.bindings["|1"].spell, "Holy Light"); assertTrue(#char.errorLog >= 4)
    end)
end)

-- ======================================================================== real profile: v3 -> v4
describe("buff migration: the owner's real v3 profile loads as schema 4 with identical behaviour", function()
    local raw = loadFixture("owner-char-pre-buffgroups.lua")
    local ns = pure(raw)
    it("loads without error as schema 4, keeping the migratedFrom marker", function()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(ns.db.version, 4); assertEquals(ns.SchemaVersion(), 4)
        assertEquals(ns.db.migratedFrom, "account")
        assertNil(ns.downgradeFrom)
    end)
    it("all four presets are kept, in order, with their names, extras and activePreset", function()
        assertEquals(#ns.db.presets, #raw.presets)
        for i, p in ipairs(raw.presets) do
            assertEquals(ns.db.presets[i].name, p.name, "name " .. i)
            assertDeepEquals(ns.db.presets[i].extras, p.extras or {}, "extras " .. i)
        end
        assertEquals(ns.db.activePreset, raw.activePreset or 1)
    end)
    it("EVERY class / role / self cell of EVERY preset resolves to exactly the same buff as under v3", function()
        local checked = 0
        for pi, raw_p in ipairs(raw.presets) do
            for _, cell in ipairs(allCells(ns)) do
                local class, role, isSelf = cell[1], cell[2], cell[3]
                local want = v3Resolve(raw_p, class, role, isSelf)
                local got = ns.Presets.ResolveBuff(ns.db.presets[pi], class, role, isSelf)
                assertEquals(got, want, string.format("preset %d %s %s self=%s", pi, class, tostring(role), tostring(isSelf)))
                local set = ns.Presets.CellBuffs(ns.db.presets[pi], class, role, isSelf)
                assertDeepEquals(set, want and { want } or {}, "set of " .. class)
                checked = checked + 1
            end
        end
        assertTrue(checked > 150, "checked " .. checked .. " cells")
    end)
    it("the stored cells are now sets (arrays of keys), never strings", function()
        for _, p in ipairs(ns.db.presets) do
            for class, entry in pairs(p.map) do
                for role, v in pairs(entry) do assertEquals(type(v), "table", class .. "." .. role) end
            end
            if p.self ~= nil then assertEquals(type(p.self), "table") end
        end
        assertDeepEquals(ns.db.presets[1].self, { "kings" })
    end)
    it("the missing-buff logic gives the same answers (GetMissingBuff on all cells with an empty aura list)", function()
        for pi, raw_p in ipairs(raw.presets) do
            for _, cell in ipairs(allCells(ns)) do
                local want = v3Resolve(raw_p, cell[1], cell[2], cell[3])
                local got = ns.Presets.GetMissingBuff(cell[1], {}, ns.db.presets[pi], 0, ns.Classes.BUFFS, 60, cell[2], cell[3])
                assertEquals(got, want, "preset " .. pi .. " " .. cell[1])
            end
        end
    end)
    it("bindings, auras, minimap, error log and every other saved value are unchanged", function()
        for k, v in pairs(raw) do
            if k ~= "presets" and k ~= "version" then
                local d = subsetDiff(v, ns.db[k], k)
                assertNil(d, d)
            end
        end
        local n, m = 0, 0
        for k, v in pairs(ns.db.bindings) do n = n + 1; assertEquals(v.spell, raw.bindings[k] and raw.bindings[k].spell, k) end
        for _ in pairs(raw.bindings) do m = m + 1 end
        assertEquals(n, m, "no binding added or lost")
        assertEquals(#ns.db.errorLog, #raw.errorLog)
        assertEquals(ns.db.errorLog[4].count, 279)
    end)
    it("the real profile is not mutated by loading (the raw table is only read)", function()
        assertEquals(raw.version, 3); assertEquals(raw.presets[1].self, "kings")
    end)
    it("a sparse save writes schema 4 with set-shaped presets and nothing the profile did not have", function()
        local save = ns:BuildSaveTable()
        assertEquals(save.version, 4)
        assertEquals(#save.presets, 4)
        assertDeepEquals(save.presets[1].self, { "kings" })
        assertEquals(type(save.presets[1].map.PALADIN.DEFAULT), "table")
        assertNil(save.debugLog, "an empty debug log is not saved")
        assertEquals(save.bindings["|1"].spell, "Holy Light")
    end)
    it("save -> reload is stable: the second load equals the first and a second save is identical", function()
        local save = ns:BuildSaveTable()
        local ns2 = pure(save)
        assertEquals(ns2.db.version, 4)
        assertTrue(F.deepEq(ns.db.presets, ns2.db.presets), "presets differ after a reload")
        assertTrue(F.deepEq(ns.db.bindings, ns2.db.bindings), "bindings differ after a reload")
        assertTrue(F.deepEq(ns:BuildSaveTable(), ns2:BuildSaveTable()), "a second save differs")
        local save3 = pure(ns2:BuildSaveTable()):BuildSaveTable()
        assertTrue(F.deepEq(save, save3), "three save/load cycles drift")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("running the 3 -> 4 step again on the migrated data changes nothing (idempotent)", function()
        local before = deepcopy(ns.db.presets)
        ns.migrations[3](ns.db)
        assertTrue(F.deepEq(before, ns.db.presets))
        ns.migrations[3](ns.db)
        assertTrue(F.deepEq(before, ns.db.presets))
    end)
    it("the whole addon boots on the migrated real profile: buff buttons, pane and slash commands work", function()
        mock.install(); local S = mock.state
        S.units.party1 = { name = "T", class = "WARRIOR", health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = "TANK" }
        local n = {}
        for _, rel in ipairs(toc.files) do if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, n)) end end
        _G.HealerForeverCharDB = deepcopy(raw)
        mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers(); mock.fire("PLAYER_LOGIN"); mock.flushTimers()
        mock.setGroup(2); mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
        n.Options:Show("buffs"); mock.flushTimers()
        for _, cmd in ipairs({ "version", "debug buffs", "profile", "errors" }) do assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, cmd), cmd) end
        local b
        for _, f in ipairs(mock.frames) do if st(f).name and st(f).name:match("^HealerForeverBuff%d$") and f.unit == "party1" then b = f end end
        assertNotNil(b)
        assertEquals(b.buffKey, "kings", "the owner's 5-man preset gives a Warrior Kings")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== older formats
describe("buff migration: v1, v2 and v3 formats all end at schema 4 with the same resolution", function()
    it("the v2 character fixture (real older profile): schema 4, same resolution, same bindings", function()
        local raw = loadFixture("owner-char-v3.lua")
        assertEquals(raw.version, 2)
        local ns = pure(raw)
        assertEquals(ns.db.version, 4); assertEquals(#mock.errors, 0, errstr())
        assertEquals(#ns.db.presets, #raw.presets)
        -- the old format lacked entries for some classes: MigratePreset fills those from the legacy template, so compare only what the file defines
        for pi, rp in ipairs(raw.presets) do
            for class, entry in pairs(rp.map) do
                for role, v in pairs(entry) do
                    assertDeepEquals(ns.Presets.CellBuffs(ns.db.presets[pi], class, role, false), v ~= "none" and { v } or {}, string.format("p%d %s %s", pi, class, role))
                end
            end
            if rp.self ~= nil then assertDeepEquals(ns.Presets.CellBuffs(ns.db.presets[pi], "PALADIN", nil, true), rp.self ~= "none" and { rp.self } or {}) end
        end
        for k, v in pairs(raw.bindings) do assertEquals(ns.db.bindings[k].spell, v.spell, k) end
    end)
    it("the v2 account fixture loaded as a character profile", function()
        local raw = Fx.userAccount()
        local ns = pure(raw)
        assertEquals(ns.db.version, 4); assertEquals(#mock.errors, 0, errstr())
        assertEquals(#ns.db.presets, #raw.presets)
        for pi, rp in ipairs(raw.presets) do
            for class, entry in pairs(rp.map) do
                for role, v in pairs(entry) do
                    assertDeepEquals(ns.Presets.CellBuffs(ns.db.presets[pi], class, role, false), v ~= "none" and { v } or {})
                end
            end
        end
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light")
    end)
    it("a v1 profile (string maps, no roles): migrates through steps 1-3", function()
        local raw = { version = 1, activePreset = 2, presets = { { name = "Old A", map = { PALADIN = "kings", WARRIOR = "might", MAGE = "wisdom" } },
            { name = "Old B", map = { PALADIN = "light" } } }, bindings = { ["|1"] = { type = "spell", spell = "Holy Light" } } }
        local ns = pure(raw)
        assertEquals(ns.db.version, 4); assertEquals(ns.db.activePreset, 2)
        assertDeepEquals(ns.db.presets[1].map.PALADIN.DEFAULT, { "kings" }); assertDeepEquals(ns.db.presets[1].map.WARRIOR.DEFAULT, { "might" })
        assertDeepEquals(ns.db.presets[2].map.PALADIN.DEFAULT, { "light" })
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a minimal v3 profile with a string self and a 'none' cell", function()
        local raw = { version = 3, presets = { { name = "P", self = "none", map = { PALADIN = { DEFAULT = "none", TANK = "might" }, MAGE = { DEFAULT = "kings" } }, extras = {} } } }
        local ns = pure(raw)
        local p = ns.db.presets[1]
        assertDeepEquals(p.self, {}); assertDeepEquals(p.map.PALADIN.DEFAULT, {}); assertDeepEquals(p.map.PALADIN.TANK, { "might" }); assertDeepEquals(p.map.MAGE.DEFAULT, { "kings" })
        assertNil(ns.Presets.ResolveBuff(p, "PALADIN", "HEALER", true), "self = none stays 'no buff for me'")
        assertEquals(ns.Presets.ResolveBuff(p, "PALADIN", "TANK", false), "might")
    end)
    it("a profile that is already schema 4 (sets) is not changed by loading", function()
        local raw = { version = 4, presets = { { name = "P", self = { "wisdom" }, map = { PRIEST = { DEFAULT = { "fortitude", "spirit" }, HEALER = { "fortitude" }, TANK = { "fortitude" } } }, extras = {} } } }
        local ns = pure(raw)
        local p = ns.db.presets[1]
        assertDeepEquals(p.self, { "wisdom" }); assertDeepEquals(p.map.PRIEST.DEFAULT, { "fortitude", "spirit" }); assertDeepEquals(p.map.PRIEST.HEALER, { "fortitude" }); assertNil(p.map.PRIEST.TANK, "a Priest cannot tank: the invalid role cell is dropped")
        assertEquals(ns.db.version, 4)
    end)
    it("a corrupted cell never crashes the migration", function()
        local raw = { version = 3, presets = { { name = "X", map = { PALADIN = { DEFAULT = "might", HEALER = 5, TANK = { "kings" }, DAMAGER = true },
            MAGE = 7, PRIEST = "bogus" }, extras = {} } } }
        local ok, ns = pcall(pure, raw)
        assertTrue(ok, tostring(ns))
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(type(ns.db.presets[1].map.PALADIN), "table"); assertEquals(type(ns.db.presets[1].map.MAGE), "table")
    end)
    it("a profile from a NEWER schema is kept as is (never migrated backwards)", function()
        local raw = { version = 9, presets = { { name = "F", map = { PALADIN = { DEFAULT = { "might" } } }, extras = {} } } }
        local ns = pure(raw)
        assertEquals(ns.db.version, 9); assertEquals(ns.downgradeFrom, 9)
        assertDeepEquals(ns.db.presets[1].map.PALADIN.DEFAULT, { "might" })
    end)
    it("save -> reload stability for every older format", function()
        for _, raw in ipairs({ loadFixture("owner-char-v3.lua"), Fx.userAccount(),
            { version = 1, presets = { { name = "A", map = { PALADIN = "kings" } } } } }) do
            local ns = pure(raw)
            local s1 = ns:BuildSaveTable()
            local ns2 = pure(s1)
            assertTrue(F.deepEq(s1, ns2:BuildSaveTable()), "unstable save/reload")
            assertTrue(F.deepEq(ns.db.presets, ns2.db.presets))
        end
    end)
end)
