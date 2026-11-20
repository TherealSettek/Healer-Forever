-- New characters start empty (0.12.1, owner decision 2026-11-20). A character without saved settings starts from the
-- defaults and never copies the account-wide HealerForeverDB on its own. A character that an older version seeded from the
-- account DB (migratedFrom = "account") with buffs its class can't cast gets its presets and click-casting reset ONCE
-- (marker "account-cleared", one chat line). /hf copyaccount on a class mismatch copies everything but presets/bindings.
-- The owner's Paladin (class matches the copied buffs) and an unreadable class change nothing at all.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")
local PS = require("party_snapshot")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local deepcopy = Fx.deepcopy
local S
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function printed() return table.concat(mock.printed, "\n") end

-- How many times the one-time cleanup message was printed since the last mock.install.
local MSG_PART = "another class's buff presets and click-casting"
local function msgCount()
    local n = 0
    for _, line in ipairs(mock.printed) do if line:find(MSG_PART, 1, true) then n = n + 1 end end
    return n
end

-- Full addon boot like the game. opts: class, account, char, group, combat, secretAll,
-- duringLoad(S) / afterLoad(S): change the world only around ADDON_LOADED (that is when the cleanup runs).
local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.class then S.units.player.class = opts.class end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.account ~= nil then _G.HealerForeverDB = deepcopy(opts.account) end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    if opts.combat then S.combat = true end
    if opts.secretAll then S.secretAll = true end
    local restore
    if opts.duringLoad then restore = opts.duringLoad(S) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if restore then restore() end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 2)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
-- The sparse table the game writes on logout.
local function logoutSave()
    mock.fire("PLAYER_LOGOUT")
    return deepcopy(_G.HealerForeverCharDB)
end
local function slash(msg)
    local fn; for _, f in pairs(_G.SlashCmdList) do fn = f end
    mock.printed = {}
    local ok, err = pcall(fn, msg)
    assertTrue(ok, tostring(err))
    mock.flushTimers()
    return printed()
end

-- A Paladin's preset in the 0.12 format: blessings on every class row, a role row and "Self".
local function paladinPresets()
    return {
        { name = "Default", map = { WARRIOR = { DEFAULT = { "kings" }, TANK = { "kings", "sanctuary" } }, MAGE = { DEFAULT = { "wisdom" } },
            DRUID = { DEFAULT = "might" } }, self = { "kings" }, extras = {} },
        { name = "Raid", map = { PRIEST = { DEFAULT = { "salvation" } } }, extras = {} },
    }
end
local PALADIN_BINDINGS = {
    ["|1"] = { type = "spell", spell = "Holy Light" }, ["|2"] = { type = "spell", spell = "Flash of Light" },
    ["ctrl|1"] = { type = "spell", spell = "Purify" }, ["meta|3"] = { type = "spell", spell = "Lay on Hands" },
}
-- A character DB as an older version wrote it after seeding from the Paladin's account settings.
local function seededChar(extra)
    local t = {
        version = 4, migratedFrom = "account", activePreset = 2,
        presets = paladinPresets(), bindings = deepcopy(PALADIN_BINDINGS),
        frames = { layout = "vertical", locked = true, point = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 321, y = -123 } },
        minimap = { angle = 77 }, auras = { maxBuffs = 3 }, ui = { modSet = "mac" },
        roleOverrides = { ["Tank-TestRealm"] = "TANK" },
    }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
-- A preset map with a rule for every class, as the addon saves it (a modified preset is saved whole). Partial maps are not
-- used for "own buffs" cases on purpose: Presets.MigratePreset fills classes missing from an old preset with the legacy
-- Paladin template, which is foreign to a Druid.
local ALL_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local function fullMap(rules)
    local map = {}
    for _, c in ipairs(ALL_CLASSES) do map[c] = rules[c] or { DEFAULT = {} } end
    return map
end
local function assertDefaultsPresetsBindings(ns, label)
    assertEquals(#ns.db.presets, 1, label .. ": one default preset")
    assertEquals(ns.db.presets[1].name, ns.Presets.DEFAULTS[1].name, label)
    assertNil(ns.db.presets[1].self, label .. ": no Self override")
    assertFalse(ns.PresetsHaveForeignBuffs(ns.db.presets, "WARRIOR"), label .. ": no buff in any cell")
    assertEquals(#(ns.db.presets[1].extras or {}), 0, label .. ": no extras")
    assertEquals(ns.db.activePreset, 1, label)
    assertDeepEquals(ns.db.bindings, ns.DEFAULTS.bindings, label .. ": default click-casting")
end

-- ======================================================================== ns.PresetsHaveForeignBuffs
describe("new char: ns.PresetsHaveForeignBuffs (pure)", function()
    local ns = boot()
    local F = ns.PresetsHaveForeignBuffs
    it("bad input is never 'foreign'", function()
        assertFalse(F(nil, "DRUID")); assertFalse(F("x", "DRUID")); assertFalse(F(5, "DRUID"))
        assertFalse(F(paladinPresets(), nil)); assertFalse(F(paladinPresets(), 7)); assertFalse(F({}, "DRUID"))
        assertFalse(F({ 5, "x", { map = "m" }, { map = { DRUID = 3 } }, { self = 9 } }, "DRUID"))
    end)
    it("the defaults and empty / 'none' cells hold nothing foreign for any class", function()
        for _, c in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
            assertFalse(F(deepcopy(ns.Presets.DEFAULTS), c), c)
            assertFalse(F({ { map = { MAGE = { DEFAULT = "none", TANK = { "none" } }, DRUID = { DEFAULT = {} } }, self = "none" } }, c), c)
        end
    end)
    it("a class's own buffs are not foreign; another class's are (string cell, set cell, role row, Self)", function()
        assertFalse(F(paladinPresets(), "PALADIN"))
        assertTrue(F(paladinPresets(), "DRUID"))
        assertTrue(F({ { map = { MAGE = { DEFAULT = "kings" } } } }, "DRUID"), "string cell")
        assertTrue(F({ { map = { MAGE = { DEFAULT = { "motw", "kings" } } } } }, "DRUID"), "one foreign key in a set")
        assertTrue(F({ { map = { WARRIOR = { DEFAULT = { "motw" }, TANK = { "light" } } } } }, "DRUID"), "role row")
        assertTrue(F({ { map = {}, self = { "kings" } } }, "DRUID"), "Self cell")
        assertTrue(F({ { map = {}, self = "kings" } }, "DRUID"), "Self as a string")
        assertTrue(F({ { map = {} }, { map = { ROGUE = { DEFAULT = "wisdom" } } } }, "DRUID"), "second preset")
        assertFalse(F({ { map = { MAGE = { DEFAULT = { "motw" }, TANK = "thorns" } }, self = { "thorns" } } }, "DRUID"))
        assertFalse(F({ { map = { MAGE = { DEFAULT = { "fortitude", "spirit", "shadowprot" } } } } }, "PRIEST"))
        assertTrue(F({ { map = { MAGE = { DEFAULT = { "fortitude" } } } } }, "MAGE"))
        assertFalse(F({ { map = { MAGE = { DEFAULT = { "arcaneint", "dampen" } } } } }, "MAGE"))
    end)
    it("classes without a buff catalog (Warrior, Shaman, Rogue...) find every buff foreign", function()
        for _, c in ipairs({ "WARRIOR", "SHAMAN", "ROGUE", "HUNTER", "WARLOCK" }) do
            assertTrue(F({ { map = { MAGE = { DEFAULT = "kings" } } } }, c), c)
            assertTrue(F({ { map = {}, self = { "motw" } } }, c), c)
        end
    end)
    it("non-string keys inside a set are ignored, extras are not buff cells", function()
        assertFalse(F({ { map = { MAGE = { DEFAULT = { 5, true } } }, extras = { { spell = "Holy Light", roles = { TANK = true } } } } }, "DRUID"))
    end)
    it("is pure: the presets are not modified", function()
        local p = paladinPresets(); local snap = deepcopy(p)
        F(p, "DRUID"); F(p, "PALADIN")
        assertDeepEquals(p, snap)
    end)
end)

describe("new char: legacy template fill and the foreign check", function()
    it("a partial Druid-only preset map gets the legacy Paladin rules for missing classes on load, so it counts as foreign", function()
        local ns = boot({ class = "DRUID" })
        local p = { name = "Partial", map = { WARRIOR = { DEFAULT = { "motw" } } } }
        assertFalse(ns.PresetsHaveForeignBuffs({ p }, "DRUID"), "before MigratePreset")
        ns.Presets.MigratePreset(p)
        assertTrue(ns.PresetsHaveForeignBuffs({ p }, "DRUID"), "MigratePreset fills missing classes from the legacy template")
        local full = { name = "Full", map = fullMap({ WARRIOR = { DEFAULT = { "motw" } } }) }
        ns.Presets.MigratePreset(full)
        assertFalse(ns.PresetsHaveForeignBuffs({ full }, "DRUID"), "a complete map is left alone")
    end)
end)

-- ======================================================================== ns.PlayerClassToken
describe("new char: ns.PlayerClassToken reads the class safely", function()
    it("a known class, and nil when the API is missing, raises, returns a secret, nil or an unknown class", function()
        local ns = boot({ class = "DRUID" })
        assertEquals(ns.PlayerClassToken(), "DRUID")
        S.secretClass = { player = true }; assertNil(ns.PlayerClassToken()); S.secretClass = nil
        S.classError = { player = true }; assertNil(ns.PlayerClassToken()); S.classError = nil
        S.units.player.class = "DEATHKNIGHT"; assertNil(ns.PlayerClassToken())
        S.units.player.class = "PALADIN"; assertEquals(ns.PlayerClassToken(), "PALADIN")
        local real = _G.UnitClass
        _G.UnitClass = function() return nil end; assertNil(ns.PlayerClassToken())
        _G.UnitClass = function() return "Druid", 42 end; assertNil(ns.PlayerClassToken())
        _G.UnitClass = nil; assertNil(ns.PlayerClassToken())
        _G.UnitClass = real
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== new characters
describe("new char: a new character ignores the account-wide settings", function()
    local account = Fx.userAccount()
    local snap = deepcopy(account)
    local ns = boot({ class = "DRUID", account = account })
    it("a new Druid with the full Paladin account DB starts from the defaults", function()
        assertEquals(#mock.errors, 0, errstr())
        assertNil(ns.db.migratedFrom)
        assertDefaultsPresetsBindings(ns, "new druid")
        assertEquals(ns.db.frames.layout, ns.DEFAULTS.frames.layout); assertEquals(ns.db.minimap.angle, ns.DEFAULTS.minimap.angle)
        assertDeepEquals(ns.db.frames.point, ns.DEFAULTS.frames.point, "frame position must not come from the account DB")
    end)
    it("prints no cleanup message", function() assertEquals(msgCount(), 0, printed()) end)
    it("the account DB is untouched (load, logout)", function()
        assertDeepEquals(_G.HealerForeverDB, snap)
        local save = logoutSave()
        assertDeepEquals(_G.HealerForeverDB, snap)
        assertDeepEquals(save, { version = ns.DEFAULTS.version }, "a new character saves only the version")
    end)
    it("a reload stays at the defaults with no marker and no message", function()
        local ns2 = boot({ class = "DRUID", account = account, char = { version = ns.DEFAULTS.version } })
        assertNil(ns2.db.migratedFrom); assertDefaultsPresetsBindings(ns2, "reload"); assertEquals(msgCount(), 0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a new Paladin also starts from the defaults (no automatic copy for anyone)", function()
        local ns2 = boot({ class = "PALADIN", account = account })
        assertNil(ns2.db.migratedFrom); assertDefaultsPresetsBindings(ns2, "new paladin"); assertEquals(msgCount(), 0)
        assertDeepEquals(_G.HealerForeverDB, snap)
    end)
    it("in combat and with everything secret a new character still starts clean, without protected calls", function()
        local ns2 = boot({ class = "DRUID", account = account, combat = true, secretAll = true })
        assertNil(ns2.db.migratedFrom); assertDefaultsPresetsBindings(ns2, "combat"); assertEquals(msgCount(), 0)
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0, "protected calls in combat")
    end)
end)

-- ======================================================================== one-time cleanup
describe("new char: a Druid seeded with the Paladin's settings is cleaned once", function()
    local seed = seededChar()
    local ns = boot({ class = "DRUID", char = seed, account = Fx.userAccount() })
    it("presets and click-casting go back to the defaults; the marker becomes 'account-cleared'", function()
        assertEquals(#mock.errors, 0, errstr())
        assertDefaultsPresetsBindings(ns, "cleaned")
        assertEquals(ns.db.migratedFrom, "account-cleared")
        assertFalse(ns.PresetsHaveForeignBuffs(ns.db.presets, "DRUID"))
    end)
    it("prints exactly one chat line, with the documented text", function()
        assertEquals(msgCount(), 1, printed())
        assertNotNil(printed():find(ns.FOREIGN_SEED_CLEARED_MSG, 1, true), printed())
    end)
    it("layout, lock, frame position, minimap, auras, mod set and role overrides are kept", function()
        assertEquals(ns.db.frames.layout, "vertical"); assertEquals(ns.db.frames.locked, true)
        assertDeepEquals(ns.db.frames.point, seed.frames.point)
        assertEquals(ns.db.minimap.angle, 77); assertEquals(ns.db.auras.maxBuffs, 3); assertEquals(ns.db.ui.modSet, "mac")
        assertEquals(ns.db.roleOverrides["Tank-TestRealm"], "TANK")
    end)
    it("the unit buttons use the default click-casting (no Holy Light macro left)", function()
        for _, f in ipairs(mock.frames) do
            local s = rawget(f, "__s")
            if tostring(s.name):match("^HealerForeverUnit") then
                for k, v in pairs(s.attrs) do
                    assertTrue(type(v) ~= "string" or not v:find("Holy Light", 1, true), tostring(s.name) .. " " .. tostring(k) .. " = " .. tostring(v))
                end
            end
        end
    end)
    local save = logoutSave()
    it("the sparse save keeps the marker and the kept settings and drops presets/bindings", function()
        assertEquals(save.migratedFrom, "account-cleared")
        assertNil(save.presets); assertNil(save.bindings); assertNil(save.activePreset)
        assertEquals(save.frames.layout, "vertical"); assertEquals(save.minimap.angle, 77)
    end)
    it("after save and reload: no second message, nothing changes", function()
        local ns2 = boot({ class = "DRUID", char = save, account = Fx.userAccount() })
        assertEquals(msgCount(), 0, printed())
        assertEquals(ns2.db.migratedFrom, "account-cleared")
        assertDeepEquals(logoutSave(), save)
    end)
    it("a Druid can then set its own buffs and keep them over reloads (the cleanup never runs again)", function()
        local ns2 = boot({ class = "DRUID", char = save })
        ns2.Presets.SetSelf(ns2.db.presets[1], "motw"); ns2.db.bindings["|1"] = { type = "spell", spell = "Rejuvenation" }
        ns2:Changed("all"); mock.flushTimers()
        local save2 = logoutSave()
        local ns3 = boot({ class = "DRUID", char = save2 })
        assertEquals(msgCount(), 0); assertEquals(ns3.db.bindings["|1"].spell, "Rejuvenation")
        assertDeepEquals(ns3.db.presets[1].self, { "motw" })
    end)
    it("a character already marked 'account-cleared' is never cleaned again, even with foreign buffs", function()
        local ns2 = boot({ class = "DRUID", char = seededChar({ migratedFrom = "account-cleared" }) })
        assertEquals(msgCount(), 0); assertEquals(ns2.db.bindings["|1"].spell, "Holy Light")
        assertTrue(ns2.PresetsHaveForeignBuffs(ns2.db.presets, "DRUID"))
    end)
    it("a character without the account marker is never cleaned (only seeded characters are)", function()
        local ns2 = boot({ class = "DRUID", char = seededChar({ migratedFrom = false }) })
        assertEquals(msgCount(), 0); assertEquals(ns2.db.bindings["|1"].spell, "Holy Light")
        local ns3 = boot({ class = "DRUID", char = (function() local c = seededChar(); c.migratedFrom = nil; return c end)() })
        assertEquals(msgCount(), 0); assertEquals(ns3.db.bindings["|1"].spell, "Holy Light"); assertNil(ns3.db.migratedFrom)
    end)
    it("works the same in combat (/reload in combat) and with everything secret: no errors, no protected calls", function()
        local ns2 = boot({ class = "DRUID", char = seed, combat = true, secretAll = true })
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0, "protected calls in combat")
        assertEquals(ns2.db.migratedFrom, "account-cleared"); assertDefaultsPresetsBindings(ns2, "combat"); assertEquals(msgCount(), 1)
    end)
end)

describe("new char: other classes seeded with the Paladin's buffs are cleaned too", function()
    for _, class in ipairs({ "WARRIOR", "SHAMAN", "PRIEST", "MAGE", "ROGUE" }) do
        it(class .. " is cleaned once with the message", function()
            local ns = boot({ class = class, char = seededChar() })
            assertEquals(#mock.errors, 0, errstr())
            assertEquals(ns.db.migratedFrom, "account-cleared"); assertDefaultsPresetsBindings(ns, class); assertEquals(msgCount(), 1)
            assertEquals(ns.db.frames.layout, "vertical")
        end)
    end
    it("the owner's real profile as a Druid is cleaned; layout, point and minimap are kept", function()
        local char = Fx.userChar()
        local ns = boot({ class = "DRUID", char = char })
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(ns.db.migratedFrom, "account-cleared"); assertDefaultsPresetsBindings(ns, "owner as druid"); assertEquals(msgCount(), 1)
        assertEquals(ns.db.frames.layout, char.frames.layout); assertDeepEquals(ns.db.frames.point, char.frames.point)
        assertEquals(ns.db.minimap.angle, char.minimap.angle); assertEquals(ns.db.frames.width, char.frames.width)
    end)
end)

describe("new char: seeded characters whose class matches are never touched", function()
    local function sameAsWithoutCleanup(char, class, label)
        -- reference: the same profile loaded with the class unreadable during load (the cleanup can't run)
        boot({ class = class, char = char, duringLoad = function(S2) S2.classError = { player = true }; return function() S2.classError = nil end end })
        assertEquals(msgCount(), 0, label)
        local ref = logoutSave()
        local ns = boot({ class = class, char = char })
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(msgCount(), 0, label .. ": no message")
        assertEquals(ns.db.migratedFrom, char.migratedFrom, label)
        local save = logoutSave()
        assertDeepEquals(save, ref, label .. ": BuildSaveTable must be identical")
        return ns, save
    end
    it("the owner's Paladin (owner-char-v3 fixture): identical save, bindings and presets kept", function()
        local char = Fx.userChar()
        local ns = sameAsWithoutCleanup(char, "PALADIN", "owner-char-v3")
        assertEquals(char.migratedFrom, "account", "the fixture really is a seeded profile")
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light"); assertEquals(ns.db.bindings["ctrl|1"].spell, "Purify")
        assertEquals(#ns.db.presets, #char.presets)
    end)
    it("the owner's Paladin (pre-buffgroups fixture): identical save", function()
        local char = Fx.loadSaved(HF_TESTS .. "/fixtures/owner-char-pre-buffgroups.lua", "HealerForeverCharDB")
        assertEquals(char.migratedFrom, "account")
        local ns = sameAsWithoutCleanup(char, "PALADIN", "owner-char-pre-buffgroups")
        assertEquals(#ns.db.presets, #char.presets)
    end)
    it("a synthetic seeded Paladin profile: identical save", function()
        sameAsWithoutCleanup(seededChar(), "PALADIN", "seeded paladin")
    end)
    it("a Druid seeded with only Druid buffs keeps everything", function()
        local char = seededChar({ presets = { { name = "Druid", map = fullMap({ WARRIOR = { DEFAULT = { "motw" }, TANK = { "motw", "thorns" } },
            MAGE = { DEFAULT = "motw" }, PRIEST = { DEFAULT = "none" } }), self = { "thorns" }, extras = {} } }, activePreset = 1,
            bindings = { ["|1"] = { type = "spell", spell = "Rejuvenation" } } })
        local ns = sameAsWithoutCleanup(char, "DRUID", "druid own buffs")
        assertEquals(ns.db.migratedFrom, "account"); assertEquals(ns.db.bindings["|1"].spell, "Rejuvenation")
        assertDeepEquals(ns.db.presets[1].self, { "thorns" })
    end)
    it("the party golden scenario with a seeded marker still matches party-golden-0.10.1 and prints nothing", function()
        local golden = PS.loadGolden()
        local sc = PS.scenario("party4_v0.10.1_save")
        if not golden or not golden[sc.name] then return skip("golden", "no golden for " .. sc.name) end
        local realLoad = Fx.loadSaved
        Fx.loadSaved = function(path, var)
            local t = realLoad(path, var)
            if var == "HealerForeverCharDB" then t.migratedFrom = "account" end
            return t
        end
        local ok, ns = pcall(PS.boot, sc)
        Fx.loadSaved = realLoad
        assertTrue(ok, tostring(ns))
        assertEquals(ns.db.migratedFrom, "account"); assertEquals(msgCount(), 0, printed())
        assertEquals(#mock.errors, 0, errstr())
        local d = PS.diff(golden[sc.name], PS.snapshotParty(ns))
        assertNil(d, d)
    end)
end)

describe("new char: an unreadable class changes nothing", function()
    local cases = {
        { "secret class", function(S2) S2.secretClass = { player = true }; return function() S2.secretClass = nil end end },
        { "UnitClass raises", function(S2) S2.classError = { player = true }; return function() S2.classError = nil end end },
        { "UnitClass returns nil", function()
            local real = _G.UnitClass
            _G.UnitClass = function(u, ...) if u == "player" then return nil end return real(u, ...) end
            return function() _G.UnitClass = real end end },
        { "UnitClass missing", function()
            local real = _G.UnitClass; _G.UnitClass = nil
            return function() _G.UnitClass = real end end },
        { "unknown class", function(S2) S2.units.player.class = "DEATHKNIGHT"; return function() S2.units.player.class = "DRUID" end end },
    }
    for _, c in ipairs(cases) do
        it(c[1] .. " at load: the seeded profile is kept as it is, no message, no error", function()
            local ns = boot({ class = "DRUID", char = seededChar(), duringLoad = c[2] })
            assertEquals(#mock.errors, 0, errstr())
            assertEquals(msgCount(), 0, printed())
            assertEquals(ns.db.migratedFrom, "account", "the cleanup can still run on a later load")
            assertEquals(ns.db.bindings["|1"].spell, "Holy Light"); assertEquals(#ns.db.presets, 2)
        end)
    end
    it("a later load with a readable class then cleans it once", function()
        boot({ class = "DRUID", char = seededChar(), duringLoad = cases[1][2] })
        local save = logoutSave()
        local ns = boot({ class = "DRUID", char = save })
        assertEquals(msgCount(), 1); assertEquals(ns.db.migratedFrom, "account-cleared")
    end)
    it("the class secret for the whole session (not only at load) does not break the boot", function()
        local ns = boot({ class = "DRUID", char = seededChar(), duringLoad = function(S2) S2.secretClass = { player = true } end })
        assertEquals(msgCount(), 0)
        assertEquals(ns.db.migratedFrom, "account")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== /hf copyaccount
describe("new char: /hf copyaccount", function()
    it("as a Druid with the Paladin's account settings: everything except presets and click-casting", function()
        local account = Fx.userAccount(); local snap = deepcopy(account)
        local ns = boot({ class = "DRUID", account = account })
        local ask = slash("copyaccount")
        assertNotNil(ask:find("confirm", 1, true), ask); assertNil(ns.db.migratedFrom, "nothing before confirm")
        local out = slash("copyaccount confirm")
        assertNotNil(out:find("except buff presets and click-casting", 1, true), out)
        assertEquals(#mock.errors, 0, errstr())
        assertDefaultsPresetsBindings(ns, "copy as druid")
        assertEquals(ns.db.migratedFrom, "account")
        assertEquals(ns.db.frames.layout, account.frames.layout); assertEquals(ns.db.minimap.angle, account.minimap.angle)
        assertEquals(ns.db.frames.point.x, account.frames.point.x); assertEquals(ns.db.frames.point.y, account.frames.point.y)
        assertDeepEquals(_G.HealerForeverDB, snap, "the account DB is never modified")
        assertTrue(ns.db == _G.HealerForeverCharDB)
        -- the copy is clean, so the next load prints nothing and keeps the marker
        local save = logoutSave()
        local ns2 = boot({ class = "DRUID", account = account, char = save })
        assertEquals(msgCount(), 0); assertEquals(ns2.db.migratedFrom, "account"); assertDefaultsPresetsBindings(ns2, "reload")
        assertEquals(ns2.db.frames.layout, account.frames.layout)
    end)
    it("as a Druid replaces the Druid's own presets and bindings with the defaults (the copy replaces the profile)", function()
        local ns = boot({ class = "DRUID", account = Fx.userAccount(), char = { version = 4, bindings = { ["|1"] = { type = "spell", spell = "Rejuvenation" } } } })
        slash("copyaccount confirm")
        assertDefaultsPresetsBindings(ns, "replaced")
    end)
    it("as a Druid with an account DB holding only Druid buffs: copied whole", function()
        local account = { version = 4, presets = { { name = "Wild", map = fullMap({ WARRIOR = { DEFAULT = { "motw" } } }), extras = {} } },
            bindings = { ["|1"] = { type = "spell", spell = "Rejuvenation" } }, frames = { layout = "vertical" } }
        local ns = boot({ class = "DRUID", account = account })
        local out = slash("copyaccount confirm")
        assertNil(out:find("except", 1, true), out); assertNotNil(out:find("Copied account-wide settings", 1, true), out)
        assertEquals(ns.db.presets[1].name, "Wild"); assertEquals(ns.db.bindings["|1"].spell, "Rejuvenation")
    end)
    it("as a Paladin: everything is copied (presets and bindings too)", function()
        local account = Fx.userAccount(); local snap = deepcopy(account)
        local ns = boot({ class = "PALADIN", account = account })
        local out = slash("copyaccount confirm")
        assertNil(out:find("except", 1, true), out)
        assertEquals(ns.db.migratedFrom, "account"); assertEquals(ns.db.bindings["|1"].spell, "Holy Light")
        assertEquals(#ns.db.presets, #account.presets); assertEquals(ns.db.activePreset, account.activePreset)
        assertDeepEquals(_G.HealerForeverDB, snap)
        local ok, skipped = ns:ImportAccount()
        assertTrue(ok); assertFalse(skipped)
    end)
    it("with no account DB: says so and changes nothing", function()
        for _, acct in ipairs({ false, {}, "garbage" }) do
            local ns = boot({ class = "DRUID", account = acct or nil, char = { version = 4, frames = { layout = "vertical" } } })
            local before = deepcopy(ns.db)
            local out = slash("copyaccount confirm")
            assertNotNil(out:find("No account-wide settings found", 1, true), out)
            assertDeepEquals(ns.db, before)
            assertEquals(ns:ImportAccount(), false)
        end
    end)
    it("with the class unreadable it copies everything; a later load with a readable class then cleans it once", function()
        local ns = boot({ class = "DRUID", account = Fx.userAccount() })
        S.secretClass = { player = true }
        local out = slash("copyaccount confirm")
        S.secretClass = nil
        assertNil(out:find("except", 1, true), out); assertEquals(ns.db.bindings["|1"].spell, "Holy Light")
        local save = logoutSave()
        local ns2 = boot({ class = "DRUID", char = save })
        assertEquals(msgCount(), 1); assertEquals(ns2.db.migratedFrom, "account-cleared"); assertDefaultsPresetsBindings(ns2, "later")
    end)
    it("in combat the copy waits for combat to end and makes no protected call", function()
        local ns = boot({ class = "DRUID", account = Fx.userAccount() })
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        slash("copyaccount confirm")
        assertNil(ns.db.migratedFrom, "queued in combat")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(ns.db.migratedFrom, "account"); assertDefaultsPresetsBindings(ns, "after combat")
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
    end)
end)
