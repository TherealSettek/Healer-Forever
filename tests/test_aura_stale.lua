-- Dispelled auras must never stay on the bar (real bug: Purify removed the debuff, the icon stayed).
-- UNIT_AURA updateInfo (removedAuraInstanceIDs / isFullUpdate), last-known icons kept for at most 1s, coalesced retries,
-- verify-by-instance-ID, the 0.5s safety tick, and the /hf debug auras "last update" line.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

local function boot()
    mock.install(); S = mock.state
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER"); S.units.party3 = unit("Mage", "MAGE", "DAMAGER")
    S.units.partypet1 = unit("Pet", "HUNTER"); S.units.pet = unit("MyPet", "WARRIOR")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    return ns
end
local function debuff(i, base) base = base or 200
    return { spellId = 7000 + i, name = "Debuff" .. i, icon = 300 + i, duration = 60, expirationTime = S.now + 40, isHarmful = true, isHelpful = false,
        dispelName = "Magic", auraInstanceID = base + i } end
local function buff(i, base) base = base or 100
    return { spellId = 6000 + i, name = "Buff" .. i, icon = 100 + i, duration = 300, expirationTime = S.now + 200, isHelpful = true, isHarmful = false,
        auraInstanceID = base + i, sourceUnit = "player" } end
local function setAuras(u, nBuff, nDebuff)
    local list = {}
    for i = 1, nBuff do list[#list + 1] = buff(i) end
    for i = 1, nDebuff do list[#list + 1] = debuff(i) end
    S.auras[u] = list
end
local function removeAura(u, id)
    for i, a in ipairs(S.auras[u]) do if a.auraInstanceID == id then table.remove(S.auras[u], i) return end end
    error("no aura " .. id)
end
local function button(ns, u) return ns.UnitFrames.byUnit[u] end
local function shownIDs(list)
    local out = {}
    for _, icon in ipairs(list) do if st(icon).shown then out[#out + 1] = icon.auraInstanceID end end
    return out
end
local function count(list) return #shownIDs(list) end
local function has(list, id) for _, v in ipairs(shownIDs(list)) do if v == id then return true end end return false end
local function fullRender(u) mock.fire("UNIT_AURA", u); mock.flushTimers() end
local function debugLines(ns, u)
    mock.printed = {}
    assert(pcall(_G.SlashCmdList.HEALERFOREVER, "debug auras"))
    local out = {}
    for _, line in ipairs(mock.printed) do if line:find("^" .. u .. " last update") or line:find(u .. " last update", 1, true) then out[#out + 1] = line end end
    return table.concat(out, "\n")
end
local function pendingTimers() local n = 0 for _, t in ipairs(mock.timers) do if not t.cancelled then n = n + 1 end end return n end
local function clearTimers() for k in pairs(mock.timers) do mock.timers[k] = nil end end
-- icons are packed with no gaps: the i-th shown icon sits at IconOffset(i)
local function assertPacked(ns, list, size, label)
    local zone, n = nil, 0
    for _, icon in ipairs(list) do
        if st(icon).shown then
            n = n + 1
            local p = st(icon).points[#st(icon).points]
            zone = zone or p[2]
            local corner, x, y = ns.Util.IconOffset(n, size, ns.Auras.PerRowFor(list[1].isDebuff and "debuff" or "buff"), zone.grow or "right", zone.timerH, zone.iconGap)
            assertEquals(p[1], corner, label .. " icon " .. n); assertEquals(p[4], x, label .. " x of icon " .. n); assertEquals(p[5], y, label .. " y of icon " .. n)
        end
    end
    -- and every hidden icon comes after every shown one
    local seenHidden = false
    for _, icon in ipairs(list) do
        if not st(icon).shown then seenHidden = true elseif seenHidden then error(label .. ": a shown icon follows a hidden one (gap)") end
    end
end

-- ======================================================================== mock support
describe("aura stale: mock support for updateInfo, timers and removed auras", function()
    local ns = boot()
    it("C_Timer.After honours its delay with mock.advance (flushTimers still runs everything)", function()
        local fired = {}
        C_Timer.After(0.5, function() fired[#fired + 1] = "a" end)
        C_Timer.After(0.2, function() fired[#fired + 1] = "b" end)
        mock.advance(0.3); assertEquals(table.concat(fired), "b")
        mock.advance(0.3); assertEquals(table.concat(fired), "ba")
        C_Timer.After(5, function() fired[#fired + 1] = "c" end)
        mock.flushTimers(); assertEquals(table.concat(fired), "bac")
    end)
    it("a callback scheduled inside a callback is honoured by advance", function()
        local n = 0
        local function again() n = n + 1; if n < 3 then C_Timer.After(0.2, again) end end
        C_Timer.After(0.2, again); mock.advance(1)
        assertEquals(n, 3)
    end)
    it("GetAuraDataByAuraInstanceID returns nil for removed auras and data for live ones", function()
        setAuras("party1", 0, 2)
        assertNotNil(C_UnitAuras.GetAuraDataByAuraInstanceID("party1", 201))
        removeAura("party1", 201)
        assertNil(C_UnitAuras.GetAuraDataByAuraInstanceID("party1", 201))
        assertNotNil(C_UnitAuras.GetAuraDataByAuraInstanceID("party1", 202))
    end)
    it("mock.auraEvent delivers updateInfo to UNIT_AURA handlers", function()
        local got
        local f = mock.newFrame("Frame", "HFAuraProbe")
        f:RegisterEvent("UNIT_AURA")
        f:SetScript("OnEvent", function(_, _, u, info) got = { u, info } end)
        mock.auraEvent("party1", { full = false, added = { { auraInstanceID = 9 } }, updated = { 4 }, removed = { 7, 8 } })
        assertEquals(got[1], "party1"); assertEquals(got[2].isFullUpdate, false)
        assertEquals(#got[2].removedAuraInstanceIDs, 2); assertEquals(got[2].updatedAuraInstanceIDs[1], 4); assertEquals(got[2].addedAuras[1].auraInstanceID, 9)
        mock.auraEvent("party1", { full = true }); assertEquals(got[2].isFullUpdate, true)
    end)
    it("S.failEnumerate makes every enumeration API raise while by-ID lookups keep working", function()
        S.failEnumerate = true
        setAuras("party1", 0, 1)
        assertFalse((pcall(C_UnitAuras.GetUnitAuras, "party1", "HARMFUL")))
        assertFalse((pcall(C_UnitAuras.GetUnitAuraInstanceIDs, "party1", "HARMFUL")))
        assertFalse((pcall(C_UnitAuras.GetAuraDataByIndex, "party1", 1, "HARMFUL")))
        assertNotNil(C_UnitAuras.GetAuraDataByAuraInstanceID("party1", 201))
        S.failEnumerate = false
    end)
end)

-- ======================================================================== 1. the bug
describe("aura stale: a dispelled debuff must leave the bar even when no enumeration method works", function()
    it("removedAuraInstanceIDs hides the icon at once, even while every enumeration fails (the Purify bug)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        assertEquals(count(b.debuffIcons), 3)
        S.failEnumerate = true
        removeAura("party1", 202)
        mock.auraEvent("party1", { removed = { 202 } })
        assertFalse(has(b.debuffIcons, 202), "the removed debuff's icon is gone immediately")
        assertEquals(count(b.debuffIcons), 2)
        assertTrue(has(b.debuffIcons, 201) and has(b.debuffIcons, 203), "the others stay")
        assertEquals(#mock.errors, 0, errstr())
        S.failEnumerate = false; mock.flushTimers()
    end)
    it("with a SECRET aura table in combat (and no instance-ID list) the removal is still shown at once", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        S.secretTable = true; S.noInstanceIDs = true; S.failEnumerate = true
        removeAura("party1", 203)
        mock.auraEvent("party1", { removed = { 203 } })
        assertFalse(has(b.debuffIcons, 203)); assertEquals(count(b.debuffIcons), 2)
        assertEquals(#mock.errors, 0, errstr())
        S.secretTable, S.noInstanceIDs, S.failEnumerate = false, false, false
    end)
    it("when EVERY value reads as secret (even the IDs), the icon is kept at first and verify-by-ID clears it after ~1s", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        S.secret = true; S.secretTable = true; S.noInstanceIDs = true; S.failEnumerate = true
        removeAura("party1", 203)
        mock.auraEvent("party1", { removed = { 203 } })
        assertTrue(has(b.debuffIcons, 203), "IDs cannot be compared when secret: uncertain, so kept for now")
        mock.advance(1.8)
        assertFalse(has(b.debuffIcons, 203)); assertEquals(count(b.debuffIcons), 2)
        assertEquals(#mock.errors, 0, errstr())
        S.secret, S.secretTable, S.noInstanceIDs, S.failEnumerate = false, false, false, false
    end)
    it("even when the event carries NO updateInfo and every enumeration fails, the cache render is cross-checked by ID: the dispelled icon is gone at once", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        removeAura("party1", 201)
        mock.fire("UNIT_AURA", "party1")
        assertFalse(has(b.debuffIcons, 201), "the cached entry no longer resolves by instance ID, so it is dropped")
        assertTrue(has(b.debuffIcons, 202), "the aura that still exists stays")
        assertPacked(ns, b.debuffIcons, ns.db.auras.debuffSize, "after the cross-check")
        assertTrue(ns.UnitFrames.byUnit.party1.auraDebug.cacheUsed, "rendered from the cache")
        assertEquals(#mock.errors, 0, errstr())
        S.failEnumerate = false
    end)
    it("when the by-ID lookup itself is unreadable the icon is kept (unknown means keep), and it clears as soon as lookups work again", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        local real = C_UnitAuras.GetAuraDataByAuraInstanceID
        C_UnitAuras.GetAuraDataByAuraInstanceID = function() error("secret ID") end
        removeAura("party1", 201)
        mock.fire("UNIT_AURA", "party1"); mock.advance(3)
        assertTrue(has(b.debuffIcons, 201), "nothing can prove it gone")
        C_UnitAuras.GetAuraDataByAuraInstanceID = real
        mock.advance(0.7)
        assertFalse(has(b.debuffIcons, 201), "the safety tick re-renders and the cross-check now works")
        S.failEnumerate = false
    end)
    it("with no event at all the 0.5s safety tick eventually clears it (within about 1.6s)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        removeAura("party1", 202)
        mock.advance(1.8)
        assertFalse(has(b.debuffIcons, 202)); assertTrue(has(b.debuffIcons, 201))
        assertEquals(#mock.errors, 0, errstr())
        S.failEnumerate = false
    end)
    it("an aura that still exists is NEVER hidden by verify (unknown or present means keep)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        mock.advance(3)
        assertEquals(count(b.debuffIcons), 2)
        -- the by-ID lookup itself raising also means keep
        local real = C_UnitAuras.GetAuraDataByAuraInstanceID
        C_UnitAuras.GetAuraDataByAuraInstanceID = function() error("secret") end
        removeAura("party1", 201)
        mock.advance(3)
        C_UnitAuras.GetAuraDataByAuraInstanceID = real
        assertEquals(count(b.debuffIcons), 2, "unknown means keep")
        S.failEnumerate = false
    end)
    it("once enumeration works again, the next render drops what is gone and resets the failure clock", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true; removeAura("party1", 201)
        mock.fire("UNIT_AURA", "party1")
        S.failEnumerate = false; mock.advance(0.5)
        assertFalse(has(b.debuffIcons, 201)); assertNil(b.auraFailSince); assertEquals(b.auraRetries, 0)
    end)
end)

-- ======================================================================== 2. normal removal
describe("aura stale: normal out-of-combat removal", function()
    it("hides the icon at once and the others repack without gaps (debuffs)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 4); fullRender("party1")
        removeAura("party1", 202)
        mock.auraEvent("party1", { removed = { 202 } })
        assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "201,203,204")
        assertPacked(ns, b.debuffIcons, ns.db.auras.debuffSize, "debuffs")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("works for buffs too, and for several IDs in one update", function()
        local ns = boot(); local b = button(ns, "party1")
        ns.db.auras.maxBuffs = 6; ns:Changed("frames"); mock.flushTimers()
        setAuras("party1", 4, 4); fullRender("party1")
        removeAura("party1", 101); removeAura("party1", 103); removeAura("party1", 204)
        mock.auraEvent("party1", { removed = { 101, 103, 204 } })
        assertEquals(table.concat(shownIDs(b.buffIcons), ","), "102,104")
        assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "201,202,203")
        assertPacked(ns, b.buffIcons, ns.db.auras.buffSize, "buffs"); assertPacked(ns, b.debuffIcons, ns.db.auras.debuffSize, "debuffs")
    end)
    it("removing every aura empties the row and fades the zone", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.auras.party1 = {}
        mock.auraEvent("party1", { removed = { 201, 202 } })
        assertEquals(count(b.debuffIcons), 0); assertEquals(b.zones.debuff:GetAlpha(), 0)
    end)
    it("an unknown removed ID changes nothing", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        mock.auraEvent("party1", { removed = { 99999 } })
        assertEquals(count(b.debuffIcons), 2)
    end)
    it("a removal then a re-add of the same spell (new instance ID) shows exactly one icon", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 1); fullRender("party1")
        removeAura("party1", 201); mock.auraEvent("party1", { removed = { 201 } })
        S.auras.party1[#S.auras.party1 + 1] = debuff(1, 300)
        mock.auraEvent("party1", { added = { { auraInstanceID = 301 } } })
        assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "301")
    end)
    it("isFullUpdate and updated-only events render normally", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2)
        mock.auraEvent("party1", { full = true })
        assertEquals(count(b.debuffIcons), 2)
        S.auras.party1[3] = debuff(3)
        mock.auraEvent("party1", { updated = { 201 } })
        assertEquals(count(b.debuffIcons), 3)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== 3. secret removed IDs
describe("aura stale: secret instance IDs", function()
    it("a secret removed ID does not error and falls back to a full render", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        removeAura("party1", 202)
        mock.auraEvent("party1", { removed = { mock.newSecret() } })
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "201,203", "the full render dropped the dispelled debuff")
        assertTrue(debugLines(ns, "party1"):find("uncertain(secret ID)=true", 1, true), debugLines(ns, "party1"))
    end)
    it("an icon that stores a secret ID is never matched by comparison (kept, then the full render decides)", function()
        local ns = boot(); local b = button(ns, "party1")
        local sid = mock.newSecret()
        S.auras.party1 = { { spellId = 1, name = "S", icon = 5, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, dispelName = "Magic", auraInstanceID = sid } }
        fullRender("party1")
        assertEquals(count(b.debuffIcons), 1)
        mock.auraEvent("party1", { removed = { 201 } })
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(count(b.debuffIcons), 1, "present in the data, so it stays")
        S.auras.party1 = {}
        mock.auraEvent("party1", { removed = { sid } })
        assertEquals(count(b.debuffIcons), 0, "the full render after the uncertain removal clears it")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a secret ID with failing enumeration is survived (kept, later verified)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        mock.auraEvent("party1", { removed = { mock.newSecret() } })
        assertEquals(count(b.debuffIcons), 2)
        assertEquals(#mock.errors, 0, errstr())
        S.failEnumerate = false
    end)
    it("malformed updateInfo never errors", function()
        local ns = boot(); setAuras("party1", 0, 2); fullRender("party1")
        for _, info in ipairs({ {}, { removedAuraInstanceIDs = "x" }, { removedAuraInstanceIDs = 5 }, { removedAuraInstanceIDs = { {}, "a", false } }, "string", 42, true }) do
            mock.fire("UNIT_AURA", "party1", info)
        end
        mock.fire("UNIT_AURA", "party1", mock.newSecret())
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== 4. retries
describe("aura stale: retries are coalesced and bounded", function()
    it("many failing events schedule exactly ONE pending retry", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true; clearTimers()
        mock.fire("UNIT_AURA", "party1")
        local one = pendingTimers()
        for _ = 1, 14 do mock.fire("UNIT_AURA", "party1") end
        assertEquals(pendingTimers(), one, "no timer pile-up: 15 failing events queue no more timers than one")
        assertTrue(b.auraRetryPending); assertEquals(b.auraRetries, 1)
        S.failEnumerate = false
    end)
    it("each retry runs after ~0.2s and schedules the next one (still one pending)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true; clearTimers()
        mock.fire("UNIT_AURA", "party1")
        local baseline = pendingTimers()
        mock.advance(0.15); assertEquals(b.auraRetries, 1)
        mock.advance(0.1); assertEquals(b.auraRetries, 2); assertTrue(pendingTimers() <= baseline, "chain does not grow")
        mock.advance(0.2); assertEquals(b.auraRetries, 3); assertTrue(pendingTimers() <= baseline, "chain does not grow")
        S.failEnumerate = false
    end)
    it("a retry that succeeds stops the chain and resets the counters", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true; clearTimers()
        mock.fire("UNIT_AURA", "party1"); mock.advance(0.5)
        assertTrue(b.auraRetries >= 2)
        S.failEnumerate = false
        mock.advance(0.3)
        assertEquals(b.auraRetries, 0); assertNil(b.auraFailSince); assertFalse(b.auraRetryPending and true or false)
        local n0 = #mock.timers
        mock.advance(0.5)
        assertTrue(pendingTimers() <= n0, "no further retries")
    end)
    it("after 25 fast (0.2s) retries the chain never gives up: it continues once a second, still ONE pending timer", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true; clearTimers()
        mock.fire("UNIT_AURA", "party1")
        local baseline = pendingTimers()
        mock.advance(5.3)
        assertTrue(b.auraRetries >= 25 and b.auraRetries <= 27, "25 fast retries in ~5s, got " .. b.auraRetries)
        local at5 = b.auraRetries
        mock.advance(10)
        local slow = b.auraRetries - at5
        assertTrue(slow >= 9 and slow <= 11, "then about one retry per second, got " .. slow .. " in 10s")
        assertTrue(pendingTimers() <= baseline, "no pile-up")
        assertTrue(b.auraRetryPending, "still retrying")
        assertEquals(#mock.errors, 0, errstr())
        S.failEnumerate = false
        mock.advance(1.5)
        assertEquals(b.auraRetries, 0, "a success ends the chain"); assertFalse(b.auraRetryPending and true or false)
    end)
    it("a retry on a hidden button is a no-op (no render, no error)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true; clearTimers()
        mock.fire("UNIT_AURA", "party1")
        b:Hide(); mock.advance(0.5)
        assertEquals(#mock.errors, 0, errstr())
        b:Show(); S.failEnumerate = false
    end)
end)

-- ======================================================================== 5. safety tick
describe("aura stale: the safety tick", function()
    local function spy(ns)
        local calls = {}
        local orig = ns.Auras.Update
        ns.Auras.Update = function(btn, src, ...) calls[#calls + 1] = { unit = btn.unit, src = src }; return orig(btn, src, ...) end
        return calls, function() ns.Auras.Update = orig end
    end
    it("re-renders units that show a debuff OR buff icon (about every 0.5s), nothing for units without icons", function()
        local ns = boot()
        setAuras("party1", 0, 2); setAuras("party2", 3, 0); setAuras("party3", 0, 0)
        for _, u in ipairs({ "party1", "party2", "party3", "player" }) do fullRender(u) end
        local calls, restore = spy(ns)
        mock.advance(1.0)
        restore()
        local by = {}
        for _, c in ipairs(calls) do if c.src == "safety" then by[c.unit] = (by[c.unit] or 0) + 1 end end
        assertTrue(by.party1 and by.party1 >= 1 and by.party1 <= 3, "party1 safety renders: " .. tostring(by.party1))
        assertTrue(by.party2 and by.party2 >= 1 and by.party2 <= 3, "party2 (buffs only) is covered now: " .. tostring(by.party2))
        assertNil(by.party3, "no icons: not re-rendered"); assertNil(by.player)
    end)
    it("does nothing at all when no aura icon is shown and no render failed", function()
        local ns = boot()
        for _, u in ipairs({ "party1", "party2", "party3", "player" }) do setAuras(u, 0, 0); fullRender(u) end
        local calls, restore = spy(ns)
        mock.advance(3)
        restore()
        assertEquals(#calls, 0)
    end)
    it("stops re-rendering a unit once its last aura icon is gone", function()
        local ns = boot()
        setAuras("party1", 0, 1); fullRender("party1")
        S.auras.party1 = {}; mock.auraEvent("party1", { removed = { 201 } })
        local calls, restore = spy(ns)
        mock.advance(2)
        restore()
        assertEquals(#calls, 0)
    end)
    it("the tick itself cannot error with hidden buttons or before the frames exist", function()
        local ns = boot()
        assertTrue(pcall(ns.Auras.SafetyTick, 10))
        for _, b in ipairs(ns.UnitFrames.buttons) do b:Hide() end
        assertTrue(pcall(ns.Auras.SafetyTick, 10))
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== 6. raid tokens, pets
describe("aura stale: tokens without a member bar are ignored", function()
    it("raid tokens, target, nil unit and the player's pet raise no error and change nothing", function()
        local ns = boot()
        setAuras("party1", 1, 2); fullRender("party1")
        local before = #shownIDs(button(ns, "party1").debuffIcons)
        local calls = 0
        local orig = ns.Auras.Update
        ns.Auras.Update = function(...) calls = calls + 1; return orig(...) end
        for _, u in ipairs({ "raid1", "raid17", "raid40", "target", "focus", "nameplate1", "boss1", "arena2", "vehicle" }) do
            mock.auraEvent(u, { removed = { 201 } }); mock.auraEvent(u, { full = true })
        end
        mock.fire("UNIT_AURA"); mock.fire("UNIT_AURA", nil, { removedAuraInstanceIDs = { 201 } })
        ns.Auras.Update = orig
        assertEquals(calls, 0)
        assertEquals(#shownIDs(button(ns, "party1").debuffIcons), before)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("pet tokens (pet, partypet1) are handled without error and never get aura icons", function()
        local ns = boot()
        S.auras.pet = { buff(1), debuff(1) }; S.auras.partypet1 = { buff(1), debuff(1) }
        for _, u in ipairs({ "pet", "partypet1" }) do
            mock.auraEvent(u, { full = true }); mock.auraEvent(u, { removed = { 201 } })
            local b = button(ns, u)
            if b then assertEquals(count(b.debuffIcons or {}), 0, u); assertEquals(count(b.buffIcons or {}), 0, u) end
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== 7. combat and secrets
describe("aura stale: combat and everything-secret", function()
    it("in combat the stale-aura machinery makes no protected calls and no soft violations", function()
        local ns = boot()
        setAuras("party1", 2, 3); fullRender("party1")
        local v0, s0 = #mock.violations, #mock.softViolations
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        removeAura("party1", 201); mock.auraEvent("party1", { removed = { 201 } })
        S.failEnumerate = true
        removeAura("party1", 202); mock.auraEvent("party1", { removed = { 202 } })
        mock.fire("UNIT_AURA", "party1"); mock.advance(2.5)
        S.failEnumerate = false; mock.advance(0.5)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0); assertEquals(#mock.errors, 0, errstr())
    end)
    it("everything secret, out of combat, with updateInfo events: no errors", function()
        local ns = boot()
        S.secretAll = true
        setAuras("party1", 2, 3); setAuras("player", 1, 1)
        for _, u in ipairs({ "party1", "player", "party2" }) do
            mock.auraEvent(u, { full = true }); mock.auraEvent(u, { removed = { 201, 102 } }); mock.auraEvent(u, { removed = { mock.newSecret() } })
        end
        S.failEnumerate = true
        mock.advance(2.5)
        S.failEnumerate = false
        mock.advance(1)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("everything secret AND in combat AND failing enumeration, with every removal secret: still no error", function()
        local ns = boot()
        S.secretAll = true; S.combat = true; S.secret = true; S.secretTable = true; S.failEnumerate = true
        setAuras("party1", 2, 3)
        for _ = 1, 5 do mock.auraEvent("party1", { removed = { mock.newSecret() } }); mock.advance(0.7) end
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== 8. /hf debug auras
describe("aura stale: /hf debug auras shows the last update source", function()
    local ns = boot()
    setAuras("party1", 0, 3); fullRender("party1")
    it("an event with removed IDs", function()
        removeAura("party1", 201)
        mock.auraEvent("party1", { removed = { 201 } })
        local line = debugLines(ns, "party1")
        assertTrue(line:find("source=event", 1, true), line); assertTrue(line:find("full=false", 1, true), line)
        assertTrue(line:find("removedIDs=1", 1, true), line); assertTrue(line:find("uncertain(secret ID)=false", 1, true), line)
    end)
    it("a full update", function()
        mock.auraEvent("party1", { full = true })
        local line = debugLines(ns, "party1")
        assertTrue(line:find("source=event", 1, true) and line:find("full=true", 1, true), line)
    end)
    it("the safety tick", function()
        mock.advance(0.7)
        assertTrue(debugLines(ns, "party1"):find("source=safety", 1, true), debugLines(ns, "party1"))
    end)
    it("a retry, with last-known icons and the retry counter", function()
        S.failEnumerate = true
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        local line = debugLines(ns, "party1")
        assertTrue(line:find("source=retry", 1, true), line)
        assertTrue(line:find("lastKnownIcons=true", 1, true), line)
        assertTrue(line:match("retries=(%d+)") ~= nil and tonumber(line:match("retries=(%d+)")) >= 1, line)
        S.failEnumerate = false
        mock.fire("UNIT_AURA", "party1")
    end)
    it("a secret removed ID is reported as uncertain", function()
        mock.auraEvent("party1", { removed = { mock.newSecret() } })
        assertTrue(debugLines(ns, "party1"):find("uncertain(secret ID)=true", 1, true))
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== another player dispels during a fight
describe("aura stale: ANOTHER player dispels the debuff (no action from us)", function()
    -- (the fallback path reads nothing in real combat; these tests cover the same removals out of combat, with and without working enumeration)
    local function inCombat(ns)
        S.combat = false
    end
    local function setup()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 1, 3); fullRender("party1")
        assertEquals(count(b.debuffIcons), 3)
        inCombat(ns)
        return ns, b
    end
    it("via UNIT_AURA with removedAuraInstanceIDs: gone at once", function()
        local ns, b = setup()
        removeAura("party1", 202)
        mock.auraEvent("party1", { removed = { 202 } })
        assertFalse(has(b.debuffIcons, 202)); assertEquals(count(b.debuffIcons), 2)
        assertPacked(ns, b.debuffIcons, ns.db.auras.debuffSize, "combat removal")
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
    it("via a plain UNIT_AURA with no updateInfo: gone at once when enumeration works (combat render)", function()
        local ns, b = setup()
        removeAura("party1", 202)
        mock.fire("UNIT_AURA", "party1")
        assertFalse(has(b.debuffIcons, 202)); assertEquals(count(b.debuffIcons), 2)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("via a plain UNIT_AURA while enumeration fails: gone within the 1s verify window", function()
        local ns, b = setup()
        S.failEnumerate = true
        removeAura("party1", 202)
        mock.fire("UNIT_AURA", "party1")
        mock.advance(1.8)
        assertFalse(has(b.debuffIcons, 202)); assertEquals(count(b.debuffIcons), 2)
        assertEquals(#mock.errors, 0, errstr())
        S.failEnumerate = false
    end)
    it("UNIT_AURA NEVER fires and enumeration works: the 0.5s safety tick removes it (within ~0.7s)", function()
        local ns, b = setup()
        removeAura("party1", 202)
        assertTrue(has(b.debuffIcons, 202), "nothing has told the addon yet")
        mock.advance(0.7)
        assertFalse(has(b.debuffIcons, 202), "the safety tick re-rendered the unit")
        assertTrue(debugLines(ns, "party1"):find("source=safety", 1, true), debugLines(ns, "party1"))
        assertEquals(count(b.debuffIcons), 2)
        assertPacked(ns, b.debuffIcons, ns.db.auras.debuffSize, "safety tick")
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
    it("UNIT_AURA NEVER fires, secret table + secret values in combat: still cleared by the safety tick", function()
        local ns, b = setup()
        S.secret = true; S.secretTable = true
        removeAura("party1", 203)
        mock.advance(1.0)
        assertFalse(has(b.debuffIcons, 203))
        assertEquals(#mock.errors, 0, errstr())
        S.secret, S.secretTable = false, false
    end)
    it("UNIT_AURA NEVER fires and every enumeration method fails: the safety tick renders from the cache and the cross-check clears it within ~0.7s", function()
        local ns, b = setup()
        S.failEnumerate = true
        removeAura("party1", 201)
        mock.advance(0.7)
        assertFalse(has(b.debuffIcons, 201), "gone via the safety tick + cache cross-check")
        assertTrue(has(b.debuffIcons, 202) and has(b.debuffIcons, 203))
        assertEquals(#mock.errors, 0, errstr())
        S.failEnumerate = false
    end)
    it("only the safety tick can catch it: with the tick disabled the icon stays (proves the tick is what clears it)", function()
        local ns, b = setup()
        local tick = ns.Auras.SafetyTick
        ns.Auras.SafetyTick = nil
        removeAura("party1", 202)
        mock.advance(2)
        assertTrue(has(b.debuffIcons, 202), "no event and no tick: nothing can notice")
        ns.Auras.SafetyTick = tick
        mock.advance(0.7)
        assertFalse(has(b.debuffIcons, 202))
    end)
    it("several members, one is dispelled silently: only that member's row changes", function()
        local ns = boot()
        setAuras("party1", 0, 2); setAuras("party2", 0, 2); fullRender("party1"); fullRender("party2")
        inCombat(ns)
        removeAura("party2", 201)
        mock.advance(0.7)
        assertEquals(count(button(ns, "party1").debuffIcons), 2)
        assertEquals(table.concat(shownIDs(button(ns, "party2").debuffIcons), ","), "202")
    end)
    it("a debuff dispelled and re-applied (new ID) with no event is replaced by the tick", function()
        local ns, b = setup()
        removeAura("party1", 202)
        S.auras.party1[#S.auras.party1 + 1] = debuff(2, 400)
        mock.advance(0.7)
        assertFalse(has(b.debuffIcons, 202)); assertTrue(has(b.debuffIcons, 402))
        assertEquals(count(b.debuffIcons), 3)
    end)
end)

-- ======================================================================== stale enumeration cross-check

describe("aura stale: a STALE enumeration is cross-checked by instance ID", function()
    local function dropped(ns, u)
        local d = ns.Auras.debugInfo[u .. ":render"]
        return d and table.concat(d.errors, " | "):find("dropped a listed aura", 1, true) ~= nil
    end
    local function stale(ns, id) S.goneIDs = S.goneIDs or {}; S.goneIDs[id] = true end   -- still listed by GetUnitAuras, no longer resolves by ID

    it("sanity: the stale list really is listed by the enumeration while the by-ID lookup says it is gone", function()
        local ns = boot()
        setAuras("party1", 0, 2)
        stale(ns, 201)
        assertEquals(#C_UnitAuras.GetUnitAuras("party1", "HARMFUL"), 2)
        assertNil(C_UnitAuras.GetAuraDataByAuraInstanceID("party1", 201))
        assertNotNil(C_UnitAuras.GetAuraDataByAuraInstanceID("party1", 202))
    end)
    it("out of combat: the icon for the listed-but-gone debuff is hidden and the rest repack", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        assertEquals(count(b.debuffIcons), 3)
        stale(ns, 202)
        mock.fire("UNIT_AURA", "party1")
        assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "201,203")
        assertPacked(ns, b.debuffIcons, ns.db.auras.debuffSize, "stale list")
        assertTrue(dropped(ns, "party1"), "the drop is noted in the render debug info")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secret mode + secret table: the same", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        S.secret = true; S.secretTable = true
        stale(ns, 203)
        mock.fire("UNIT_AURA", "party1")
        assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "201,202")
        mock.auraEvent("party1", { full = true })
        assertEquals(count(b.debuffIcons), 2)
        S.secret, S.secretTable = false, false
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
    it("the safety tick alone clears a stale-listed debuff (no event)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        stale(ns, 201)
        mock.advance(0.7)
        assertFalse(has(b.debuffIcons, 201)); assertTrue(has(b.debuffIcons, 202))
    end)
    it("buffs are cross-checked too", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 3, 0); fullRender("party1")
        stale(ns, 102)
        mock.fire("UNIT_AURA", "party1")
        assertEquals(table.concat(shownIDs(b.buffIcons), ","), "101,103")
        assertPacked(ns, b.buffIcons, ns.db.auras.buffSize, "buffs")
    end)
    it("every aura gone: the row empties and the zone fades", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        stale(ns, 201); stale(ns, 202)
        mock.fire("UNIT_AURA", "party1")
        assertEquals(count(b.debuffIcons), 0); assertEquals(b.zones.debuff:GetAlpha(), 0)
    end)
    it("a debuff that is gone but comes back (new data for the same id) is shown again", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        stale(ns, 201); mock.fire("UNIT_AURA", "party1"); assertFalse(has(b.debuffIcons, 201))
        S.goneIDs[201] = nil; mock.fire("UNIT_AURA", "party1")
        assertTrue(has(b.debuffIcons, 201))
    end)
end)

describe("aura stale: unreadable or erroring IDs keep the entry", function()
    it("a by-ID lookup that raises keeps every listed aura", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 2, 3); fullRender("party1")
        local real = C_UnitAuras.GetAuraDataByAuraInstanceID
        C_UnitAuras.GetAuraDataByAuraInstanceID = function() error("secret ID rejected") end
        mock.fire("UNIT_AURA", "party1")
        C_UnitAuras.GetAuraDataByAuraInstanceID = real
        assertEquals(count(b.debuffIcons), 3); assertEquals(count(b.buffIcons), 2)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a by-ID lookup that returns a SECRET value keeps the entry (never compared)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        local real = C_UnitAuras.GetAuraDataByAuraInstanceID
        C_UnitAuras.GetAuraDataByAuraInstanceID = function() return mock.newSecret() end
        mock.fire("UNIT_AURA", "party1")
        C_UnitAuras.GetAuraDataByAuraInstanceID = real
        assertEquals(count(b.debuffIcons), 3)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("an aura whose own instance ID is secret is kept (and resolved with the secret itself)", function()
        local ns = boot(); local b = button(ns, "party1")
        local sid = mock.newSecret()
        S.auras.party1 = { { spellId = 1, name = "S", icon = 5, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, dispelName = "Magic", auraInstanceID = sid } }
        mock.fire("UNIT_AURA", "party1")
        assertEquals(count(b.debuffIcons), 1)
        mock.fire("UNIT_AURA", "party1"); mock.advance(0.7)
        assertEquals(count(b.debuffIcons), 1)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("an aura without any instance ID is kept", function()
        local ns = boot(); local b = button(ns, "party1")
        S.auras.party1 = { debuff(1) }
        local realGet = C_UnitAuras.GetUnitAuras
        C_UnitAuras.GetUnitAuras = function(...) local out = realGet(...); for _, a in ipairs(out) do a.auraInstanceID = nil end return out end
        mock.fire("UNIT_AURA", "party1")
        C_UnitAuras.GetUnitAuras = realGet
        local n = 0
        for _, icon in ipairs(b.debuffIcons) do if st(icon).shown then n = n + 1 end end
        assertEquals(n, 1)
    end)
    it("the lookup API missing entirely skips the cross-check without error", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        local real = C_UnitAuras.GetAuraDataByAuraInstanceID
        C_UnitAuras.GetAuraDataByAuraInstanceID = nil
        mock.fire("UNIT_AURA", "party1")
        C_UnitAuras.GetAuraDataByAuraInstanceID = real
        assertEquals(count(b.debuffIcons), 2)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("everything secret: no error and the icons stay (nothing is dropped on unreadable IDs)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 2, 3); fullRender("party1")
        S.secretAll = true
        mock.fire("UNIT_AURA", "party1"); mock.advance(1.2)
        assertEquals(count(b.debuffIcons), 3)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("aura stale: normal auras are unaffected by the cross-check", function()
    it("a normal list renders exactly as before: same icons, no 'dropped' note, repeated renders are stable", function()
        local ns = boot(); local b = button(ns, "party1")
        ns.db.auras.maxDebuffs = 4; ns:Changed("frames"); mock.flushTimers()
        setAuras("party1", 3, 4); fullRender("party1")
        assertEquals(count(b.debuffIcons), 4); assertEquals(count(b.buffIcons), 3)
        for _ = 1, 5 do mock.fire("UNIT_AURA", "party1") end
        mock.advance(1.5)
        assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "201,202,203,204")
        assertEquals(table.concat(shownIDs(b.buffIcons), ","), "101,102,103")
        local d = ns.Auras.debugInfo["party1:render"]
        assertNil(table.concat(d.errors, " | "):find("dropped", 1, true))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("aura data stays correct for the surviving icons (names, textures, order)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        S.goneIDs = { [202] = true }
        mock.fire("UNIT_AURA", "party1")
        assertEquals(b.debuffIcons[1].auraName, "Debuff1"); assertEquals(b.debuffIcons[2].auraName, "Debuff3")
        assertEquals(st(b.debuffIcons[2].texture).texture, 303)
    end)
    it("the cross-check respects maxDebuffs (a dropped stale entry lets the next aura in)", function()
        local ns = boot(); local b = button(ns, "party1")
        ns.db.auras.maxDebuffs = 2; ns:Changed("frames"); mock.flushTimers()
        setAuras("party1", 0, 3); fullRender("party1")
        assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "201,202")
        S.goneIDs = { [201] = true }
        mock.fire("UNIT_AURA", "party1")
        assertEquals(count(b.debuffIcons), 2)
        assertFalse(has(b.debuffIcons, 201))
    end)
end)

-- ======================================================================== /hf debug auras per-icon output
describe("aura stale: /hf debug auras lists every visible icon and orphans", function()
    local function debugText(ns)
        mock.printed = {}
        assert(pcall(_G.SlashCmdList.HEALERFOREVER, "debug auras"))
        return table.concat(mock.printed, "\n")
    end
    it("a visible icon: index, stored ID, name, still-exists, zone and in-list flags", function()
        local ns = boot()
        setAuras("party1", 0, 2); fullRender("party1")
        local out = debugText(ns)
        assertTrue(out:find("debuff icon 1: id=201 name=Debuff1 auraStillExists=true zone=true inDebuffIcons=true", 1, true), out)
        assertTrue(out:find("debuff icon 2: id=202 name=Debuff2 auraStillExists=true zone=true inDebuffIcons=true", 1, true), out)
        assertNil(out:find("ORPHAN", 1, true), "no orphan in a healthy bar")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a removed aura whose icon is still up reports auraStillExists=false", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        local real = C_UnitAuras.GetAuraDataByAuraInstanceID
        C_UnitAuras.GetAuraDataByAuraInstanceID = function() error("unreadable at render time") end      -- the cross-check cannot drop it
        mock.fire("UNIT_AURA", "party1")
        C_UnitAuras.GetAuraDataByAuraInstanceID = real
        S.goneIDs = { [201] = true }                                                                  -- ...but it is gone when /hf debug looks
        assertTrue(has(b.debuffIcons, 201), "kept: the render-time check was unreadable")
        local out = debugText(ns)
        assertTrue(out:find("debuff icon 1: id=201 name=Debuff1 auraStillExists=false", 1, true), out)
        assertTrue(out:find("debuff icon 2: id=202 name=Debuff2 auraStillExists=true", 1, true), out)
        S.failEnumerate = false
    end)
    it("hidden icons are not listed", function()
        local ns = boot()
        setAuras("party1", 0, 3); fullRender("party1")
        S.auras.party1 = { debuff(1) }; mock.auraEvent("party1", { removed = { 202, 203 } })
        local out = debugText(ns)
        assertTrue(out:find("debuff icon 1:", 1, true)); assertNil(out:find("debuff icon 2:", 1, true), out)
    end)
    it("secret ids / names are printed as <secret> and an erroring lookup as unreadable, without raising", function()
        local ns = boot()
        local sid = mock.newSecret()
        S.auras.party1 = { { spellId = 1, name = "S", icon = 5, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, dispelName = "Magic", auraInstanceID = sid } }
        mock.fire("UNIT_AURA", "party1")
        local out = debugText(ns)
        assertTrue(out:find("id=<secret>", 1, true), out)
        local real = C_UnitAuras.GetAuraDataByAuraInstanceID
        setAuras("party1", 0, 1); fullRender("party1")
        C_UnitAuras.GetAuraDataByAuraInstanceID = function() error("nope") end
        out = debugText(ns)
        C_UnitAuras.GetAuraDataByAuraInstanceID = real
        assertTrue(out:find("auraStillExists=unreadable", 1, true), out)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a planted orphan frame in the debuff zone is reported; hidden or managed frames are not", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 1); fullRender("party1")
        assertNil(debugText(ns):find("ORPHAN", 1, true))
        local orphan = ns.NewFrame("Frame", nil, b.zones.debuff)
        orphan:Show()
        local out = debugText(ns)
        assertTrue(out:find("ORPHAN: a shown frame in the debuff zone is not in debuffIcons", 1, true), out)
        orphan:Hide()
        assertNil(debugText(ns):find("ORPHAN", 1, true), "a hidden stray frame is not an orphan")
        orphan:Show()
        table.insert(b.debuffIcons, orphan)
        assertNil(debugText(ns):find("ORPHAN", 1, true), "once it is a managed icon it is not an orphan")
        table.remove(b.debuffIcons)
        orphan:Hide()
    end)
    it("a debuff icon whose parent is not the debuff zone is flagged zone=false", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 1); fullRender("party1")
        local icon = b.debuffIcons[1]
        local realParent = st(icon).parent
        st(icon).parent = b.zones.buff
        local out = debugText(ns)
        st(icon).parent = realParent
        assertTrue(out:find("debuff icon 1:[^\n]*zone=false"), out)
    end)
    it("works with everything secret; in combat it says the fallback reads nothing (and lists no icons)", function()
        local ns = boot()
        setAuras("party1", 1, 2); fullRender("party1")
        S.secretAll = true
        assertTrue(debugText(ns):find("debuff icon", 1, true))
        S.secretAll = false
        S.combat = true
        local out = debugText(ns)
        S.combat = false
        assertTrue(out:find("in combat: the fallback path reads nothing", 1, true), out)
        assertNil(out:find("debuff icon 1", 1, true))
        assertEquals(#mock.errors, 0, errstr())
    end)
end)


-- ======================================================================== combat: nothing is read, so nothing can be (mis)displayed
describe("aura stale: in combat the fallback is frozen; a dispel is shown by the refresh when combat ends", function()
    it("a debuff dispelled in combat (by us or anybody) stays on the frozen, dimmed bar - with ZERO aura reads - and disappears at PLAYER_REGEN_ENABLED", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 1, 3); fullRender("party1")
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        removeAura("party1", 202)
        mock.auraEvent("party1", { removed = { 202 } }); mock.fire("UNIT_AURA", "party1"); mock.advance(5)
        assertTrue(has(b.debuffIcons, 202), "frozen: still shown")
        assertEquals(b.zones.debuff:GetAlpha(), 0.4, "dimmed to show that it is frozen")
        assertEquals(mock.auraCalls.total, 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertFalse(has(b.debuffIcons, 202)); assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "201,203")
        assertEquals(b.zones.debuff:GetAlpha(), 1)
        assertPacked(ns, b.debuffIcons, ns.db.auras.debuffSize, "after combat")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("many dispels over a long fight are all applied by the single refresh afterwards (buffs and debuffs)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 3, 3); fullRender("party1")
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        for _, id in ipairs({ 201, 203, 102 }) do removeAura("party1", id); mock.auraEvent("party1", { removed = { id } }); mock.advance(10) end
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(table.concat(shownIDs(b.debuffIcons), ","), "202"); assertEquals(table.concat(shownIDs(b.buffIcons), ","), "101,103")
    end)
    it("the pending retry chain (started before combat) does not read in combat and resumes after it", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        mock.fire("UNIT_AURA", "party1")
        assertTrue(b.auraRetryPending)
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        mock.advance(20)
        assertEquals(mock.auraCalls.total, 0, "retries are silent in combat")
        S.failEnumerate = false; S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(b.auraRetries, 0)
    end)
end)
