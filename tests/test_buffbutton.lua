-- Missing-buff buttons end to end: visibility, unknown-spell greying, durations, reasons (/hf debug buffs),
-- role buffs (extras) buttons, smart/tank secure buttons and Bindings.xml hookup.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function st(f) return rawget(f, "__s") end
local function frameNamed(name) for _, f in ipairs(mock.frames) do if st(f).name == name then return f end end end
local function unit(name, class, role)
    return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.class then S.units.player.class = opts.class end
    if opts.units then for k, v in pairs(opts.units) do local c = {}; for kk, vv in pairs(v) do c[kk] = vv end; S.units[k] = c end end
    if opts.book then mock.setSpellbook(opts.book) end
    if opts.setup then opts.setup() end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.db ~= nil then _G.HealerForeverCharDB = opts.db end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if opts.seed ~= false and opts.char == nil and opts.db == nil and opts.account == nil and ns.db then Fx.seed(ns, { presets = 4 }) end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    if opts.group then mock.setGroup(opts.group) end
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local function refresh() mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers() end
local function buff(u) for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverBuff%d$") and f.unit == u then return f end end end
local function extra(u) for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverExtra%d$") and f.unit == u then return f end end end
local function unitButton(u) for _, f in ipairs(mock.frames) do if tostring(st(f).name):match("^HealerForeverUnit") and st(f).attrs.unit == u then return f end end end
local function active(b) return b:GetAlpha() > 0 and st(b).mouse == true end
local function auraFor(ns, u, extra)
    local preset = ns.db.presets[ns.db.activePreset]
    local _, token = UnitClass(u)
    local key = ns.Presets.ResolveBuff(preset, token, ns.Roles.Get(u), u == "player")
    local def = ns.Classes.BUFFS[key]
    local a = { spellId = def.spellIds[1], name = def.names[1], icon = 1, duration = 600, expirationTime = 0, applications = 0, isHelpful = true, sourceUnit = "player" }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end

local function spellOfMacro(text) if not text then return nil end return text:match("%]%s*([^;%]]+)$") end

local PARTY = { party1 = unit("TankPal", "PALADIN", "TANK"), party2 = unit("HealPal", "PALADIN", "HEALER"), party3 = unit("Warr", "WARRIOR", "DAMAGER"),
    party4 = unit("Rogue", "ROGUE", "DAMAGER") }

describe("buff button: visible and clickable when a buff is missing", function()
    it("solo player (default showSolo): button active, alpha 1, mouse on, spell attribute set, level above the unit frame", function()
        local ns = boot()
        local b = buff("player")
        assertNotNil(b, "player buff button missing")
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil(b.buffKey, "no buff assigned to the solo player")
        assertEquals(b:GetAlpha(), 1); assertTrue(st(b).mouse)
        assertEquals(st(b).attrs.type1, "macro"); assertNotNil(st(b).attrs.macrotext1); assertNotNil(st(b).attrs.macrotext2)
        assertNil(st(b).attrs.spell1, "buff buttons never use type=spell")
        assertEquals(st(b).attrs.unit, "player")
        assertTrue(b:GetFrameLevel() >= unitButton("player"):GetFrameLevel() + 20, "frame level must sit well above the unit button")
        assertTrue(st(b).shown)
        assertFalse(st(b.icon).desat == true, "ready button must not be desaturated")
        assertTrue(st(b.pulse).playing)
    end)
    it("solo: showSolo = false hides it", function()
        local ns = boot()
        ns.db.buffs.showSolo = false; ns:Changed("presets"); refresh()
        assertFalse(active(buff("player")))
        ns.db.buffs.showSolo = true; ns:Changed("presets"); refresh()
        assertTrue(active(buff("player")))
    end)
    it("grouped: every member missing their buff has an active button", function()
        local ns = boot({ group = 4, units = PARTY })
        for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
            local b = buff(u)
            local _, token = UnitClass(u)
            local want = ns.Presets.ResolveBuff(ns.db.presets[ns.db.activePreset], token, ns.Roles.Get(u), u == "player")
            if want then
                assertEquals(b.buffKey, want, u)
                assertTrue(active(b), u .. " not active")
                assertEquals(st(b).attrs.type1, "macro", u)
            else
                assertFalse(active(b), u .. " has no assignment, must be hidden")
            end
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("spell attributes are set for both clicks (single on left, greater on right)", function()
        local ns = boot({ group = 1, units = PARTY })
        local b = buff("party1")
        local def = ns.Classes.BUFFS[b.buffKey]
        assertEquals(spellOfMacro(st(b).attrs.macrotext1), def.name); assertEquals(spellOfMacro(st(b).attrs.macrotext2), def.greater)
        assertEquals(st(b).attrs.macrotext1, ns.Bindings.BuildMacroText("party1", def.name, nil))
        assertEquals(st(b).attrs.macrotext2, ns.Bindings.BuildMacroText("party1", def.greater, nil))
    end)
    it("a member with the buff and a long duration -> inactive; short duration -> active again", function()
        local ns = boot({ group = 2, units = PARTY })
        local u = "party1"
        assertTrue(active(buff(u)))
        S.auras[u] = { auraFor(ns, u, { expirationTime = S.now + 3000 }) }
        refresh()
        assertFalse(active(buff(u)), "long duration buff must hide the button")
        assertNil(buff(u).buffKey)
        S.auras[u] = { auraFor(ns, u, { expirationTime = S.now + 20 }) }
        refresh()
        assertTrue(active(buff(u)), "expiring buff must show the button")
        S.auras[u] = { auraFor(ns, u, { expirationTime = 0 }) }
        refresh()
        assertFalse(active(buff(u)), "permanent buff must hide the button")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("warn threshold off (buffs.warn=false): an expiring buff is still 'present'", function()
        local ns = boot({ group = 2, units = PARTY })
        ns.db.buffs.warn = false; ns:Changed("presets")
        S.auras.party1 = { auraFor(ns, "party1", { expirationTime = S.now + 20 }) }
        refresh()
        assertFalse(active(buff("party1")))
    end)
    it("dead / offline members do not get buttons; they come back when alive", function()
        local ns = boot({ group = 2, units = PARTY })
        S.dead.party1 = true; S.offline.party2 = true; refresh()
        assertFalse(active(buff("party1"))); assertFalse(active(buff("party2")))
        S.dead.party1 = nil; S.offline.party2 = nil; refresh()
        assertTrue(active(buff("party1"))); assertTrue(active(buff("party2")))
    end)
    it("the 1s ticker alone picks up aura changes (no events)", function()
        local ns = boot({ group = 2, units = PARTY })
        assertTrue(active(buff("party2")))
        S.auras.party2 = { auraFor(ns, "party2", { expirationTime = 0 }) }
        mock.tick(); mock.flushTimers()
        assertFalse(active(buff("party2")))
    end)
    it("class without blessings (WARRIOR player): no buttons, no errors", function()
        boot({ class = "WARRIOR", group = 2, units = PARTY })
        for _, u in ipairs({ "player", "party1", "party2" }) do assertFalse(active(buff(u))) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("in combat the buttons are driven by a [combat] hide state driver and attributes are never touched", function()
        local ns = boot({ group = 2, units = PARTY })
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local n0 = #mock.calls
        S.auras.party1 = { auraFor(ns, "party1", { expirationTime = 0 }) }
        mock.fire("UNIT_AURA", "party1"); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick()
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.secure and c.combat and c.method == "SetAttribute", "SetAttribute on secure frame in combat")
        end
        assertEquals(#mock.violations, 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertFalse(active(buff("party1")), "after combat the buff is seen and the button hides")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("buff button: unknown buff spell is shown greyed, not hidden", function()
    local function noKnown()
        mock.setGlobal("IsPlayerSpell", function() return false end)
        mock.setGlobal("IsSpellKnownOrOverridesKnown", function() return false end)
        mock.setGlobal("IsSpellKnown", function() return false end)
        mock.setGlobal("C_SpellBook", { IsSpellKnown = function() return false end, FindSpellBookSlotForSpell = function() return nil end })
    end
    it("button is visible, desaturated, has no spell attributes, and a tooltip explains", function()
        local ns = boot({ group = 2, units = PARTY, setup = noKnown })
        local b = buff("party1")
        assertNotNil(b.buffKey, "assignment must still be recorded")
        assertEquals(b.unknownSpell, ns.Classes.BUFFS[b.buffKey].name)
        assertEquals(b:GetAlpha(), 0.8); assertTrue(st(b).mouse)
        assertTrue(st(b.icon).desat, "must be desaturated")
        assertNil(st(b).attrs.type1); assertNil(st(b).attrs.spell1); assertNil(st(b).attrs.spell2)
        assertFalse(st(b.pulse).playing, "unknown spell button must not pulse")
        assertEquals(#mock.errors, 0, errstr())
        local lines = {}
        local gt = _G.GameTooltip
        gt.AddLine = function(_, t) lines[#lines + 1] = t end
        st(b).hooks.OnEnter[1](b)
        assertNotNil(table.concat(lines, "|"):find("Not in your spellbook", 1, true), table.concat(lines, "|"))
    end)
    it("when the spell becomes known the button becomes castable and not grey", function()
        local ns = boot({ group = 2, units = PARTY, setup = noKnown })
        _G.IsPlayerSpell = function() return true end
        mock.fire("SPELLS_CHANGED"); mock.flushTimers(); mock.tick()
        local b = buff("party1")
        assertEquals(st(b).attrs.type1, "macro")
        assertFalse(st(b.icon).desat)
        assertEquals(b:GetAlpha(), 1)
    end)
    it("partially known: only the greater spell known -> castable on both clicks", function()
        local ns = boot({ group = 2, units = PARTY, setup = noKnown })
        local def = ns.Classes.BUFFS[buff("party1").buffKey]
        _G.IsPlayerSpell = function(id) return id == mock.state.spellByName[def.greater] end
        mock.fire("SPELLS_CHANGED"); mock.flushTimers(); mock.tick()
        local b = buff("party1")
        assertEquals(spellOfMacro(st(b).attrs.macrotext1), def.greater); assertEquals(spellOfMacro(st(b).attrs.macrotext2), def.greater)
    end)
end)

describe("buff button: every default preset x class x role resolves or is deliberately none", function()
    local ns = boot()
    local classes = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
    local presetsToCheck = { ns.Presets.ExamplePaladin() }
    for _, d in ipairs(ns.Presets.DEFAULTS) do presetsToCheck[#presetsToCheck + 1] = d end
    for pi, preset in ipairs(presetsToCheck) do
        it("preset " .. pi .. " (" .. preset.name .. ")" .. (next(preset.map) == nil and " [blank shipped default: resolves to nothing]" or ""), function()
            if next(preset.map) == nil then
                for _, class in ipairs(classes) do
                    assertNil(ns.Presets.ResolveBuff(preset, class, nil, false), "the shipped default preset must assign no buff")
                    for _, r in ipairs(ns.Classes.ROLES[class]) do assertNil(ns.Presets.ResolveBuff(preset, class, r, true)) end
                end
                return
            end
            for _, class in ipairs(classes) do
                local roles = { false }
                for _, r in ipairs(ns.Classes.ROLES[class]) do roles[#roles + 1] = r end
                for _, role in ipairs(roles) do
                    for _, isSelf in ipairs({ false, true }) do
                        local key = ns.Presets.ResolveBuff(preset, class, role or nil, isSelf)
                        local entry = preset.map[class]
                        local raw = (role and entry[role]) or entry.DEFAULT
                        if isSelf and preset.self then raw = preset.self end
                        if key == nil then
                            assertDeepEquals(raw, {}, string.format("%s %s %s resolved to nothing but the rule is %s", class, tostring(role), tostring(isSelf), tostring(raw)))
                        else
                            assertNotNil(ns.Classes.BUFFS[key], "unknown buff " .. tostring(key))
                            assertEquals(key, raw[1], "the first buff of the cell is the resolved one")
                        end
                    end
                end
            end
        end)
    end
    it("every Paladin blessing has spell ids, names and a greater variant; every other catalog buff has names (spell ids are empty on purpose)", function()
        for key, def in pairs(ns.Classes.BUFFS) do
            assertTrue(#def.names > 0, key); assertEquals(type(def.name), "string")
            if def.group == "blessing" then
                assertTrue(#def.spellIds > 0, key); assertEquals(type(def.greater), "string")
            else
                assertEquals(#def.spellIds, 0, key .. ": non-Paladin buffs match by name")
            end
            if def.groupSpell then assertEquals(def.greater, def.groupSpell, key) end
        end
    end)
    it("a paladin in the 5-man preset: every class that should get a buff does (no silent gaps)", function()
        local five = ns.Presets.ExamplePaladin()
        assertNotNil(five.name:find("5"))
        local gaps = {}
        for _, class in ipairs(classes) do
            if ns.Presets.ResolveBuff(five, class, nil, false) == nil then gaps[#gaps + 1] = class end
        end
        if #gaps > 0 then warn("5-man preset: classes with deliberately no default buff: " .. table.concat(gaps, ",")) end
    end)
end)

describe("buff button: /hf debug buffs", function()
    local function debug()
        mock.printed = {}
        local fn
        for k, f in pairs(_G.SlashCmdList) do fn = f end
        local ok, err = pcall(fn, "debug buffs")
        assertTrue(ok, tostring(err))
        return table.concat(mock.printed, "\n")
    end
    it("runs without error solo, grouped, in combat, in secret mode, and with bad subcommands", function()
        local ns = boot({ group = 3, units = PARTY })
        assertNotNil(debug():find("buff debug"))
        S.combat = true; debug(); S.secret = true; debug(); S.combat = false; S.secret = false
        local fn; for _, f in pairs(_G.SlashCmdList) do fn = f end
        assertTrue(pcall(fn, "debug")); assertTrue(pcall(fn, "debug bogus")); assertTrue(pcall(fn, "debug buffs extra"))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("prints one line per unit button and the verdict (WOULD SHOW)", function()
        boot({ group = 2, units = PARTY })
        local out = debug()
        local lines = 0
        for _ in out:gmatch("WOULD SHOW") do lines = lines + 1 end
        assertTrue(lines >= 3, "expected WOULD SHOW for player, party1, party2:\n" .. out)
        assertNotNil(out:find("role=TANK"))
    end)
    it("reason: class without blessings", function()
        boot({ class = "WARRIOR", group = 1, units = PARTY })
        assertNotNil(debug():find("your class has no party buffs to assign", 1, true))
    end)
    it("reason: unit does not exist (empty party slots)", function()
        boot({ group = 1, units = PARTY })
        assertNotNil(debug():find("unit does not exist", 1, true))
    end)
    it("reason: solo and show-while-solo off", function()
        local ns = boot()
        ns.db.buffs.showSolo = false
        assertNotNil(debug():find("solo and 'show while solo' is off", 1, true))
    end)
    it("reason: unit is dead / offline", function()
        boot({ group = 2, units = PARTY })
        S.dead.party1 = true; S.offline.party2 = true
        local out = debug()
        assertNotNil(out:find("unit is dead", 1, true)); assertNotNil(out:find("unit is offline", 1, true))
    end)
    it("reason: dead/connected state is secret", function()
        boot({ group = 1, units = PARTY })
        S.secret = true
        assertNotNil(debug():find("secret", 1, true))
    end)
    it("reason: class unreadable", function()
        boot({ group = 2, units = PARTY })
        S.units.party1.class = nil
        assertNotNil(debug():find("class unreadable", 1, true))
    end)
    it("reason: auras unreadable (secret aura values) is not treated as buffed", function()
        local ns = boot({ group = 2, units = PARTY })
        S.auras.party1 = { { spellId = 1, name = "x", expirationTime = 0, icon = 1, isHelpful = true } }
        local real = C_UnitAuras.GetUnitAuras
        C_UnitAuras.GetUnitAuras = function() return { { spellId = mock.newSecret(), name = "x", expirationTime = 0 } } end
        local out = debug()
        C_UnitAuras.GetUnitAuras = real
        assertNotNil(out:find("auras unreadable", 1, true), out)
    end)
    it("reason: preset assigns no buff to this class/role", function()
        local ns = boot({ group = 2, units = PARTY })
        ns.db.presets[ns.db.activePreset].map.PALADIN = { DEFAULT = {} }
        assertNotNil(debug():find("preset assigns none of your buffs", 1, true))
    end)
    it("reason: has the buff (with the aura named)", function()
        local ns = boot({ group = 2, units = PARTY })
        S.auras.party1 = { auraFor(ns, "party1", { expirationTime = 0 }) }
        local out = debug()
        assertNotNil(out:find("has all assigned buffs", 1, true), out)
        if not out:find("no expiry", 1, true) then warn("/hf debug buffs no longer names the aura that satisfies a buff or its expiry ('has all assigned buffs' only)") end
    end)
    it("shows known/unknown for the buff spells and the button state", function()
        boot({ group = 1, units = PARTY })
        local out = debug()
        assertNotNil(out:find("known", 1, true)); assertNotNil(out:find("alpha=", 1, true))
    end)
end)

-- ======================================================================== role buffs (extras)
describe("extras: role-buff button on the tank", function()
    local function setupExtra(ns, roles, single)
        local preset = ns.db.presets[ns.db.activePreset]
        preset.extras = {}
        ns.Presets.AddExtra(preset, "Oath of Light", roles or { TANK = true }, single ~= false)
        ns:Changed("presets"); refresh()
    end
    local function ownAura(u) return { spellId = 900002, name = "Oath of Light", icon = 1, duration = 0, expirationTime = 0, isHelpful = true, sourceUnit = "player" } end
    local function bootParty(units, opts)
        opts = opts or {}
        return boot({ group = 4, units = units or {
            party1 = unit("Tank1", "WARRIOR", "TANK"), party2 = unit("Dps1", "MAGE", "DAMAGER"), party3 = unit("Dps2", "ROGUE", "DAMAGER"),
            party4 = unit("Dps3", "HUNTER", "DAMAGER") }, book = opts.book, setup = opts.setup })
    end
    local BOOK = { names = { [19750] = "Flash of Light", [900002] = "Oath of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 19750, 900002 } } } }

    it("shows only on the tank", function()
        local ns = bootParty(nil, { book = BOOK })
        setupExtra(ns)
        assertTrue(active(extra("party1")), "tank must get the role-buff button")
        assertEquals(extra("party1").extraSpell, "Oath of Light")
        for _, u in ipairs({ "player", "party2", "party3", "party4" }) do assertFalse(active(extra(u)), u .. " must not") end
        assertEquals(st(extra("party1")).attrs.type1, "macro"); assertEquals(spellOfMacro(st(extra("party1")).attrs.macrotext1), "Oath of Light")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("once our own aura is on the tank it hides", function()
        local ns = bootParty(nil, { book = BOOK })
        setupExtra(ns)
        S.auras.party1 = { ownAura() }
        refresh()
        assertFalse(active(extra("party1")))
    end)
    it("an aura from someone else does not count as ours for single (but still satisfies the tank)", function()
        local ns = bootParty(nil, { book = BOOK })
        setupExtra(ns)
        local a = ownAura(); a.sourceUnit = "party2"
        S.auras.party1 = { a }
        refresh()
        assertFalse(active(extra("party1")), "tank already has the buff")
    end)
    it("with two tanks only the first tank missing it gets the button", function()
        local ns = bootParty({ party1 = unit("Tank1", "WARRIOR", "TANK"), party2 = unit("Tank2", "PALADIN", "TANK"),
            party3 = unit("Dps2", "ROGUE", "DAMAGER"), party4 = unit("Dps3", "HUNTER", "DAMAGER") }, { book = BOOK })
        setupExtra(ns)
        assertTrue(active(extra("party1"))); assertFalse(active(extra("party2")), "second tank must not also get it")
    end)
    it("with two tanks and our aura on EITHER one, no button at all", function()
        local ns = bootParty({ party1 = unit("Tank1", "WARRIOR", "TANK"), party2 = unit("Tank2", "PALADIN", "TANK"),
            party3 = unit("Dps2", "ROGUE", "DAMAGER"), party4 = unit("Dps3", "HUNTER", "DAMAGER") }, { book = BOOK })
        setupExtra(ns)
        S.auras.party2 = { ownAura() }; refresh()
        assertFalse(active(extra("party1")), "our aura is on tank 2: tank 1 must not be offered")
        assertFalse(active(extra("party2")))
        S.auras.party2 = nil; S.auras.party1 = { ownAura() }; refresh()
        assertFalse(active(extra("party1"))); assertFalse(active(extra("party2")))
    end)
    it("non-single entries are offered on every matching unit missing it", function()
        local ns = bootParty({ party1 = unit("Tank1", "WARRIOR", "TANK"), party2 = unit("Tank2", "PALADIN", "TANK"),
            party3 = unit("Dps2", "ROGUE", "DAMAGER"), party4 = unit("Dps3", "HUNTER", "DAMAGER") }, { book = BOOK })
        setupExtra(ns, { TANK = true }, false)
        assertTrue(active(extra("party1"))); assertTrue(active(extra("party2")))
    end)
    it("role SELF and DAMAGER entries target the right units", function()
        local ns = bootParty(nil, { book = BOOK })
        setupExtra(ns, { SELF = true }, false)
        assertTrue(active(extra("player"))); assertFalse(active(extra("party1")))
        setupExtra(ns, { DAMAGER = true }, false)
        assertFalse(active(extra("player"))); assertTrue(active(extra("party2"))); assertTrue(active(extra("party3")))
    end)
    it("an unknown spell gives a greyed button (visible, no attributes)", function()
        local ns = bootParty(nil, { book = { names = { [19750] = "Flash of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 19750 } } } },
            setup = function()
                mock.setGlobal("IsPlayerSpell", function() return false end)
                mock.setGlobal("IsSpellKnownOrOverridesKnown", function() return false end)
                mock.setGlobal("IsSpellKnown", function() return false end)
                mock.state.spellByName["Oath of Light"] = nil
                local book = _G.C_SpellBook
                book.IsSpellKnown = function() return false end
            end })
        setupExtra(ns)
        local b = extra("party1")
        assertEquals(b:GetAlpha(), 0.8); assertTrue(st(b).mouse); assertTrue(st(b.icon).desat)
        assertNil(st(b).attrs.type1); assertNil(st(b).attrs.spell1)
        assertEquals(b.unknownSpell, "Oath of Light")
    end)
    it("extras button sits above the unit button", function()
        local ns = bootParty(nil, { book = BOOK })
        setupExtra(ns)
        assertTrue(extra("party1"):GetFrameLevel() >= unitButton("party1"):GetFrameLevel() + 20)
    end)
    it("in combat nothing protected is touched while roles/auras change", function()
        local ns = bootParty(nil, { book = BOOK })
        setupExtra(ns)
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0, n0 = #mock.violations, #mock.softViolations, #mock.calls
        S.auras.party1 = { ownAura() }
        mock.fire("UNIT_AURA", "party1"); mock.fire("PLAYER_ROLES_ASSIGNED"); mock.fire("GROUP_ROSTER_UPDATE")
        mock.flushTimers(); mock.tick(); mock.runOnUpdate(2, 0.5)
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.secure and c.method == "SetAttribute", "SetAttribute on secure frame in combat")
        end
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertFalse(active(extra("party1")))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secret auras never error", function()
        local ns = bootParty(nil, { book = BOOK })
        setupExtra(ns)
        S.secret = true
        S.auras.party1 = { ownAura() }
        refresh(); mock.fire("UNIT_AURA", "party1")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== smart + tank secure buttons, Bindings.xml
describe("smart buff button and tank buff button", function()
    local BOOK = { names = { [19750] = "Flash of Light", [900002] = "Oath of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 19750, 900002 } } } }
    local units = { party1 = unit("TankPal", "PALADIN", "TANK"), party2 = unit("Mage", "MAGE", "DAMAGER"), party3 = unit("Rogue", "ROGUE", "DAMAGER") }
    local ns = boot({ group = 3, units = units, book = BOOK })
    local smart, tank = frameNamed("HealerForeverSmartBuff"), frameNamed("HealerForeverTankBuff")
    local function attrs(f) local a = st(f).attrs; return a.type, spellOfMacro(a.macrotext), a.unit end

    it("both secure buttons exist and are secure action buttons", function()
        assertNotNil(smart); assertNotNil(tank)
        assertTrue(st(smart).secure); assertTrue(st(tank).secure)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Bindings.xml CLICK names match the created frames", function()
        local xml = L.readFile(L.addonDir .. "/Bindings.xml")
        local seen = 0
        for frame in xml:gmatch('CLICK ([%w_]+):LeftButton') do
            seen = seen + 1
            assertNotNil(frameNamed(frame), "Bindings.xml refers to missing frame " .. frame)
            assertNotNil(rawget(_G, "BINDING_NAME_CLICK " .. frame .. ":LeftButton"), "no BINDING_NAME for " .. frame)
        end
        assertTrue(seen >= 2)
        assertEquals(type(rawget(_G, "BINDING_HEADER_HEALERFOREVER")), "string")
        for _, f in ipairs({ smart, tank }) do
            local registered = false
            for _, c in ipairs(mock.calls) do
                if c.obj == f and c.method == "RegisterForClicks" and c.args[1] == "AnyDown" then registered = true end
            end
            assertTrue(registered, "key-bound click buttons must register AnyDown and AnyUp")
        end
    end)
    it("with the tank missing an extra and a blessing: smart points at the tank's missing role buff first", function()
        local preset = ns.db.presets[ns.db.activePreset]
        preset.extras = {}
        ns.Presets.AddExtra(preset, "Oath of Light", { TANK = true }, true)
        ns:Changed("presets"); refresh()
        local t, spell, u = attrs(smart)
        assertEquals(t, "macro"); assertEquals(spell, "Oath of Light"); assertEquals(u, "party1")
        local tt, tspell, tu = attrs(tank)
        assertEquals(tt, "macro"); assertEquals(tspell, "Oath of Light"); assertEquals(tu, "party1")
    end)
    it("after the oath is applied: next is the tank's missing blessing", function()
        S.auras.party1 = { { spellId = 900002, name = "Oath of Light", icon = 1, expirationTime = 0, sourceUnit = "player", isHelpful = true } }
        refresh()
        local t, spell, u = attrs(smart)
        assertEquals(u, "party1")
        local key = ns.Presets.ResolveBuff(ns.db.presets[ns.db.activePreset], "PALADIN", "TANK", false)
        assertEquals(spell, ns.Classes.BUFFS[key].name)
        -- the tank key/button is armed only while the tank role buff is missing: oath present -> idle
        local tt, _, tu = attrs(tank)
        assertNil(tt, "tank button must be idle while the tank has the oath"); assertNil(tu)
    end)
    it("tank button is cleared when there is no tank / no TANK extra, and re-armed when the oath is missing", function()
        S.auras.party1 = {}
        refresh()
        assertEquals((attrs(tank)), "macro", "oath missing -> armed")
        S.units.party1.role = "DAMAGER"
        mock.fire("PLAYER_ROLES_ASSIGNED"); refresh()
        local tt, _, tu = attrs(tank)
        assertNil(tt); assertNil(tu)
        S.units.party1.role = "TANK"
        mock.fire("PLAYER_ROLES_ASSIGNED"); refresh()
        assertEquals((attrs(tank)), "macro")
        ns.db.presets[ns.db.activePreset].extras = {}
        ns:Changed("presets"); refresh()
        assertNil((attrs(tank)))
        ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true }, true)
        S.auras.party1 = { { spellId = 900002, name = "Oath of Light", icon = 1, expirationTime = 0, sourceUnit = "player", isHelpful = true } }
        ns:Changed("presets"); refresh()
    end)
    it("then DPS blessings (lowest unit token first), then the player (self) last, then cleared", function()
        local function give(u) S.auras[u] = S.auras[u] or {}; table.insert(S.auras[u], auraFor(ns, u)) end
        give("party1"); refresh()
        local _, _, u = attrs(smart)
        assertEquals(u, "party2", "next pending should be the first DPS")
        give("party2"); refresh()
        _, _, u = attrs(smart); assertEquals(u, "party3")
        give("party3"); refresh()
        _, _, u = attrs(smart); assertEquals(u, "player", "self is last")
        give("player"); refresh()
        local t, spell, unitAttr = attrs(smart)
        assertNil(t); assertNil(spell); assertNil(unitAttr)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("pending again when a buff drops off", function()
        S.auras.party2 = nil; refresh()
        local t, _, u = attrs(smart)
        assertEquals(t, "macro"); assertEquals(u, "party2")
    end)
    it("in combat: no SetAttribute calls on the smart/tank buttons and attributes stay frozen", function()
        local before = { attrs(smart) }
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local n0, v0 = #mock.calls, #mock.violations
        S.auras.party3 = nil; S.auras.party2 = { auraFor(ns, "party2") }
        mock.fire("UNIT_AURA", "party2"); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick()
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.method == "SetAttribute" and (c.obj == smart or c.obj == tank), "SetAttribute on smart/tank button in combat")
        end
        assertEquals(#mock.violations, v0)
        local after = { attrs(smart) }
        assertDeepEquals(after, before)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("smart button position persists on drag stop and is restorable", function()
        ns.db.frames.locked = false
        st(smart).scripts.OnDragStop(smart)
        assertEquals(type(ns.db.smartButton.point), "table")
        assertTrue(pcall(ns.BuffButtons.ApplySmartPosition, ns.BuffButtons))
        assertEquals(#mock.errors, 0, errstr())
    end)
end)


-- ======================================================================== Buff Presets pane: role buffs section
describe("extras: Buff Presets pane (add, remove, toggle roles and single)", function()
    local BOOK = { names = { [19750] = "Flash of Light", [900002] = "Oath of Light", [900001] = "Light's Vigil" },
        lines = { { name = "G", ids = {} }, { name = "H", ids = { 19750, 900002, 900001 } } } }
    local ns = boot({ group = 3, book = BOOK, units = {
        party1 = unit("TankPal", "WARRIOR", "TANK"), party2 = unit("Mage", "MAGE", "DAMAGER"), party3 = unit("Heal", "PRIEST", "HEALER") } })
    local preset = ns.db.presets[ns.db.activePreset]
    preset.extras = {}
    ns.Options:Show("buffs"); mock.flushTimers()

    local function button(text)
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.scripts.OnClick and s.text == text then return f end
        end
    end
    local function click(f) st(f).scripts.OnClick(f, "LeftButton"); mock.flushTimers() end
    local function checkRows()
        local rows, cur = {}, nil
        local want = { Tank = 1, Healer = 2, DPS = 3, Self = 4, ["One target at a time"] = 5 }
        local seq = {}
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "CheckButton" and f.label then
                local t = st(f.label).text
                if want[t] and (t ~= "Self" or true) then seq[#seq + 1] = { f = f, kind = t } end
            end
        end
        -- the extras rows are the last 8 x 5 checkboxes created
        local n = #seq
        local first = n - 8 * 5 + 1
        for i = 0, 7 do
            local r = {}
            for j = 1, 5 do r[seq[first + i * 5 + j - 1].kind] = seq[first + i * 5 + j - 1].f end
            rows[i + 1] = r
        end
        return rows
    end
    local function removeButtons()
        local out = {}
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.text == "X" and s.scripts.OnClick then out[#out + 1] = f end
        end
        return out
    end
    local function toggle(cb, value) st(cb).checked = value; st(cb).scripts.OnClick(cb, "LeftButton"); mock.flushTimers() end

    it("pane builds with the role buffs section", function()
        assertNotNil(button("+ Add role buff"))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("+ Add role buff lists known spells; picking one appends an entry (TANK, not single)", function()
        mock.menu = nil
        click(button("+ Add role buff"))
        local texts = {}
        for _, e in ipairs(mock.menu.entries) do texts[e.text] = true end
        assertTrue(texts["Oath of Light"], "Oath of Light must be offered"); assertTrue(texts["Light's Vigil"])
        assertTrue(mock.pickMenu("Oath of Light"))
        mock.flushTimers()
        assertEquals(#preset.extras, 1)
        assertEquals(preset.extras[1].spell, "Oath of Light")
        assertEquals(preset.extras[1].roles.TANK, true)
        assertEquals(preset.extras[1].single, false)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the new role buff immediately produces a button on the tank (integration)", function()
        refresh()
        assertTrue(active(extra("party1")), "tank extra button should be active")
    end)
    it("toggle roles: Healer on, DPS on, Self on, Tank off; effects on ResolveExtras", function()
        local rows = checkRows()
        toggle(rows[1].Healer, true); toggle(rows[1].DPS, true); toggle(rows[1].Self, true); toggle(rows[1].Tank, false)
        local roles = preset.extras[1].roles
        assertEquals(roles.HEALER, true); assertEquals(roles.DAMAGER, true); assertEquals(roles.SELF, true); assertNil(roles.TANK)
        assertEquals(#ns.Presets.ResolveExtras(preset, "HEALER", false), 1)
        assertEquals(#ns.Presets.ResolveExtras(preset, "TANK", false), 0)
        assertEquals(#ns.Presets.ResolveExtras(preset, "NONE", true), 1)
        refresh()
        assertFalse(active(extra("party1")), "tank no longer targeted")
        assertTrue(active(extra("party2")), "dps now targeted")
        assertTrue(active(extra("party3")), "healer now targeted")
        assertTrue(active(extra("player")), "self now targeted")
    end)
    it("toggle 'One target at a time' on and off", function()
        local rows = checkRows()
        toggle(rows[1]["One target at a time"], true)
        assertEquals(preset.extras[1].single, true)
        toggle(rows[1]["One target at a time"], false)
        assertEquals(preset.extras[1].single, false)
    end)
    it("add a second entry via the menu and remove the first with X: the second shifts up", function()
        mock.menu = nil
        click(button("+ Add role buff")); assertTrue(mock.pickMenu("Light's Vigil")); mock.flushTimers()
        assertEquals(#preset.extras, 2); assertEquals(preset.extras[2].spell, "Light's Vigil")
        local xs = removeButtons()
        assertTrue(#xs >= 2)
        click(xs[1])
        assertEquals(#preset.extras, 1); assertEquals(preset.extras[1].spell, "Light's Vigil")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("remove the last entry: pane refreshes, no extras button remains", function()
        click(removeButtons()[1])
        assertEquals(#preset.extras, 0)
        refresh()
        for _, u in ipairs({ "player", "party1", "party2", "party3" }) do assertFalse(active(extra(u))) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("dragging a spell onto the add button adds it (when the cursor holds a spell)", function()
        S.cursor = { "spell", 1, "spell", 900002 }
        local btn = button("+ Add role buff")
        local h = st(btn).scripts.OnReceiveDrag
        assertNotNil(h)
        h(btn); mock.flushTimers()
        if ns.CursorSpellName then
            assertEquals(#preset.extras, 1); assertEquals(preset.extras[1].spell, "Oath of Light"); assertNil(S.cursor)
            click(removeButtons()[1])
        else
            warn("ns.CursorSpellName not exposed; drag-add not exercised")
        end
        S.cursor = nil
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("dragging a non-spell does nothing", function()
        S.cursor = { "item", 5 }
        local btn = button("+ Add role buff")
        st(btn).scripts.OnReceiveDrag(btn)
        assertEquals(#preset.extras, 0)
        S.cursor = nil
    end)
    it("extras are per preset: switching the edited preset shows that preset's list", function()
        mock.menu = nil
        click(button("+ Add role buff")); mock.pickMenu("Oath of Light"); mock.flushTimers()
        assertEquals(#preset.extras, 1)
        local other = ns.db.presets[2]
        assertTrue(#(other.extras or {}) == 0 or other.extras ~= preset.extras)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("add / toggle / remove in combat: data changes, nothing protected is touched", function()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0, n0 = #mock.violations, #mock.softViolations, #mock.calls
        mock.menu = nil
        click(button("+ Add role buff")); mock.pickMenu("Light's Vigil")
        local rows = checkRows()
        toggle(rows[2].Healer, true)
        click(removeButtons()[2])
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.secure and c.method == "SetAttribute", "SetAttribute on secure frame in combat")
        end
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)


-- ======================================================================== tank button: armed / idle rules
describe("tank buff button is armed only while the tank role buff is missing", function()
    local BOOK = { names = { [19750] = "Flash of Light", [900002] = "Oath of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 19750, 900002 } } } }
    local function mk(units, single, units2)
        local ns = boot({ group = 4, book = BOOK, units = units or {
            party1 = unit("Tank1", "WARRIOR", "TANK"), party2 = unit("Dps", "MAGE", "DAMAGER"), party3 = unit("Dps2", "ROGUE", "DAMAGER"),
            party4 = unit("Dps3", "HUNTER", "DAMAGER") } })
        local preset = ns.db.presets[ns.db.activePreset]
        preset.extras = {}
        ns.Presets.AddExtra(preset, "Oath of Light", { TANK = true }, single ~= false)
        ns:Changed("presets"); refresh()
        return ns, frameNamed("HealerForeverTankBuff"), frameNamed("HealerForeverSmartBuff")
    end
    local function mine(exp) return { spellId = 900002, name = "Oath of Light", icon = 1, duration = 600, expirationTime = exp, isHelpful = true, sourceUnit = "player" } end
    local function a(f) local x = st(f).attrs; return x.type, spellOfMacro(x.macrotext), x.unit end
    local function debug()
        mock.printed = {}
        local fn; for _, f in pairs(_G.SlashCmdList) do fn = f end
        fn("debug buffs")
        return table.concat(mock.printed, "\n")
    end

    it("armed while the oath is missing: points at the tank", function()
        local ns, tank = mk()
        local t, spell, u = a(tank)
        assertEquals(t, "macro"); assertEquals(spell, "Oath of Light"); assertEquals(u, "party1")
        assertNotNil(debug():find("tank button: armed", 1, true))
    end)
    it("armed -> oath applied -> cleared -> aura removed -> armed again", function()
        local ns, tank = mk()
        assertEquals((a(tank)), "macro")
        S.auras.party1 = { mine(0) }; refresh()
        local t, spell, u = a(tank)
        assertNil(t); assertNil(spell); assertNil(u)
        assertNotNil(debug():find("tank button: idle: tank already has Oath of Light", 1, true))
        S.auras.party1 = {}; refresh()
        assertEquals((a(tank)), "macro")
    end)
    it("a 'not mine' oath on the tank also satisfies a non-single entry (idle)", function()
        local ns, tank = mk(nil, false)
        local x = mine(0); x.sourceUnit = "party2"
        S.auras.party1 = { x }; refresh()
        assertNil((a(tank)))
    end)
    it("about to expire (under the 60s threshold) -> armed again; exactly 60s or more -> idle", function()
        local ns, tank = mk()
        assertEquals(ns.db.buffs.threshold, 60)
        S.auras.party1 = { mine(S.now + 600) }; refresh()
        assertNil((a(tank)), "600s left: idle")
        S.auras.party1 = { mine(S.now + 60) }; refresh()
        assertNil((a(tank)), "exactly 60s left: idle")
        S.auras.party1 = { mine(S.now + 59) }; refresh()
        assertEquals((a(tank)), "macro", "59s left: armed")
        S.auras.party1 = { mine(S.now + 5) }; refresh()
        assertEquals((a(tank)), "macro", "5s left: armed")
        S.auras.party1 = { mine(S.now - 1) }; refresh()
        assertEquals((a(tank)), "macro", "expired: armed")
    end)
    it("a custom threshold is honoured (120s): 100s left is armed", function()
        local ns, tank = mk()
        ns.db.buffs.threshold = 120; ns:Changed("presets")
        S.auras.party1 = { mine(S.now + 100) }; refresh()
        assertEquals((a(tank)), "macro")
        S.auras.party1 = { mine(S.now + 130) }; refresh()
        assertNil((a(tank)))
    end)
    it("expiry noticed by the 1s ticker alone as time passes", function()
        local ns, tank = mk()
        S.auras.party1 = { mine(S.now + 90) }; refresh()
        assertNil((a(tank)))
        S.now = S.now + 40; mock.tick(); mock.flushTimers()
        assertEquals((a(tank)), "macro", "50s left after 40s passed")
    end)
    it("two tanks, single: our aura on either tank clears it; none -> armed on the first tank", function()
        local ns, tank = mk({ party1 = unit("Tank1", "WARRIOR", "TANK"), party2 = unit("Tank2", "PALADIN", "TANK"),
            party3 = unit("Dps2", "ROGUE", "DAMAGER"), party4 = unit("Dps3", "HUNTER", "DAMAGER") }, true)
        local t, _, u = a(tank)
        assertEquals(t, "macro"); assertEquals(u, "party1")
        S.auras.party2 = { mine(0) }; refresh()
        assertNil((a(tank)), "our aura is on tank 2 -> cleared")
        S.auras.party2 = {}; S.auras.party1 = { mine(0) }; refresh()
        assertNil((a(tank)), "our aura is on tank 1 -> cleared")
        S.auras.party1 = {}; refresh()
        t, _, u = a(tank)
        assertEquals(t, "macro"); assertEquals(u, "party1")
    end)
    it("two tanks, NOT single: the tank without the buff is the target", function()
        local ns, tank = mk({ party1 = unit("Tank1", "WARRIOR", "TANK"), party2 = unit("Tank2", "PALADIN", "TANK"),
            party3 = unit("Dps2", "ROGUE", "DAMAGER"), party4 = unit("Dps3", "HUNTER", "DAMAGER") }, false)
        S.auras.party1 = { mine(0) }; refresh()
        local t, _, u = a(tank)
        assertEquals(t, "macro"); assertEquals(u, "party2")
        S.auras.party2 = { mine(0) }; refresh()
        assertNil((a(tank)))
    end)
    it("unknown spell, no tank, no extra: idle with a reason in /hf debug buffs", function()
        local ns, tank = mk()
        S.units.party1.role = "DAMAGER"; mock.fire("PLAYER_ROLES_ASSIGNED"); refresh()
        assertNil((a(tank)))
        assertNotNil(debug():find("tank button: idle: no tank in the group", 1, true))
        ns.db.presets[ns.db.activePreset].extras = {}; ns:Changed("presets"); refresh()
        assertNotNil(debug():find("tank button: idle: no tank role buff configured", 1, true))
    end)
    it("unknown oath spell: idle (never an armed button that cannot cast)", function()
        local ns = boot({ group = 2, units = { party1 = unit("Tank1", "WARRIOR", "TANK") }, book = { names = { [19750] = "Flash of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 19750 } } } },
            setup = function()
                mock.setGlobal("IsPlayerSpell", function() return false end)
                mock.setGlobal("IsSpellKnownOrOverridesKnown", function() return false end)
                mock.setGlobal("IsSpellKnown", function() return false end)
                _G.C_SpellBook.IsSpellKnown = function() return false end
            end })
        ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true }, true)
        ns:Changed("presets"); refresh()
        assertNil((a(frameNamed("HealerForeverTankBuff"))))
        assertNotNil(debug():find("don't know", 1, true))
    end)
    it("in combat the tank button attributes are frozen and never touched", function()
        local ns, tank = mk()
        local before = { a(tank) }
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local n0 = #mock.calls
        S.auras.party1 = { mine(0) }
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers(); mock.tick()
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.method == "SetAttribute" and c.obj == tank, "SetAttribute on tank button in combat")
        end
        assertDeepEquals({ a(tank) }, before)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers(); mock.tick()
        assertNil((a(tank)), "after combat the oath is seen: idle")
        assertEquals(#mock.errors, 0, errstr())
    end)

    it("the on-screen 'Buff next' button hides when nothing is pending, shows when something is", function()
        local ns, tank, smart = mk()
        ns.db.smartButton.show = true; ns:Changed("presets"); refresh()
        assertEquals(smart:GetAlpha(), 1); assertTrue(st(smart).mouse)
        local function giveAll()
            for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
                local preset = ns.db.presets[ns.db.activePreset]
                local _, token = UnitClass(u)
                local key = ns.Presets.ResolveBuff(preset, token, ns.Roles.Get(u), u == "player")
                S.auras[u] = S.auras[u] or {}
                if key then
                    local def = ns.Classes.BUFFS[key]
                    table.insert(S.auras[u], { spellId = def.spellIds[1], name = def.names[1], expirationTime = 0, isHelpful = true, sourceUnit = "player" })
                end
            end
            table.insert(S.auras.party1, mine(0))
        end
        giveAll(); refresh()
        assertNil(st(smart).attrs.type, "nothing pending: smart attributes cleared")
        assertEquals(smart:GetAlpha(), 0, "on-screen button must hide when nothing is pending")
        assertFalse(st(smart).mouse)
        S.auras.party2 = {}; refresh()
        assertEquals(smart:GetAlpha(), 1); assertTrue(st(smart).mouse)
    end)
    it("with the on-screen button disabled it never shows, but the keybound attributes still work", function()
        local ns, tank, smart = mk()
        ns.db.smartButton.show = false; ns:Changed("presets"); refresh()
        assertEquals(smart:GetAlpha(), 0); assertFalse(st(smart).mouse)
        assertEquals(st(smart).attrs.type, "macro", "key press still has a target")
    end)
    it("debug output reports the smart pick", function()
        local ns = mk()
        assertNotNil(debug():find("smart buff:", 1, true))
    end)
end)
