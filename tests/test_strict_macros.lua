-- Strict macros: no cast path may ever resolve to the player (or the current target) for another unit.
-- Parses every generated macro and attribute set; checks range gating, smart/tank buttons, combat and rosters.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end
local function unit(name, class, role)
    return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
end
local PARTY = {
    party1 = unit("Tank", "WARRIOR", "TANK"), party2 = unit("Heal", "PRIEST", "HEALER"), party3 = unit("Mage", "MAGE", "DAMAGER"),
    party4 = unit("Rogue", "ROGUE", "DAMAGER"),
}
local PETS = { pet = unit("MyPet", "WARRIOR"), partypet1 = unit("P1", "WARRIOR"), partypet2 = unit("P2", "WARRIOR"), partypet3 = unit("P3", "WARRIOR"), partypet4 = unit("P4", "WARRIOR") }
local MEMBERS = { "player", "party1", "party2", "party3", "party4" }
local ALL_UNITS = { "player", "party1", "party2", "party3", "party4", "pet", "partypet1", "partypet2", "partypet3", "partypet4" }

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.player.class = opts.class or "PALADIN"
    for k, v in pairs(opts.party or PARTY) do S.units[k] = deepcopy(v) end
    for k, v in pairs(PETS) do S.units[k] = deepcopy(v) end
    if opts.book then mock.setSpellbook(opts.book) end
    if opts.setup then opts.setup() end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if opts.seed ~= false and opts.char == nil and opts.db == nil and opts.account == nil and ns.db then Fx.seed(ns, { presets = 4 }) end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 4)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local function refresh() mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers() end
local function frameNamed(name) for _, f in ipairs(mock.frames) do if st(f).name == name then return f end end end
local function unitButton(u) for _, f in ipairs(mock.frames) do if tostring(st(f).name):match("^HealerForeverUnit") and st(f).attrs.unit == u then return f end end end
local function buff(u) for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverBuff%d$") and f.unit == u then return f end end end
local function extra(u) for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverExtra%d$") and f.unit == u then return f end end end

-- ---------------------------------------------------------------- macro parser
local FORBIDDEN = { "@player", "@target", "@mouseover", "@focus", "@cursor", "@pet", "target=", "@none" }
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
-- returns a list of problems for one macrotext aimed at `u`
local function macroProblems(text, u)
    local problems = {}
    if type(text) ~= "string" or text == "" then return { "empty macro" } end
    if #text > 255 then problems[#problems + 1] = "longer than 255 characters (" .. #text .. ")" end
    for line in text:gmatch("[^\n]+") do
        local cmd, rest = line:match("^/(%a+)%s+(.*)$")
        if not cmd then
            problems[#problems + 1] = "not a slash-command line: " .. line
        elseif cmd ~= "cast" and cmd ~= "target" then
            problems[#problems + 1] = "unexpected command /" .. cmd
        else
            for clause in rest:gmatch("[^;]+") do
                clause = trim(clause)
                local conds, action = clause:match("^%[(.-)%]%s*(.*)$")
                if not conds then
                    problems[#problems + 1] = "bare clause (would fall back to the player/target): '" .. clause .. "' in " .. line
                else
                    local units = {}
                    for x in conds:gmatch("@([%w_]+)") do units[#units + 1] = x end
                    if #units ~= 1 or units[1] ~= u then problems[#problems + 1] = "clause does not name @" .. u .. " exactly once: [" .. conds .. "]" end
                    for _, bad in ipairs(FORBIDDEN) do
                        if conds:find(bad, 1, true) and not (u == "player" and bad == "@player") and not (u == "pet" and bad == "@pet") then
                            problems[#problems + 1] = "forbidden " .. bad .. " in [" .. conds .. "]"
                        end
                    end
                    if cmd == "cast" and not (conds:find(",help,nodead", 1, true) or conds:find(",dead", 1, true)) then
                        problems[#problems + 1] = "cast clause lacks help,nodead or dead: [" .. conds .. "]"
                    end
                    if cmd == "cast" and action == "" then problems[#problems + 1] = "cast clause without a spell: [" .. conds .. "]" end
                end
            end
            if rest:match(";%s*$") then problems[#problems + 1] = "trailing ';' (empty clause)" end
        end
    end
    return problems
end

-- every macro-ish attribute of a secure button
local function macrosOf(btn)
    local out, bad = {}, {}
    for k, v in pairs(st(btn).attrs) do
        k = tostring(k)
        if k:find("macrotext", 1, true) and not k:match("^hf%-") then out[#out + 1] = { name = k, text = v }
        elseif k:match("^hf%-dtext") then out[#out + 1] = { name = k, text = v } end
        if k:match("type%d*$") or k:match("type%-HFB%d+$") or k:match("%-type%d+$") then
            if v == "spell" then bad[#bad + 1] = k .. "=spell" end
        end
        if k:match("^spell%d*$") or k:match("spell%d+$") or k:match("^%*spell") then bad[#bad + 1] = "spell attribute " .. k end
    end
    return out, bad
end
local function assertButtonSafe(btn, u, label)
    local macros, bad = macrosOf(btn)
    assertEquals(#bad, 0, label .. ": " .. table.concat(bad, ", "))
    for _, m in ipairs(macros) do
        local p = macroProblems(m.text, u)
        assertEquals(#p, 0, label .. " [" .. m.name .. "] " .. tostring(m.text) .. "\n" .. table.concat(p, "\n"))
    end
    return #macros
end

-- ======================================================================== parser self-test
describe("strict: the macro parser flags unsafe macros (guards against a toothless test)", function()
    it("accepts the strict forms", function()
        assertEquals(#macroProblems("/cast [@party1,help,nodead] Flash of Light", "party1"), 0)
        assertEquals(#macroProblems("/cast [@party1,dead,nocombat] Revive; [@party1,dead] Rebirth; [@party1,help,nodead] Holy Light", "party1"), 0)
        assertEquals(#macroProblems("/cast [@party1,dead] Redemption\n/target [@party1,nodead]", "party1"), 0)
        assertEquals(#macroProblems("/target [@party2]", "party2"), 0)
        assertEquals(#macroProblems("/cast [@player,help,nodead] Holy Light", "player"), 0)
    end)
    it("rejects bare clauses, fallbacks, wrong units, @player/@target/@mouseover and over-length", function()
        for _, bad in ipairs({
            "/cast [@party1,dead] Redemption; Flash of Light", "/cast [@party1] Flash of Light", "/cast Flash of Light",
            "/cast [@party1,help,nodead] A; [@player] B", "/cast [@player,help,nodead] Flash of Light", "/cast [@target,help,nodead] X",
            "/cast [@mouseover,help,nodead] X", "/cast [@party2,help,nodead] X", "/cast [help,nodead] X", "/cast [@party1,help,nodead] X;",
            "/cast [target=player,help,nodead] X", "/use [@party1] X", "cast [@party1,help,nodead] X", "/cast [@party1,@player,help,nodead] X",
            "/cast [@party1,help,nodead] " .. string.rep("x", 260),
        }) do assertTrue(#macroProblems(bad, "party1") > 0, "should be rejected: " .. bad) end
    end)
end)

-- ======================================================================== 1. every generated macro / attribute set
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local MODS = {}
for mask = 0, 15 do
    local p = {}
    if mask >= 8 then p[#p + 1] = "alt" end
    if mask % 8 >= 4 then p[#p + 1] = "ctrl" end
    if mask % 4 >= 2 then p[#p + 1] = "meta" end
    if mask % 2 == 1 then p[#p + 1] = "shift" end
    MODS[#MODS + 1] = table.concat(p, "-")
end
local BUTTONS = { 1, 2, 3, 4, 5, 6, 7, 8, 31 }

local function fullBindings()
    local b = {}
    local n = 0
    for _, mod in ipairs(MODS) do
        for _, btn in ipairs(BUTTONS) do
            n = n + 1
            local key = mod .. "|" .. btn
            if n % 7 == 3 then b[key] = { type = "target" }
            elseif key == "|2" then b[key] = { type = "menu" }
            else b[key] = { type = "spell", spell = "Spell Number " .. n } end
        end
    end
    return b
end

describe("strict: no unit-button clause can resolve to the player (all classes x res on/off x modifier x button x unit)", function()
    for _, class in ipairs(CLASSES) do
        for _, resOn in ipairs({ true, false }) do
            it(string.format("%s, resurrectOnClick=%s", class, tostring(resOn)), function()
                local ns = boot({ class = class })
                ns.db.resurrectOnClick = resOn
                ns.db.bindings = fullBindings()
                ns:Changed("bindings"); mock.flushTimers()
                assertEquals(#mock.errors, 0, errstr())
                local total = 0
                for _, u in ipairs(ALL_UNITS) do
                    local b = unitButton(u)
                    assertNotNil(b, u)
                    total = total + assertButtonSafe(b, u, class .. "/" .. u)
                    -- every binding present as a macro on this button
                    local macros = macrosOf(b)
                    local found = {}
                    for _, m in ipairs(macros) do
                        for n in tostring(m.text):gmatch("Spell Number (%d+)") do found[tonumber(n)] = true end
                    end
                    local n = 0
                    for _, mod in ipairs(MODS) do for _, btn in ipairs(BUTTONS) do
                        n = n + 1
                        local act = ns.db.bindings[mod .. "|" .. btn]
                        if act.type == "spell" then assertTrue(found[n], string.format("%s %s|%d (spell %d) missing a macro", u, mod, btn, n)) end
                    end end
                end
                assertTrue(total > 500, "macros inspected: " .. total)
                -- exact expectation for plain slots: built by BuildMacroText with this unit's own token
                local res, ooc
                if resOn then res, ooc = ns.PlayerRes() end
                for _, u in ipairs(ALL_UNITS) do
                    local b = unitButton(u)
                    local isPet = u == "pet" or u:match("^partypet")
                    local want = ns.Bindings.BuildMacroText(u, "Spell Number 1", (not isPet) and res or nil, (not isPet) and ooc or nil)
                    local key = "|1"
                    local act = ns.db.bindings[key]
                    if act.type == "spell" then assertEquals(st(b).attrs.macrotext1, want, u) end
                end
            end)
        end
    end
    it("pets never get resurrection clauses and keep their own token", function()
        local ns = boot({ class = "PALADIN" })
        for _, u in ipairs({ "pet", "partypet1", "partypet4" }) do
            for _, m in ipairs(macrosOf(unitButton(u))) do
                assertNil(tostring(m.text):find("Redemption", 1, true), u .. " must not carry a res spell")
                assertEquals(#macroProblems(m.text, u), 0, m.text)
            end
        end
    end)
    it("the player's own frame may target the player (explicit @player), still strict", function()
        local ns = boot({ class = "PALADIN" })
        local macros = macrosOf(unitButton("player"))
        assertTrue(#macros > 0)
        for _, m in ipairs(macros) do
            assertEquals(#macroProblems(m.text, "player"), 0, m.text)
        end
        assertNotNil(st(unitButton("player")).attrs.macrotext1:find("@player", 1, true))
    end)
    it("no secure frame anywhere carries type=spell or a spell attribute for another unit (whole addon sweep)", function()
        local ns = boot({ class = "PALADIN" })
        local book = { names = { [900002] = "Oath of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 900002 } } } }
        ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true, HEALER = true, DAMAGER = true, SELF = true }, false)
        ns:Changed("presets"); refresh()
        local checked = 0
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.secure then
                for k, v in pairs(s.attrs) do
                    k = tostring(k)
                    if k:match("type%d*$") or k == "type" then assertTrue(v ~= "spell", tostring(s.name) .. " " .. k .. "=spell") end
                    assertFalse(k:match("^spell%d*$") ~= nil or k:match("^%*spell") ~= nil, tostring(s.name) .. " has a spell attribute " .. k)
                    checked = checked + 1
                end
            end
        end
        assertTrue(checked > 100)
    end)
end)

describe("strict: buff, role-buff, smart and tank buttons use strict macros on their own unit", function()
    it("every armed member and role-buff button, and the smart/tank buttons, are strict (several rosters and classes)", function()
        for _, class in ipairs({ "PALADIN", "PRIEST", "DRUID", "SHAMAN" }) do
            local ns = boot({ class = class })
            local preset = ns.db.presets[ns.db.activePreset]
            ns.Presets.AddExtra(preset, "Oath of Light", { TANK = true, HEALER = true, DAMAGER = true, SELF = true }, false)
            ns:Changed("presets"); refresh()
            local armed = 0
            for _, u in ipairs(MEMBERS) do
                for _, b in ipairs({ buff(u), extra(u) }) do
                    if st(b).attrs.macrotext1 then armed = armed + assertButtonSafe(b, u, class .. " " .. tostring(st(b).name)) end
                end
            end
            for _, name in ipairs({ "HealerForeverSmartBuff", "HealerForeverTankBuff" }) do
                local f = frameNamed(name)
                local u = st(f).attrs.unit
                if st(f).attrs.macrotext then
                    assertNotNil(u, name .. " has a macro but no unit")
                    armed = armed + assertButtonSafe(f, u, class .. " " .. name)
                    assertEquals(st(f).attrs.type, "macro")
                end
            end
            if class == "PALADIN" then assertTrue(armed >= 5, "armed buttons inspected: " .. armed) end
            assertEquals(#mock.errors, 0, errstr())
        end
    end)
    it("the smart/tank macro always names the unit stored in its unit attribute", function()
        local ns = boot()
        ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true }, true)
        ns:Changed("presets"); refresh()
        for _, name in ipairs({ "HealerForeverSmartBuff", "HealerForeverTankBuff" }) do
            local a = st(frameNamed(name)).attrs
            if a.macrotext then assertNotNil(a.macrotext:find("@" .. a.unit .. ",", 1, true), name .. ": " .. a.macrotext) end
        end
    end)
    it("dead-swap macros (menu bindings on a res class) are strict too", function()
        local ns = boot({ class = "DRUID" })
        ns.db.bindings = { ["|1"] = { type = "target" }, ["|2"] = { type = "menu" }, ["shift|2"] = { type = "menu" }, ["|3"] = { type = "menu" } }
        ns:Changed("bindings"); mock.flushTimers()
        for _, u in ipairs(MEMBERS) do
            local b = unitButton(u)
            local macros = macrosOf(b)
            local sawDead = false
            for _, m in ipairs(macros) do if m.name:match("^hf%-dtext") then sawDead = true end end
            assertTrue(sawDead, u .. " should have a dead-swap macro for the menu binding")
            assertButtonSafe(b, u, "druid " .. u)
        end
    end)
end)

-- ======================================================================== 2. unreachable members
describe("strict: unreachable members get disarmed, dimmed buttons that re-arm", function()
    local causes = {
        { "not visible", function(u) S.invisible = S.invisible or {}; S.invisible[u] = true end, function(u) S.invisible[u] = nil end },
        { "out of range (UnitInRange)", function(u) S.outOfRange[u] = true end, function(u) S.outOfRange[u] = nil end },
        { "spell out of range (C_Spell.IsSpellInRange)", function(u) S.spellOut = S.spellOut or {}; S.spellOut[u] = true end, function(u) S.spellOut[u] = nil end },
    }
    for _, cause in ipairs(causes) do
        it("blessing button: " .. cause[1], function()
            local ns = boot()
            local b = buff("party1")
            assertEquals(st(b).attrs.type1, "macro"); assertEquals(b:GetAlpha(), 1)
            cause[2]("party1"); mock.fire("UNIT_IN_RANGE_UPDATE", "party1"); mock.flushTimers(); mock.tick()
            assertTrue(b.unreachable, "marked unreachable")
            for _, k in ipairs({ "type1", "macrotext1", "type2", "macrotext2" }) do assertNil(st(b).attrs[k], k .. " must be cleared") end
            assertEquals(b:GetAlpha(), 0.7); assertTrue(st(b.icon).desat); assertTrue(st(b).mouse)
            assertFalse(st(b.pulse).playing)
            -- tooltip says why
            local lines = {}
            _G.GameTooltip.AddLine = function(_, t) lines[#lines + 1] = tostring(t) end
            _G.GameTooltip.SetOwner = function() lines = {} end
            st(b).hooks.OnEnter[1](b)
            assertNotNil(table.concat(lines, "|"):find("Out of range", 1, true), table.concat(lines, "|"))
            -- other units unaffected
            assertEquals(st(buff("party2")).attrs.type1, "macro")
            -- back in range: re-armed (event and ticker both work)
            cause[3]("party1"); mock.fire("UNIT_IN_RANGE_UPDATE", "party1"); mock.flushTimers()
            assertFalse(b.unreachable == true, "re-armed after the event")
            assertEquals(st(b).attrs.type1, "macro"); assertEquals(b:GetAlpha(), 1); assertFalse(st(b.icon).desat == true)
            cause[2]("party1"); mock.tick(); mock.flushTimers()
            assertNil(st(b).attrs.macrotext1)
            cause[3]("party1"); mock.tick(); mock.flushTimers()
            assertNotNil(st(b).attrs.macrotext1, "ticker re-arms without any event")
            assertEquals(#mock.errors, 0, errstr())
        end)
        it("role-buff button: " .. cause[1], function()
            local ns = boot({ book = { names = { [900002] = "Oath of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 900002 } } } } })
            ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true, DAMAGER = true }, false)
            ns:Changed("presets"); refresh()
            local e = extra("party3")
            assertEquals(st(e).attrs.type1, "macro")
            cause[2]("party3"); refresh()
            assertTrue(e.unreachable); assertNil(st(e).attrs.macrotext1); assertNil(st(e).attrs.type1)
            assertEquals(e:GetAlpha(), 0.7); assertTrue(st(e.icon).desat)
            cause[3]("party3"); refresh()
            assertEquals(st(e).attrs.type1, "macro"); assertEquals(e:GetAlpha(), 1)
        end)
    end
    it("the player is always reachable", function()
        local ns = boot()
        S.invisible = { player = true }; S.outOfRange.player = true; S.spellOut = { player = true }
        refresh()
        assertEquals(st(buff("player")).attrs.type1, "macro")
    end)
    it("unknown reachability counts as reachable: secret results", function()
        local ns = boot()
        S.secretRange = true
        refresh()
        for _, u in ipairs({ "party1", "party2" }) do
            assertEquals(st(buff(u)).attrs.type1, "macro", u); assertEquals(buff(u):GetAlpha(), 1)
            assertFalse(buff(u).unreachable == true)
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("unknown reachability counts as reachable: erroring range APIs", function()
        local ns = boot()
        S.rangeError = true
        refresh()
        for _, u in ipairs({ "party1", "party2" }) do assertEquals(st(buff(u)).attrs.type1, "macro", u) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("strict even when 'unknown counts as reachable': the armed macro still names the unit, never falls back", function()
        local ns = boot()
        S.secretRange = true; refresh()
        assertButtonSafe(buff("party1"), "party1", "secret range")
        S.secretRange = false; S.rangeError = true; refresh()
        assertButtonSafe(buff("party2"), "party2", "error range")
    end)
    it("unreachable unit-frame click bindings still cannot cast on the player (strict macro kept)", function()
        local ns = boot()
        S.invisible = { party1 = true }; S.outOfRange.party1 = true
        refresh()
        assertButtonSafe(unitButton("party1"), "party1", "frame of an unreachable member")
    end)
    it("the unit frame itself dims out-of-range members (visual)", function()
        local ns = boot()
        ns.db.frames.range.style = "dim"
        S.outOfRange.party2 = true; ns.UnitFrames:UpdateRange(unitButton("party2"))
        assertEquals(unitButton("party2"):GetAlpha(), ns.db.frames.range.dim / 100)
    end)
end)

-- ======================================================================== 3 / 4. smart and tank buttons
describe("strict: smart button skips unreachable units; tank button disarms", function()
    local function smartAttrs() local a = st(frameNamed("HealerForeverSmartBuff")).attrs; return a.type, a.unit, a.macrotext end
    local function unreachable(u) S.outOfRange[u] = true end
    local function reachableAgain(u) S.outOfRange[u] = nil end
    it("picks the next reachable unit in priority order and never an unreachable one", function()
        local ns = boot()
        refresh()
        local _, u1 = smartAttrs(); assertEquals(u1, "party1", "tank first")
        unreachable("party1"); refresh()
        local t2, u2, m2 = smartAttrs(); assertEquals(u2, "party2"); assertEquals(t2, "macro")
        assertEquals(#macroProblems(m2, "party2"), 0)
        unreachable("party2"); refresh()
        assertEquals(select(2, smartAttrs()), "party3")
        unreachable("party3"); refresh()
        assertEquals(select(2, smartAttrs()), "party4")
        unreachable("party4"); refresh()
        local _, u5 = smartAttrs(); assertEquals(u5, "player", "only the player is reachable")
        reachableAgain("party2"); refresh()
        assertEquals(select(2, smartAttrs()), "party2")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("disarms completely when nothing reachable is pending", function()
        local ns = boot()
        -- the player already has their buff; every other unit is unreachable
        S.auras.player = { { spellId = 1, name = ns.Classes.BUFFS[ns.Presets.ResolveBuff(ns.db.presets[ns.db.activePreset], "PALADIN", ns.Roles.Get("player"), true)].names[1],
            expirationTime = 0, duration = 0, isHelpful = true, sourceUnit = "player", auraInstanceID = 1 } }
        for _, u in ipairs({ "party1", "party2", "party3", "party4" }) do unreachable(u) end
        refresh()
        local t, u, m = smartAttrs()
        assertNil(t); assertNil(u); assertNil(m)
        assertEquals(st(frameNamed("HealerForeverSmartBuff")).attrs.macrotext, nil)
        for _, uu in ipairs({ "party1", "party2", "party3", "party4" }) do reachableAgain(uu) end
        refresh()
        assertNotNil(select(1, smartAttrs()), "re-arms when units come back")
    end)
    it("a role buff on an unreachable tank is skipped by the smart button too", function()
        local ns = boot({ book = { names = { [900002] = "Oath of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 900002 } } } } })
        ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true }, true)
        ns:Changed("presets"); refresh()
        local _, u, m = smartAttrs(); assertEquals(u, "party1"); assertNotNil(m:find("Oath of Light", 1, true))
        unreachable("party1"); refresh()
        local _, u2, m2 = smartAttrs()
        assertTrue(u2 ~= "party1", "never the unreachable tank"); assertEquals(#macroProblems(m2, u2), 0)
    end)
    it("tank button disarms while the tank is unreachable and re-arms afterwards", function()
        local ns = boot({ book = { names = { [900002] = "Oath of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 900002 } } } } })
        ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true }, true)
        ns:Changed("presets"); refresh()
        local tank = frameNamed("HealerForeverTankBuff")
        assertEquals(st(tank).attrs.type, "macro"); assertEquals(st(tank).attrs.unit, "party1")
        assertEquals(#macroProblems(st(tank).attrs.macrotext, "party1"), 0)
        for _, cause in ipairs({ function() S.invisible = { party1 = true } end, function() S.invisible = {}; S.outOfRange.party1 = true end,
            function() S.outOfRange.party1 = nil; S.spellOut = { party1 = true } end }) do
            cause(); refresh()
            assertNil(st(tank).attrs.type); assertNil(st(tank).attrs.macrotext); assertNil(st(tank).attrs.unit)
            local lines = {}
            mock.printed = {}
            for _, f in pairs(_G.SlashCmdList) do f("debug buffs") end
            assertNotNil(table.concat(mock.printed, "\n"):find("tank is out of range", 1, true))
        end
        S.invisible = {}; S.outOfRange.party1 = nil; S.spellOut = {}; refresh()
        assertEquals(st(tank).attrs.type, "macro"); assertEquals(st(tank).attrs.unit, "party1")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("two tanks: the reachable one is targeted when the first is unreachable", function()
        local party = deepcopy(PARTY); party.party2 = unit("Tank2", "PALADIN", "TANK")
        local ns = boot({ party = party, book = { names = { [900002] = "Oath of Light" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 900002 } } } } })
        ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true }, false)
        ns:Changed("presets"); refresh()
        unreachable("party1"); refresh()
        assertEquals(st(frameNamed("HealerForeverTankBuff")).attrs.unit, "party2")
    end)
end)

-- ======================================================================== 5. combat
describe("strict: nothing touches attributes in combat; changes apply afterwards", function()
    it("range changes, auras, roster and binding edits during combat leave all attributes untouched", function()
        local ns = boot()
        local function snapshot()
            local out = {}
            for _, f in ipairs(mock.frames) do
                if st(f).secure then
                    local a = {}
                    for k, v in pairs(st(f).attrs) do a[k] = v end
                    out[f] = a
                end
            end
            return out
        end
        local before = snapshot()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local n0, v0 = #mock.calls, #mock.violations
        S.outOfRange.party1 = true; S.invisible = { party2 = true }
        ns.db.bindings["|1"] = { type = "spell", spell = "Changed In Combat" }
        ns:Changed("bindings")
        mock.fire("UNIT_IN_RANGE_UPDATE", "party1"); mock.fire("UNIT_AURA", "party3"); mock.fire("GROUP_ROSTER_UPDATE")
        mock.flushTimers(); mock.tick(); mock.runOnUpdate(3, 0.5)
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.secure and c.method == "SetAttribute", "SetAttribute on secure frame in combat: " .. tostring(c.frame))
        end
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, 0)
        local after = snapshot()
        for f, a in pairs(before) do
            for k, v in pairs(a) do assertEquals(after[f][k], v, tostring(st(f).name) .. " attribute " .. tostring(k) .. " changed in combat") end
            for k in pairs(after[f]) do assertNotNil(a[k], tostring(st(f).name) .. " gained attribute " .. tostring(k) .. " in combat") end
        end
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        assertNotNil(tostring(st(unitButton("party1")).attrs.macrotext1):find("Changed In Combat", 1, true), "binding change applied after combat")
        assertTrue(buff("party1").unreachable, "range change applied after combat")
        assertNil(st(buff("party1")).attrs.macrotext1)
        assertTrue(buff("party2").unreachable)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secret range values in combat never error and never arm anything new", function()
        local ns = boot()
        S.combat = true; S.secret = true; S.secretRange = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.fire("UNIT_IN_RANGE_UPDATE", "party1"); mock.tick(); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
    end)
end)

-- ======================================================================== 6. length
describe("strict: macrotext stays under 255 characters", function()
    it("for the longest plausible names, every unit token and every res combination", function()
        local ns = boot()
        local long = string.rep("W", 60)
        for _, u in ipairs({ "player", "party1", "party4", "partypet4", "raid40", "nameplate12" }) do
            for _, res in ipairs({ false, "Ancestral Spirit" }) do
                for _, ooc in ipairs({ false, "Revive" }) do
                    local t = ns.Bindings.BuildMacroText(u, "Greater Blessing of Kings Extended Name", res or nil, ooc or nil)
                    assertTrue(#t < 255, u .. " " .. #t)
                end
            end
        end
        assertTrue(#ns.Bindings.BuildMacroText("partypet4", long, "Ancestral Spirit", "Revive") > 100)
    end)
    it("for every real spell name the addon knows about, per class", function()
        local ns = boot()
        local worst = 0
        for _, class in ipairs(CLASSES) do
            local names = {}
            local data = ns.Classes.DATA[class]
            for _, s in ipairs(data and data.heals or {}) do names[#names + 1] = s.name end
            for _, s in ipairs(data and data.utility or {}) do names[#names + 1] = s.name end
            for _, s in ipairs(data and data.buffSpells or {}) do names[#names + 1] = s.name end
            for _, key in ipairs(data and data.blessings or {}) do names[#names + 1] = ns.Classes.BUFFS[key].name; names[#names + 1] = ns.Classes.BUFFS[key].greater end
            local res, ooc = ns.Classes.GetResSpell(class), ns.Classes.GetResSpellOutOfCombat(class)
            for _, n in ipairs(names) do
                for _, u in ipairs({ "party4", "partypet4" }) do
                    local t = ns.Bindings.BuildMacroText(u, n, res, ooc)
                    worst = math.max(worst, #t)
                    assertTrue(#t < 255, class .. " " .. n .. " " .. #t)
                end
            end
        end
        assertTrue(worst > 0)
    end)
    it("the generated target+res macro stays under the limit as well", function()
        local ns = boot()
        for _, u in ipairs(ALL_UNITS) do
            assertTrue(#ns.Bindings.BuildTargetMacro(u, "Ancestral Spirit", "Revive") < 255)
        end
    end)
    it("all macros actually produced by the running addon are under the limit", function()
        local ns = boot({ class = "DRUID" })
        ns.db.bindings = fullBindings(); ns:Changed("bindings"); mock.flushTimers()
        for _, u in ipairs(ALL_UNITS) do for _, m in ipairs(macrosOf(unitButton(u))) do assertTrue(#m.text < 255, m.name .. " " .. #m.text) end end
    end)
end)

-- ======================================================================== 7. left = single, right = Greater
describe("strict: left click casts the single blessing, right click the Greater one", function()
    for _, caster in ipairs({ "PALADIN", "PRIEST", "MAGE", "DRUID" }) do
        it("for every " .. caster .. " buff: left casts the single spell, right the group spell (or the single when there is none)", function()
            local ns = boot({ class = caster })
            for _, key in ipairs(ns.Classes.CatalogBuffs(caster)) do
                local def = ns.Classes.BUFFS[key]
                local preset = ns.db.presets[ns.db.activePreset]
                preset.map.WARRIOR = { DEFAULT = { key } }
                ns:Changed("presets"); refresh()
                local b = buff("party1")
                assertEquals(b.buffKey, key)
                assertEquals(st(b).attrs.macrotext1, ns.Bindings.BuildMacroText("party1", def.name, nil), key)
                assertEquals(st(b).attrs.macrotext2, ns.Bindings.BuildMacroText("party1", def.groupSpell or def.name, nil), key)
                assertNotNil(st(b).attrs.macrotext1:find(def.name, 1, true)); assertNotNil(st(b).attrs.macrotext2:find(def.groupSpell or def.name, 1, true))
                assertButtonSafe(b, "party1", key)
            end
        end)
    end
    it("only one of the two known: both clicks use it", function()
        local ns = boot({ setup = function()
            mock.setGlobal("IsPlayerSpell", function() return false end); mock.setGlobal("IsSpellKnownOrOverridesKnown", function() return false end)
            mock.setGlobal("IsSpellKnown", function() return false end)
            mock.setGlobal("C_SpellBook", { IsSpellKnown = function() return false end })
        end })
        local def = ns.Classes.BUFFS[buff("party1").buffKey]
        _G.IsPlayerSpell = function(id) return id == S.spellByName[def.name] end
        mock.fire("SPELLS_CHANGED"); mock.flushTimers(); mock.tick()
        local b = buff("party1")
        assertEquals(st(b).attrs.macrotext1, ns.Bindings.BuildMacroText("party1", def.name, nil))
        assertEquals(st(b).attrs.macrotext2, ns.Bindings.BuildMacroText("party1", def.name, nil))
    end)
    it("buttons register AnyDown + AnyUp so the key-down option cannot double-cast (secure action buttons)", function()
        local ns = boot()
        local b = buff("party1")
        local found = false
        for _, c in ipairs(mock.calls) do if c.obj == b and c.method == "RegisterForClicks" and c.args[1] == "AnyDown" then found = true end end
        assertTrue(found)
    end)
end)

-- ======================================================================== 8. roster changes
describe("strict: roster changes rebuild the macros with the right unit tokens", function()
    it("every button's macros always name only its own unit through solo -> 4 -> 2 -> 0 -> 3 changes", function()
        local ns = boot({ group = 4 })
        for _, n in ipairs({ 4, 0, 2, 1, 3, 4, 0 }) do
            mock.setGroup(n)
            mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("UNIT_PET", "player"); mock.fire("PLAYER_ROLES_ASSIGNED"); mock.flushTimers(); mock.tick(); mock.flushTimers()
            ns:Changed("bindings"); mock.flushTimers()
            for _, u in ipairs(ALL_UNITS) do assertButtonSafe(unitButton(u), u, "roster " .. n .. " " .. u) end
            for _, u in ipairs(MEMBERS) do
                for _, b in ipairs({ buff(u), extra(u) }) do
                    if st(b).attrs.macrotext1 then assertButtonSafe(b, u, "roster " .. n .. " " .. tostring(st(b).name)) end
                end
            end
            local sm = st(frameNamed("HealerForeverSmartBuff")).attrs
            if sm.macrotext then assertEquals(#macroProblems(sm.macrotext, sm.unit), 0, sm.macrotext) end
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("sort modes and layout reordering never change which unit a button's macros name", function()
        local ns = boot({ group = 4 })
        for _, mode in ipairs({ "role", "class", "name", "manual" }) do
            ns.db.frames.sortMode = mode; ns:Changed("frames"); mock.flushTimers()
            for _, u in ipairs(ALL_UNITS) do assertButtonSafe(unitButton(u), u, mode .. " " .. u) end
        end
        ns.db.frames.order = { "party4", "party3", "party2", "party1", "player" }
        ns:Changed("frames"); mock.flushTimers()
        for _, u in ipairs(ALL_UNITS) do assertButtonSafe(unitButton(u), u, "reordered " .. u) end
    end)
    it("a member whose class changes (new player in the slot) gets macros rebuilt for the slot's token and role", function()
        local ns = boot({ group = 4 })
        S.units.party1 = unit("Newbie", "DRUID", "HEALER")
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        assertButtonSafe(buff("party1"), "party1", "new member")
        assertButtonSafe(unitButton("party1"), "party1", "new member frame")
    end)
    it("after combat ends, a roster change that happened during combat is reflected", function()
        local ns = boot({ group = 4 })
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        S.units.party3 = unit("Swapped", "PRIEST", "HEALER")
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        for _, u in ipairs(ALL_UNITS) do assertButtonSafe(unitButton(u), u, "after combat " .. u) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("res changes (spell becomes unknown) rebuild the macros without ever dropping the explicit unit", function()
        local ns = boot({ group = 4 })
        _G.IsPlayerSpell = function() return false end; _G.IsSpellKnown = function() return false end
        _G.C_SpellBook.IsSpellKnown = function() return false end
        S.units.player.class = "PALADIN"
        ns.Spells.knownNames = {}
        mock.fire("SPELLS_CHANGED"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        for _, u in ipairs(ALL_UNITS) do assertButtonSafe(unitButton(u), u, "no res " .. u) end
        _G.IsPlayerSpell = function() return true end
        mock.fire("SPELLS_CHANGED"); mock.flushTimers()
        for _, u in ipairs(ALL_UNITS) do assertButtonSafe(unitButton(u), u, "res again " .. u) end
    end)
end)
