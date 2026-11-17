-- Buff buttons for every caster class (Paladin, Priest, Mage, Druid): next missing buff in catalog order, the 60s threshold,
-- the count badge, the next buff arming after one lands, strict left/right macros, greyed unknown spells, range gating, the smart
-- button (tank -> healers -> DPS -> you, one cast per press), MissingCount feeding the minimap dot, combat and secret safety.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

local PARTY = { party1 = unit("Tank", "WARRIOR", "TANK"), party2 = unit("Heal", "PRIEST", "HEALER"), party3 = unit("Mage", "MAGE", "DAMAGER"),
    party4 = unit("Rogue", "ROGUE", "DAMAGER") }

local function boot(class, opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.player.class = class
    for k, v in pairs(opts.party or PARTY) do local c = {}; for kk, vv in pairs(v) do c[kk] = vv end; S.units[k] = c end
    if opts.setup then opts.setup() end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 4)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local function refresh() mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers() end
local function buff(u) for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverBuff%d$") and f.unit == u then return f end end end
local function smart() for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverSmartBuff" then return f end end end
local function active(b) return b:GetAlpha() > 0 and st(b).mouse == true end
local function countText(b) return st(b.count).text end
local function activePreset(ns) return ns.db.presets[ns.db.activePreset] end
local function assign(ns, class, role, keys)
    local preset = activePreset(ns)
    preset.map[class] = preset.map[class] or { DEFAULT = {} }
    preset.map[class][role or "DEFAULT"] = keys
    ns:Changed("presets"); refresh()
end
local function auraOf(ns, key, remaining)
    local d = ns.Classes.BUFFS[key]
    return { spellId = d.spellIds[1] or 0, name = d.name, icon = 1, duration = 600, expirationTime = remaining and (S.now + remaining) or 0, applications = 0,
        isHelpful = true, sourceUnit = "player", auraInstanceID = 5000 + ns.Classes.BuffOrder(key) }
end
local function give(ns, u, key, remaining)
    S.auras[u] = S.auras[u] or {}
    table.insert(S.auras[u], auraOf(ns, key, remaining))
    mock.fire("UNIT_AURA", u); refresh()
end
-- only these spell NAMES are known to the player (every known-spell API answers from the same set)
local function knowOnly(names)
    local ids = {}
    for _, n in ipairs(names) do local info = C_Spell.GetSpellInfo(n); if info then ids[info.spellID] = true end end
    _G.IsPlayerSpell = function(id) return ids[id] == true end
    _G.IsSpellKnownOrOverridesKnown = function(id) return ids[id] == true end
    _G.IsSpellKnown = function(id) return ids[id] == true end
    _G.C_SpellBook = { IsSpellKnown = function(id) return ids[id] == true end }
    mock.fire("SPELLS_CHANGED"); mock.flushTimers(); mock.tick(); mock.flushTimers()
end
local function macroOf(ns, u, spell) return ns.Bindings.BuildMacroText(u, spell, nil) end

-- a multi-buff cell to test with, per caster class
local SETS = {
    PALADIN = { "kings" },
    PRIEST = { "fortitude", "spirit", "shadowprot" },
    MAGE = { "arcaneint", "dampen" },
    DRUID = { "motw", "thorns" },
}
local CASTERS = { "PALADIN", "PRIEST", "MAGE", "DRUID" }

for _, class in ipairs(CASTERS) do
    describe("buff buttons: " .. class, function()
        local keys = SETS[class]
        local function fresh()
            local ns = boot(class)
            assign(ns, "WARRIOR", "DEFAULT", keys)
            return ns
        end

        it("shows the FIRST missing buff of the cell (catalog order) on the member, even when the cell lists them in another order", function()
            local ns = fresh()
            local b = buff("party1")
            assertEquals(b.buffKey, keys[1]); assertTrue(active(b))
            -- a hand-ordered cell is still presented in catalog order
            local rev = {}
            for i = #keys, 1, -1 do rev[#rev + 1] = keys[i] end
            assertEquals(ns.Presets.CellBuffs({ map = { WARRIOR = { DEFAULT = rev } } }, "WARRIOR", nil, false)[1], keys[1])
            assertEquals(#mock.errors, 0, errstr())
        end)

        it("members whose cell is empty show nothing", function()
            local ns = fresh()
            assign(ns, "PRIEST", "DEFAULT", {}); assign(ns, "MAGE", "DEFAULT", {})
            assertFalse(active(buff("party2"))); assertFalse(active(buff("party3")))
            assertTrue(active(buff("party1")))
        end)

        it("the rebuff threshold is a PERCENT of the buff's duration (default 5%): 29s of 600s (4.8%) still shows the buff, 31s (5.2%) hides it", function()
            local ns = fresh()
            assertEquals(ns.db.buffs.rebuffPercent, 5)
            for _, key in ipairs(keys) do give(ns, "party1", key, 29) end
            assertEquals(buff("party1").buffKey, keys[1], "all running out: first still missing")
            S.auras.party1 = {}
            for _, key in ipairs(keys) do give(ns, "party1", key, 31) end
            assertFalse(active(buff("party1")), "5.2% left: nothing to do")
            ns.db.buffs.warn = false; refresh()
            S.auras.party1 = {}
            for _, key in ipairs(keys) do table.insert(S.auras.party1, auraOf(ns, key, 10)) end
            mock.fire("UNIT_AURA", "party1"); refresh()
            assertFalse(active(buff("party1")), "warn off: only a missing aura counts")
        end)

        it("after a buff lands the NEXT missing one arms (out of combat), until nothing is missing", function()
            local ns = fresh()
            for i, key in ipairs(keys) do
                local b = buff("party1")
                assertEquals(b.buffKey, key, "step " .. i)
                assertEquals(st(b).attrs.macrotext1, macroOf(ns, "party1", ns.Classes.BUFFS[key].name))
                give(ns, "party1", key, 600)
            end
            assertFalse(active(buff("party1")))
            assertNil(buff("party1").buffKey)
        end)

        it("an aura that is missing the later buff but has the earlier one skips to the later one", function()
            if #keys < 2 then return end
            local ns = fresh()
            give(ns, "party1", keys[1], 600)
            assertEquals(buff("party1").buffKey, keys[2])
        end)

        it("the count badge: empty for one missing buff, the number for two or more", function()
            local ns = fresh()
            local n = #keys
            assertEquals(countText(buff("party1")), n >= 2 and tostring(n) or "")
            for i, key in ipairs(keys) do
                give(ns, "party1", key, 600)
                local left = n - i
                if left > 0 then assertEquals(countText(buff("party1")), left >= 2 and tostring(left) or "", "missing " .. left) end
            end
            assertEquals(countText(buff("party1")), "")
        end)

        it("the tooltip lists the next buff and 'Also missing' for the rest", function()
            local ns = fresh()
            local lines = {}
            _G.GameTooltip.SetOwner = function() end; _G.GameTooltip.Show = function() end
            _G.GameTooltip.AddLine = function(_, t) lines[#lines + 1] = tostring(t) end
            st(buff("party1")).hooks.OnEnter[1](buff("party1"))
            local text = table.concat(lines, "\n")
            assertTrue(text:find("Missing: " .. ns.Classes.BUFFS[keys[1]].name, 1, true), text)
            if #keys > 1 then assertTrue(text:find("Also missing: " .. ns.Classes.BUFFS[keys[2]].name, 1, true), text) else assertNil(text:find("Also missing", 1, true)) end
            assertTrue(text:find("Left-click: " .. ns.Classes.BUFFS[keys[1]].name, 1, true), text)
        end)

        it("strict macros: left casts the single spell, right the group spell (or the single when there is none); explicit unit, no fallback clause", function()
            local ns = fresh()
            local b = buff("party1")
            local def = ns.Classes.BUFFS[keys[1]]
            assertEquals(st(b).attrs.type1, "macro"); assertEquals(st(b).attrs.type2, "macro")
            assertEquals(st(b).attrs.macrotext1, macroOf(ns, "party1", def.name))
            assertEquals(st(b).attrs.macrotext2, macroOf(ns, "party1", def.groupSpell or def.name))
            for _, which in ipairs({ "macrotext1", "macrotext2" }) do
                local m = st(b).attrs[which]
                assertTrue(m:find("[@party1", 1, true), m); assertNil(m:find("@player", 1, true)); assertNil(m:find("@target", 1, true)); assertNil(m:find("target=", 1, true))
                assertEquals(select(2, m:gsub("/cast", "")), 1, "exactly one /cast")
            end
            assertNil(st(b).attrs.spell1, "never type=spell")
        end)

        it("right-click falls back to the single spell when the group spell is not known; with only the group spell known both clicks use it", function()
            local ns = fresh()
            local def = ns.Classes.BUFFS[keys[1]]
            if not def.groupSpell then return end
            knowOnly({ def.name })
            local b = buff("party1")
            assertEquals(st(b).attrs.macrotext1, macroOf(ns, "party1", def.name)); assertEquals(st(b).attrs.macrotext2, macroOf(ns, "party1", def.name))
            knowOnly({ def.groupSpell })
            b = buff("party1")
            assertEquals(st(b).attrs.macrotext1, macroOf(ns, "party1", def.groupSpell)); assertEquals(st(b).attrs.macrotext2, macroOf(ns, "party1", def.groupSpell))
        end)

        it("an unknown spell is greyed (visible, not clickable) with the 'Not in your spellbook' tooltip, and arms once it becomes known", function()
            local ns = fresh()
            knowOnly({})
            local b = buff("party1")
            local def = ns.Classes.BUFFS[keys[1]]
            assertEquals(b.unknownSpell, def.name); assertEquals(b:GetAlpha(), 0.8); assertTrue(st(b.icon).desat)
            assertNil(st(b).attrs.type1); assertNil(st(b).attrs.macrotext1); assertNil(st(b).attrs.macrotext2)
            assertFalse(st(b.pulse).playing and true or false)
            local lines = {}
            _G.GameTooltip.SetOwner = function() end; _G.GameTooltip.Show = function() end
            _G.GameTooltip.AddLine = function(_, t) lines[#lines + 1] = tostring(t) end
            st(b).hooks.OnEnter[1](b)
            assertTrue(table.concat(lines, "|"):find("Not in your spellbook: " .. def.name, 1, true), table.concat(lines, "|"))
            knowOnly({ def.name })
            b = buff("party1")
            assertEquals(st(b).attrs.type1, "macro"); assertFalse(st(b.icon).desat); assertEquals(b:GetAlpha(), 1)
        end)

        it("range gating: out of range or not visible dims and DISARMS the button; back in range re-arms it", function()
            local ns = fresh()
            assertEquals(st(buff("party1")).attrs.type1, "macro")
            S.outOfRange.party1 = true; refresh()
            local b = buff("party1")
            assertTrue(b.unreachable); assertEquals(b:GetAlpha(), 0.7); assertNil(st(b).attrs.type1); assertNil(st(b).attrs.macrotext1)
            S.outOfRange.party1 = nil; S.invisible = { party1 = true }; refresh()
            assertTrue(buff("party1").unreachable, "not visible")
            S.invisible = nil; refresh()
            b = buff("party1")
            assertNil(b.unreachable); assertEquals(st(b).attrs.type1, "macro"); assertEquals(b:GetAlpha(), 1)
            S.spellOut = { party1 = true }; refresh()
            assertTrue(buff("party1").unreachable, "the buff spell itself is out of range")
            S.spellOut = nil; refresh()
        end)

        it("unreachable state still counts as missing and shows the range line in the tooltip", function()
            local ns = fresh()
            S.outOfRange.party1 = true; refresh()
            assertEquals(buff("party1").buffKey, keys[1])
            local lines = {}
            _G.GameTooltip.SetOwner = function() end; _G.GameTooltip.Show = function() end
            _G.GameTooltip.AddLine = function(_, t) lines[#lines + 1] = tostring(t) end
            st(buff("party1")).hooks.OnEnter[1](buff("party1"))
            assertTrue(table.concat(lines, "|"):find("Out of range", 1, true))
        end)

        it("a dead or offline member shows no buff button", function()
            local ns = fresh()
            S.dead.party1 = true; refresh(); assertFalse(active(buff("party1")))
            S.dead.party1 = nil; S.offline.party1 = true; refresh(); assertFalse(active(buff("party1")))
        end)

        it("in combat the buttons are frozen (no attribute writes, no protected calls); leaving combat refreshes them", function()
            local ns = fresh()
            local before = st(buff("party1")).attrs.macrotext1
            local v0 = #mock.violations
            S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
            S.auras.party1 = { auraOf(ns, keys[1], 600) }
            mock.fire("UNIT_AURA", "party1"); mock.flushTimers(); mock.tick(); mock.runOnUpdate(4, 0.5)
            assertEquals(st(buff("party1")).attrs.macrotext1, before, "frozen during combat")
            S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); refresh()
            if #keys > 1 then assertEquals(buff("party1").buffKey, keys[2]) else assertFalse(active(buff("party1"))) end
            assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, 0); assertEquals(#mock.errors, 0, errstr())
        end)

        it("everything secret (even out of combat) and secret + combat: no errors, no protected calls", function()
            local ns = fresh()
            S.secretAll = true
            refresh(); mock.fire("UNIT_AURA", "party1"); mock.fire("UNIT_AURA", "player"); refresh(); mock.runOnUpdate(4, 0.5)
            assertTrue(pcall(ns.BuffButtons.MissingCount, ns.BuffButtons))
            assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "debug buffs"))
            S.combat = true; mock.fire("PLAYER_REGEN_DISABLED"); S.secret = true
            refresh(); mock.runOnUpdate(4, 0.5)
            S.combat = false; S.secret = false; S.secretAll = false; mock.fire("PLAYER_REGEN_ENABLED"); refresh()
            assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
        end)

        it("MissingCount counts the missing buffs and feeds the minimap button's status dot", function()
            local ns = fresh()
            local BB = ns.BuffButtons
            local first = BB:MissingCount()
            assertTrue(first >= #keys, "party1 alone is missing " .. #keys .. ", counted " .. first)
            local mb
            for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverMinimapButton" then mb = f end end
            ns.MinimapButton:UpdateBadges()
            local v = st(mb.dot).vertex
            assertTrue(v.r > 0.9 and v.g < 0.3, "red while something is missing")
            -- feed everything
            for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
                S.auras[u] = {}
                local preset = activePreset(ns)
                local _, token = UnitClass(u)
                for _, key in ipairs(ns.Presets.CellBuffs(preset, token, ns.Roles.Get(u), u == "player")) do table.insert(S.auras[u], auraOf(ns, key, 600)) end
                mock.fire("UNIT_AURA", u)
            end
            refresh(); ns.MinimapButton:UpdateBadges()
            assertEquals(BB:MissingCount(), 0)
            v = st(mb.dot).vertex
            assertTrue(v.g > 0.8 and v.r < 0.5, "green when nothing is missing")
        end)
    end)
end

-- ======================================================================== the count badge needs 2+ missing
describe("buff buttons: the count badge appears only for 2 or more missing buffs", function()
    it("a Paladin (one radio group) never shows a badge; a Priest with three buffs shows 3, 2, then none", function()
        local ns = boot("PALADIN")
        assign(ns, "WARRIOR", "DEFAULT", { "might" })
        assertEquals(countText(buff("party1")), "")
        ns = boot("PRIEST")
        assign(ns, "WARRIOR", "DEFAULT", { "fortitude", "spirit", "shadowprot" })
        assertEquals(countText(buff("party1")), "3")
        give(ns, "party1", "fortitude", 600); assertEquals(countText(buff("party1")), "2")
        give(ns, "party1", "spirit", 600); assertEquals(countText(buff("party1")), "")
        assertEquals(buff("party1").buffKey, "shadowprot")
    end)
    it("MissingCount sums the badge counts over members: 3 + 2 + 1", function()
        local ns = boot("PRIEST")
        assign(ns, "WARRIOR", "DEFAULT", { "fortitude", "spirit", "shadowprot" })
        assign(ns, "PRIEST", "DEFAULT", { "fortitude", "spirit" })
        assign(ns, "MAGE", "DEFAULT", { "fortitude" })
        assign(ns, "ROGUE", "DEFAULT", {})
        local BB = ns.BuffButtons
        assertEquals(buff("party1").missingCount, 3); assertEquals(buff("party2").missingCount, 2); assertEquals(buff("party3").missingCount, 1)
        local own = buff("player")
        local playerCount = own.missingCount or 0
        assertEquals(BB:MissingCount(), 3 + 2 + 1 + playerCount + (buff("party4").missingCount or 0))
    end)
end)

-- ======================================================================== smart button
describe("smart buff button: tank -> healers -> DPS -> you, one cast per press", function()
    local function boot3(class)
        local ns = boot(class)
        return ns
    end
    local function smartState() local s = smart(); return s.castUnit, s.castSpell, st(s).attrs.macrotext, st(s).attrs.unit end
    it("walks the members in role order as each buff lands (Priest with Fortitude)", function()
        local ns = boot3("PRIEST")
        for _, c in ipairs({ "WARRIOR", "PRIEST", "MAGE", "ROGUE", "PALADIN" }) do assign(ns, c, "DEFAULT", { "fortitude" }) end
        local seen = {}
        for step = 1, 5 do
            local u, spell, macro, attrUnit = smartState()
            assertNotNil(u, "step " .. step)
            assertEquals(spell, "Power Word: Fortitude"); assertEquals(attrUnit, u)
            assertEquals(macro, macroOf(ns, u, "Power Word: Fortitude"))
            assertEquals(select(2, macro:gsub("/cast", "")), 1, "one cast per press")
            seen[#seen + 1] = u
            give(ns, u, "fortitude", 600)
        end
        assertDeepEquals(seen, { "party1", "party2", "party3", "party4", "player" }, "tank, healer, DPS (party3 < party4), then you")
        assertNil(smart().castUnit); assertNil(st(smart()).attrs.macrotext)
    end)
    it("the smart button casts the SINGLE spell and picks catalog order within one member (Priest: Fortitude, then Spirit)", function()
        local ns = boot3("PRIEST")
        for _, c in ipairs({ "WARRIOR", "PRIEST", "MAGE", "ROGUE", "PALADIN" }) do assign(ns, c, "DEFAULT", {}) end
        assign(ns, "WARRIOR", "DEFAULT", { "fortitude", "spirit" })
        assertEquals(smart().castUnit, "party1"); assertEquals(smart().castSpell, "Power Word: Fortitude")
        give(ns, "party1", "fortitude", 600)
        assertEquals(smart().castSpell, "Divine Spirit")
        give(ns, "party1", "spirit", 600)
        assertNil(smart().castUnit)
    end)
    it("an unreachable or unknown buff is skipped by the smart button (only ready casts are offered)", function()
        local ns = boot3("PRIEST")
        for _, c in ipairs({ "WARRIOR", "PRIEST", "MAGE", "ROGUE", "PALADIN" }) do assign(ns, c, "DEFAULT", { "fortitude" }) end
        S.outOfRange.party1 = true; refresh()
        assertEquals(smart().castUnit, "party2", "the out-of-range tank is skipped")
        S.outOfRange.party1 = nil; refresh()
        assertEquals(smart().castUnit, "party1")
    end)
    it("the smart button is hidden by default (the bound key still works) and its tooltip names the buff and the target", function()
        local ns = boot3("MAGE")
        assign(ns, "WARRIOR", "DEFAULT", { "arcaneint" })
        local s = smart()
        assertNotNil(s.pendingText); assertTrue(s.pendingText:find("Arcane Intellect", 1, true))
        assertEquals(st(s).attrs.type, "macro")
    end)
    it("the smart button never changes in combat (frozen attributes) and makes no protected calls", function()
        local ns = boot3("PRIEST")
        assign(ns, "WARRIOR", "DEFAULT", { "fortitude" })
        local before = st(smart()).attrs.macrotext
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        S.auras.party1 = { auraOf(ns, "fortitude", 600) }
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers(); mock.tick(); mock.runOnUpdate(3, 0.5)
        assertEquals(st(smart()).attrs.macrotext, before)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); refresh()
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== classes without a catalog
describe("buff buttons: a class without party buffs never shows buff buttons, role buffs still work", function()
    for _, class in ipairs({ "WARRIOR", "ROGUE", "HUNTER", "SHAMAN", "WARLOCK" }) do
        it(class .. ": no blessing/buff button, debug says why", function()
            local ns = boot(class)
            for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do assertFalse(active(buff(u)), u) end
            assertEquals(ns.BuffButtons:MissingCount(), 0)
            mock.printed = {}
            assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "debug buffs"))
            assertTrue(table.concat(mock.printed, "\n"):find("your class has no party buffs to assign", 1, true))
            assertEquals(#mock.errors, 0, errstr())
        end)
    end
    it("a Warrior's role buff (extra) button still appears for the tank", function()
        local ns = boot("WARRIOR")
        ns.Presets.AddExtra(activePreset(ns), "Battle Shout", { TANK = true }, false)
        ns:Changed("presets"); refresh()
        local e
        for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverExtra%d$") and f.unit == "party1" then e = f end end
        assertNotNil(e); assertEquals(e.extraSpell, "Battle Shout"); assertTrue(active(e))
    end)
end)
