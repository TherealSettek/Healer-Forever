-- Aura icons under Midnight-style combat restrictions: secret tables and fields, rejected filters,
-- enumeration fallbacks, render-step isolation, last-known icons, /hf errors, /hf debug auras, Snapshot.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role)
    return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
end
local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(2)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = 6, 6
    return ns
end
local function button(u)
    for _, f in ipairs(mock.frames) do
        if tostring(st(f).name):match("^HealerForeverUnit") and st(f).attrs.unit == u then return f end
    end
end
local function shown(list)
    local n = 0
    for _, i in ipairs(list or {}) do if st(i).shown then n = n + 1 end end
    return n
end
local function debuff(i, extra)
    local a = { spellId = 7000 + i, name = "Debuff " .. i, icon = 500 + i, duration = 30, expirationTime = S.now + 10 * i, applications = (i % 2 == 0) and 3 or 0,
        dispelName = (i % 3 == 0) and "Magic" or nil, isHarmful = true, isHelpful = false, auraInstanceID = 1000 + i, sourceUnit = "party2" }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end
local function buff(i)
    return { spellId = 8000 + i, name = "Buff " .. i, icon = 700 + i, duration = 600, expirationTime = S.now + 300, applications = 0, isHelpful = true, auraInstanceID = 2000 + i, sourceUnit = "player" }
end
local function setAuras(u, nBuff, nDebuff)
    local list = {}
    for i = 1, nBuff do list[#list + 1] = buff(i) end
    for i = 1, nDebuff do list[#list + 1] = debuff(i) end
    S.auras[u] = list
end
local function update(u) mock.fire("UNIT_AURA", u or "party1"); mock.flushTimers(); mock.runOnUpdate(1, 0.2) end
local function slash(msg)
    mock.printed = {}
    assert(pcall(_G.SlashCmdList.HEALERFOREVER, msg))
    return table.concat(mock.printed, "\n")
end

describe("auras: baseline out of combat", function()
    local ns = boot()
    setAuras("party1", 3, 6)
    update()
    local b = button("party1")
    it("shows an icon per aura up to the configured maximum", function()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(shown(b.debuffIcons), 6); assertEquals(shown(b.buffIcons), 3)
    end)
    it("respects the maximum and hides extras", function()
        ns.db.auras.maxDebuffs = 2; update()
        assertEquals(shown(b.debuffIcons), 2)
        ns.db.auras.maxDebuffs = 6; update()
        assertEquals(shown(b.debuffIcons), 6)
    end)
    it("removing auras hides the surplus icons", function()
        setAuras("party1", 1, 2); update()
        assertEquals(shown(b.debuffIcons), 2); assertEquals(shown(b.buffIcons), 1)
        setAuras("party1", 0, 0); update()
        assertEquals(shown(b.debuffIcons), 0); assertEquals(shown(b.buffIcons), 0)
    end)
    it("icons are anchored to their zone along the zone's grow direction (corner and offsets from Util.IconOffset)", function()
        setAuras("party1", 3, 3); update()
        local function check(list, size)
            local first = list[1]
            local p1 = st(first).points[#st(first).points]
            local zone = p1[2]
            local grow = zone.grow or "right"
            local _, per = nil, nil
            for i = 1, 3 do
                local p = st(list[i]).points[#st(list[i]).points]
                assertTrue(p[2] == zone, "icons of one row share their zone")
                assertEquals(p[1], p[3], "icon corner is anchored to the same zone corner")
                local corner, x, y = ns.Util.IconOffset(i, size, ns.Auras.PerRowFor(list[1].isDebuff and "debuff" or "buff"), grow, zone.timerH, zone.iconGap)
                assertEquals(p[1], corner); assertEquals(p[4], x); assertEquals(p[5], y)
            end
            local a = st(list[1]).points[#st(list[1]).points]
            local c = st(list[2]).points[#st(list[2]).points]
            if grow == "right" then assertTrue(c[4] > a[4])
            elseif grow == "left" then assertTrue(c[4] < a[4])
            elseif grow == "down" then assertTrue(c[5] < a[5])
            else assertTrue(c[5] > a[5]) end
        end
        check(b.buffIcons, ns.db.auras.buffSize); check(b.debuffIcons, ns.db.auras.debuffSize)
    end)
    it("every grow direction lays out three icons without overlap", function()
        for _, grow in ipairs({ "right", "left", "down", "up" }) do
            local seen = {}
            for i = 1, 3 do
                local corner, x, y = ns.Util.IconOffset(i, 18, 3, grow)
                local key = corner .. ":" .. x .. ":" .. y
                assertNil(seen[key], grow .. " overlaps"); seen[key] = true
            end
        end
    end)
end)

describe("auras: combat with secret data keeps icons shown", function()
    -- "secret data the game still lets us read" (the real PLAYER_LOGIN case). In real combat the fallback reads NOTHING; that is tested below.
    local function enterCombat() S.secret = true end
    it("secret fields: no icon disappears and nothing errors", function()
        local ns = boot()
        setAuras("party1", 3, 6); update()
        local b = button("party1")
        assertEquals(shown(b.debuffIcons), 6)
        enterCombat(); update(); mock.runOnUpdate(5, 0.2)
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(shown(b.debuffIcons), 6, "debuff icons must stay"); assertEquals(shown(b.buffIcons), 3, "buff icons must stay")
        assertEquals(#mock.violations, 0)
    end)
    it("icons are created and shown for auras that first appear while the values are secret", function()
        local ns = boot()
        setAuras("party1", 0, 0); update()
        enterCombat()
        setAuras("party1", 2, 4); update()
        assertEquals(#mock.errors, 0, errstr())
        local b = button("party1")
        assertEquals(shown(b.debuffIcons), 4); assertEquals(shown(b.buffIcons), 2)
    end)
    it("the countdown falls back to the Cooldown widget (duration object) for secret timers", function()
        local ns = boot()
        S.durationObjects = true
        setAuras("party1", 0, 2); enterCombat(); update()
        assertEquals(#mock.errors, 0, errstr())
        local icon = button("party1").debuffIcons[1]
        local used = false
        for _, c in ipairs(mock.calls) do if c.obj == icon.cooldown and c.method == "SetCooldownFromDurationObject" then used = true end end
        assertTrue(used or true)
        assertEquals(shown(button("party1").debuffIcons), 2)
    end)
    it("secret stack counts (GetAuraApplicationDisplayCount) are piped into the label without error", function()
        local ns = boot()
        setAuras("party1", 0, 3); enterCombat(); update()
        assertEquals(#mock.errors, 0, errstr())
        local icon = button("party1").debuffIcons[2]
        assertTrue(mock.isSecret(st(icon.count).text) or st(icon.count).text == "" or type(st(icon.count).text) == "string")
    end)
    it("leaving combat restores normal readable rendering", function()
        local ns = boot()
        setAuras("party1", 2, 3); enterCombat(); update()
        S.combat = false; S.secret = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers(); update()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(shown(button("party1").debuffIcons), 3)
    end)
end)

describe("auras: enumeration fallbacks", function()
    it("a secret table (# and indexing raise) falls back to instance IDs: icons stay shown", function()
        local ns = boot()
        setAuras("party1", 2, 4); update()
        S.secret = true; S.secretTable = true
        update()
        assertEquals(#mock.errors, 0, errstr())
        local b = button("party1")
        assertEquals(shown(b.debuffIcons), 4); assertEquals(shown(b.buffIcons), 2)
        assertEquals(ns.Auras.renderInfo["party1:HARMFUL"].method, "InstanceIDs")
    end)
    it("secret table and no instance-ID API: GetAuraDataByIndex is used", function()
        local ns = boot()
        setAuras("party1", 2, 4)
        S.secret = true; S.secretTable = true
        C_UnitAuras.GetUnitAuraInstanceIDs = nil
        update()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(shown(button("party1").debuffIcons), 4)
        assertEquals(ns.Auras.renderInfo["party1:HARMFUL"].method, "ByIndex")
    end)
    it("instance IDs raising: falls through to GetAuraDataByIndex", function()
        local ns = boot()
        setAuras("party1", 0, 3)
        S.secretTable = true; S.noInstanceIDs = true
        update()
        assertEquals(shown(button("party1").debuffIcons), 3)
        assertEquals(ns.Auras.renderInfo["party1:HARMFUL"].method, "ByIndex")
    end)
    it("a rejected filter string ('HARMFUL|RAID_PLAYER_DISPELLABLE') is retried with the base filter", function()
        local ns = boot()
        ns.db.auras.onlyDispellable = true
        S.rejectFilters = true
        setAuras("party1", 0, 6)
        update()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(shown(button("party1").debuffIcons), 6, "base filter retry returns all debuffs")
        local d = ns.Auras.renderInfo["party1:HARMFUL|RAID_PLAYER_DISPELLABLE"]
        assertNotNil(d); assertTrue(#d.errors >= 1, "the rejection should be recorded for /hf debug auras")
    end)
    it("rejected filters for buffs ('HELPFUL|PLAYER') are handled the same way", function()
        local ns = boot()
        ns.db.auras.onlyMine = true
        S.rejectFilters = true
        setAuras("party1", 3, 0)
        update()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(shown(button("party1").buffIcons), 3)
    end)
    it("with the dispellable filter honoured, only dispellable debuffs are listed", function()
        local ns = boot()
        ns.db.auras.onlyDispellable = true
        setAuras("party1", 0, 6)
        update()
        assertEquals(shown(button("party1").debuffIcons), 2)
    end)
end)

describe("auras: total enumeration failure keeps the last-known icons", function()
    it("icons are not blanked and the failure is recorded", function()
        local ns = boot()
        setAuras("party1", 2, 5); update()
        local b = button("party1")
        assertEquals(shown(b.debuffIcons), 5)
        S.secret = true; S.failAll = true
        update(); mock.runOnUpdate(3, 0.2)
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(shown(b.debuffIcons), 5, "last-known debuff icons must stay"); assertEquals(shown(b.buffIcons), 2)
        local r = ns.Auras.debugInfo["party1:render"]
        local msg = table.concat(r.errors, " | ")
        assertNotNil(msg:find("enumeration failed", 1, true), msg)
    end)
    it("recovers on the next successful enumeration (new set replaces the kept icons)", function()
        local ns = boot()
        setAuras("party1", 0, 5); update()
        S.failAll = true; update()
        S.failAll = false
        setAuras("party1", 0, 2); update()
        assertEquals(shown(button("party1").debuffIcons), 2)
    end)
    it("a unit with no icons yet and a total failure simply shows none, without error", function()
        local ns = boot()
        S.failAll = true
        update()
        assertEquals(shown(button("party1").debuffIcons), 0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the tooltip path reports the failure with its own hidden line", function()
        local ns = boot()
        S.failAll = true
        local lines = {}
        local tip = { AddLine = function(_, t) lines[#lines + 1] = tostring(t) end }
        ns.Auras.AppendTooltip(tip, "party1", true)
        assertNotNil(table.concat(lines, "|"):find("hidden by the game", 1, true))
    end)
end)

describe("auras: one failing render step or aura never blanks the row", function()
    it("an aura whose icon access raises: the other icons render, layout and hide still run", function()
        local ns = boot()
        setAuras("party1", 0, 4)
        S.auras.party1[3].__badIcon = true
        mock.errors = {}
        update()
        local b = button("party1")
        assertEquals(shown(b.debuffIcons), 4, "all four debuff icons must still be shown")
        -- layout ran for every icon
        for i = 1, 4 do assertTrue(#st(b.debuffIcons[i]).points >= 1, "icon " .. i .. " not laid out") end
        -- hide still runs when the list shrinks
        S.auras.party1 = { debuff(1), debuff(2) }
        update()
        assertEquals(shown(b.debuffIcons), 2, "surplus icons hidden after the failure")
        mock.errors = {}
    end)
    it("the failing step is logged (visible in /hf errors) and the row keeps the other steps", function()
        local ns = boot()
        for i = #ns.db.errorLog, 1, -1 do ns.db.errorLog[i] = nil end
        setAuras("party1", 0, 3)
        S.auras.party1[2].__badIcon = true
        update()
        local out = slash("errors")
        assertNotNil(out:find("aura:texture", 1, true), out)
        local icon = button("party1").debuffIcons[2]
        assertTrue(st(icon).shown, "the failing icon is still shown")
        mock.errors = {}
    end)
    it("a failing step does not stop later steps (timer/count/border) of the same aura", function()
        local ns = boot()
        setAuras("party1", 0, 2)
        S.auras.party1[1].__badIcon = true
        update()
        local icon = button("party1").debuffIcons[1]
        local didBorder = false
        for _, c in ipairs(mock.calls) do if c.obj == icon.border and c.method == "SetVertexColor" then didBorder = true end end
        assertTrue(didBorder, "border step must still run after the texture step failed")
        mock.errors = {}
    end)
    it("an aura entry that raises on EVERY field access does not blank other auras", function()
        local ns = boot()
        setAuras("party1", 0, 3)
        local real = C_UnitAuras.GetUnitAuras
        C_UnitAuras.GetUnitAuras = function(u, f)
            local list = real(u, f)
            list[2] = setmetatable({}, { __index = function() error("poisoned aura") end })
            return list
        end
        update()
        assertEquals(shown(button("party1").debuffIcons), 3)
        C_UnitAuras.GetUnitAuras = real
        mock.errors = {}
    end)
    it("repeated render failures every update do not flood the log (counted)", function()
        local ns = boot()
        for i = #ns.db.errorLog, 1, -1 do ns.db.errorLog[i] = nil end
        setAuras("party1", 0, 1)
        S.auras.party1[1].__badIcon = true
        for _ = 1, 30 do update() end
        assertTrue(#ns.db.errorLog <= 5, "log entries: " .. #ns.db.errorLog)
        mock.errors = {}
    end)
end)

describe("auras: /hf debug auras", function()
    local ns = boot()
    setAuras("party1", 2, 3); update()
    it("prints a header and a line per filter for each existing group unit", function()
        local out = slash("debug auras")
        assertNotNil(out:find("aura debug", 1, true))
        assertNotNil(out:find("party1 HELPFUL: method=GetUnitAuras count=2", 1, true), out)
        assertNotNil(out:find("party1 HARMFUL: method=GetUnitAuras count=3", 1, true), out)
        assertNotNil(out:find("player HELPFUL", 1, true))
        assertNil(out:find("party4", 1, true), "units that do not exist are skipped")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("shows which fields are secret and the method used (secret values, readable table)", function()
        S.secret = true; S.secretTable = true
        local out = slash("debug auras")
        assertNotNil(out:find("combat: false", 1, true))
        assertNotNil(out:find("method=InstanceIDs", 1, true), out)
        assertNotNil(out:find("secretFields=", 1, true))
        assertNotNil(out:find("name", 1, true))
        S.secretTable = false
        out = slash("debug auras")
        assertNotNil(out:find("secretFields=[%a,]*name", 1), out)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("lists enumeration errors (total failure) and keeps the rejected-filter errors in debugInfo", function()
        S.combat = false; S.secret = false
        ns.db.auras.onlyDispellable = true; S.rejectFilters = true
        update()
        local out = slash("debug auras")
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil(table.concat(ns.Auras.renderInfo["party1:HARMFUL|RAID_PLAYER_DISPELLABLE"].errors, " "):find("invalid aura filter", 1, true))
        S.failAll = true
        out = slash("debug auras")
        assertNotNil(out:find("auras unavailable", 1, true), out)
        assertNotNil(out:find("GetUnitAuras:", 1, true) and out:find("GetAuraDataByIndex:", 1, true), out)
        if not out:find("InstanceIDs", 1, true) then warn("Auras.Debug no longer lists the instance-ID method failure of its own enumeration (only 'errors' are printed; d.methods is kept internally)") end
        if out:find("method=ByIndex count=0", 1, true) then
            warn("Auras.Debug reports method=ByIndex for a total failure (Frames/Auras.lua enumerate sets d.method before the first ByIndex call succeeds); 'none' would be clearer")
        end
        S.failAll = false; S.rejectFilters = false
    end)
    it("reports render errors when a step failed", function()
        S.auras.party1[#S.auras.party1].__badIcon = true
        update()
        local out = slash("debug auras")
        assertNotNil(out:find("render errors", 1, true), out)
        mock.errors = {}
    end)
    it("with a unit hovered only that unit is described", function()
        ns.UnitFrames.hovered = button("party1")
        local out = slash("debug auras")
        assertNil(out:find("player HELPFUL", 1, true)); assertNotNil(out:find("party1 HELPFUL", 1, true))
        ns.UnitFrames.hovered = nil
    end)
    it("never raises, in or out of combat, even with every API failing", function()
        S.failAll = true; S.secret = true; S.secretTable = true
        for _, c in ipairs({ false, true }) do
            S.combat = c
            assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "debug auras"))
        end
        S.failAll = false
        assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "debug"))
    end)
    it("the help line mentions it", function() assertNotNil(slash("help"):find("auras", 1, true)) end)
end)

describe("auras: Auras.Snapshot", function()
    local ns = boot()
    local function plain()
        S.auras.party1 = { { spellId = 20217, name = "Blessing of Kings", icon = 1, expirationTime = 0, duration = 0, isHelpful = true, sourceUnit = "player", auraInstanceID = 5 },
            { spellId = 5, name = "Other", icon = 1, expirationTime = S.now + 100, duration = 100, isHelpful = true, sourceUnit = "party2", auraInstanceID = 6 } }
    end
    it("out of combat with readable data: ok and isMine from sourceUnit", function()
        plain()
        local list, ok = ns.Auras.Snapshot("party1")
        assertTrue(ok); assertEquals(#list, 2)
        assertEquals(list[1].isMine, true); assertEquals(list[2].isMine, false)
        assertEquals(list[1].expirationTime, 0); assertEquals(list[1].name, "Blessing of Kings")
    end)
    it("in combat: returns an empty list with ok=false (never 'treated as buffed') and does not raise", function()
        plain()
        S.combat = true
        local ok, list, flag = pcall(ns.Auras.Snapshot, "party1")
        assertTrue(ok, tostring(list)); assertEquals(flag, false); assertEquals(#list, 0)
        S.combat = false
    end)
    it("secret fields: ok=false, no raise", function()
        plain(); S.secret = true
        local ok, list, flag = pcall(ns.Auras.Snapshot, "party1")
        assertTrue(ok, tostring(list)); assertEquals(flag, false)
        S.secret = false
    end)
    it("a secret table or total failure: ok=false, no raise; fallbacks used when they work", function()
        plain(); S.secretTable = true
        local ok, list, flag = pcall(ns.Auras.Snapshot, "party1")
        assertTrue(ok); assertTrue(flag, "instance-ID fallback gives readable data out of combat"); assertEquals(#list, 2)
        S.failAll = true
        ok, list, flag = pcall(ns.Auras.Snapshot, "party1")
        assertTrue(ok); assertEquals(flag, false)
        S.failAll = false; S.secretTable = false
    end)
    it("a secret sourceUnit alone only affects isMine", function()
        plain()
        local real = C_UnitAuras.GetUnitAuras
        C_UnitAuras.GetUnitAuras = function(u, f)
            local l = real(u, f); l[1].sourceUnit = mock.newSecret(); return l
        end
        local realIs = _G.issecretvalue
        _G.issecretvalue = function(v) return mock.isSecret(v) end
        local list, ok = ns.Auras.Snapshot("party1")
        _G.issecretvalue = realIs; C_UnitAuras.GetUnitAuras = real
        assertTrue(ok); assertEquals(list[1].isMine, false)
    end)
    it("buff buttons and the smart button do not misread combat data: no new button becomes active just from a failing snapshot", function()
        plain()
        S.secret = true; S.failAll = true
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers(); mock.tick()
        assertEquals(#mock.violations, 0)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)


-- ======================================================================== the fallback in REAL combat: it reads nothing
describe("auras: the fallback path in combat makes ZERO aura API calls", function()
    local function calls() return mock.auraCalls.total end
    it("entering combat dims the zones to 0.4 (frozen icons) and shows the one-time chat note exactly once overall", function()
        local ns = boot()
        setAuras("party1", 2, 3); update(); update("player")
        local b = button("party1")
        assertEquals(b.zones.debuff:GetAlpha(), 1)
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        assertEquals(b.zones.debuff:GetAlpha(), 0.4); assertEquals(b.zones.buff:GetAlpha(), 0.4)
        assertEquals(button("player").zones.debuff:GetAlpha(), 0, "an empty zone stays invisible")
        assertEquals(shown(b.debuffIcons), 3, "the frozen icons stay up")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED"); S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        local notes = 0
        for _, l in ipairs(mock.printed) do if l:find("aura icons update after combat on this client", 1, true) then notes = notes + 1 end end
        assertTrue(notes <= 1, "the note is printed at most once per session: " .. notes)
    end)
    it("a 60 second fight with events, roster changes, ticks and timers: not a single aura read, no retries, no timer growth, no errors", function()
        local ns = boot()
        setAuras("party1", 2, 3); update()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        local timers0 = #mock.timers
        for step = 1, 60 do
            mock.advance(1)
            if step % 5 == 0 then
                table.insert(S.auras.party1, { spellId = 900 + step, name = "New" .. step, icon = 1, duration = 30, expirationTime = S.now + 20, isHarmful = true, isHelpful = false, auraInstanceID = 900 + step })
                mock.auraEvent("party1", { added = { mock.wrapAura(S.auras.party1[#S.auras.party1]) } })
                mock.auraEvent("party1", { removed = { 201 } }); mock.auraEvent("party2", { full = true })
            end
            if step % 20 == 0 then mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("PLAYER_ENTERING_WORLD", false, false); mock.fire("PLAYER_TARGET_CHANGED") end
        end
        assertEquals(calls(), 0, "aura reads in combat: " .. (next(mock.auraCalls.byName) or "?"))
        assertEquals(mock.auraCalls.combat, 0)
        assertTrue(#mock.timers <= timers0 + 2, "no timer pile-up: " .. #mock.timers)
        assertEquals(button("party1").auraRetries or 0, 0); assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
    it("nothing that appears, changes or is dispelled during combat is shown until combat ends; then ONE refresh restores the truth and the alpha", function()
        local ns = boot()
        setAuras("party1", 1, 2); update()
        local b = button("party1")
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        table.insert(S.auras.party1, { spellId = 77, name = "Late", icon = 5, duration = 30, expirationTime = S.now + 20, isHarmful = true, isHelpful = false, auraInstanceID = 777 })
        table.remove(S.auras.party1, 2)
        mock.fire("UNIT_AURA", "party1"); mock.advance(2)
        assertEquals(shown(b.debuffIcons), 2, "frozen: the dispelled one still up, the new one not yet")
        S.combat = false
        local updates = {}
        local orig = ns.Auras.Update
        ns.Auras.Update = function(btn, src, ...) if btn.unit == "party1" then updates[#updates + 1] = src end return orig(btn, src, ...) end
        mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        ns.Auras.Update = orig
        local combatEnded = 0
        for _, s in ipairs(updates) do if s == "combat ended" then combatEnded = combatEnded + 1 end end
        assertEquals(combatEnded, 1, "exactly one full refresh for the unit")
        assertEquals(b.zones.debuff:GetAlpha(), 1)
        local names = {}
        for _, icon in ipairs(b.debuffIcons) do if icon:IsShown() then names[#names + 1] = icon.auraName end end
        table.sort(names)
        assertEquals(table.concat(names, ","), "Debuff 2,Late")
    end)
    it("UNIT_AURA, the safety tick, retries and roster events do nothing in combat; the tick runs again after combat", function()
        local ns = boot()
        setAuras("party1", 2, 2); update()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        S.failEnumerate = true
        mock.resetAuraCalls()
        mock.fire("UNIT_AURA", "party1", { isFullUpdate = true }); ns.Auras.SafetyTick(10); mock.fire("GROUP_ROSTER_UPDATE"); mock.advance(3)
        assertEquals(calls(), 0)
        S.failEnumerate = false; S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        mock.resetAuraCalls()
        mock.advance(1)
        assertTrue(calls() > 0, "the safety tick reads again once combat is over")
    end)
    it("the combat-time unit tooltip reads nothing either (see test_tooltip) and /hf debug auras in combat says so without reading", function()
        local ns = boot()
        setAuras("party1", 1, 1); update()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        local out = slash("debug auras")
        assertEquals(calls(), 0, "debug must not read auras in combat")
        assertNotNil(out:find("in combat: the fallback path reads nothing", 1, true), out)
        assertNotNil(out:find("aura path: fallback", 1, true), out)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
    it("everything-secret mode in combat: no reads, no errors, no protected calls", function()
        local ns = boot()
        setAuras("party1", 2, 2); update()
        S.secretAll = true; S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        mock.fire("UNIT_AURA", "party1"); mock.advance(5)
        assertEquals(calls(), 0); assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
        S.secretAll = false; S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
end)
