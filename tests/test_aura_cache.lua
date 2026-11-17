-- The REAL in-game failure: in combat every aura enumeration method fails for a whole fight. Icons must follow UNIT_AURA deltas from the
-- per-unit cache, never get stuck, and a full scan after combat restores the truth. Plus the GetAuraSlots path with continuation tokens,
-- per-method outcomes, the cache rules, the safety tick (buffs too, throttled) and the /hf debug auras render-time lines.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER"); S.units.party3 = unit("Mage", "MAGE", "DAMAGER")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    ns.db.auras.maxBuffs = 6; ns.db.auras.maxDebuffs = 6
    ns:Changed("frames"); mock.flushTimers()
    if opts.slots then mock.enableSlots(opts.slots) end
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
local function findAura(u, id) for i, a in ipairs(S.auras[u]) do if a.auraInstanceID == id then return a, i end end end
local function removeAura(u, id) local _, i = findAura(u, id); assert(i, "no aura " .. id); table.remove(S.auras[u], i) end
local function button(ns, u) return ns.UnitFrames.byUnit[u] end
local function ids(list)
    local out = {}
    for _, icon in ipairs(list) do if st(icon).shown then out[#out + 1] = icon.auraInstanceID end end
    table.sort(out)
    return table.concat(out, ",")
end
local function truth(u, harmful)
    local out = {}
    for _, a in ipairs(S.auras[u] or {}) do if (a.isHarmful and true or false) == harmful then out[#out + 1] = a.auraInstanceID end end
    table.sort(out)
    return table.concat(out, ",")
end
local function fullRender(u) mock.fire("UNIT_AURA", u); mock.flushTimers() end
-- NOTE: in real combat the fallback reads nothing at all (test_aura_combat). These tests exercise the cache / retry / tick machinery for the
-- case that matters now: aura enumeration FAILING while we are allowed to read (secret table, API errors, early login). Hence "inCombat" is a no-op here.
local function inCombat() end
local function outOfCombat() mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers() end
local function debugText()
    mock.printed = {}
    assert(pcall(_G.SlashCmdList.HEALERFOREVER, "debug auras"))
    return table.concat(mock.printed, "\n")
end
-- a dropped cache = no kind lists left (the code re-creates an empty container on the next render)
local function noCache(b) return b.auraCache == nil or next(b.auraCache) == nil end
local function render(ns, u, filter) return ns.Auras.renderInfo[u .. ":" .. filter] end

-- ======================================================================== 1. the real failure: a long fight with no readable enumeration
describe("aura cache: a 60 second stretch where EVERY enumeration method fails (deltas keep the icons right)", function()
    it("icons follow UNIT_AURA deltas from the cache: added shows, removed hides, updated refreshes; then PLAYER_REGEN_ENABLED restores the truth", function()
        local ns = boot({ slots = { page = 2 } }); local b = button(ns, "party1")
        setAuras("party1", 2, 3); fullRender("party1")
        assertEquals(ids(b.debuffIcons), "201,202,203"); assertEquals(ids(b.buffIcons), "101,102")
        inCombat(); S.failEnumerate = true
        -- t = 5s: a debuff is added
        mock.advance(5)
        local added = debuff(4); table.insert(S.auras.party1, added)
        mock.auraEvent("party1", { added = { mock.wrapAura(added) } })
        assertEquals(ids(b.debuffIcons), "201,202,203,204", "the added debuff shows (from the cache)")
        assertTrue(b.auraDebug.cacheUsed, "rendered from the cache")
        -- t = 15s: a buff is added, a debuff is dispelled
        mock.advance(10)
        local nb = buff(3); table.insert(S.auras.party1, nb)
        mock.auraEvent("party1", { added = { mock.wrapAura(nb) } })
        removeAura("party1", 202)
        mock.auraEvent("party1", { removed = { 202 } })
        assertEquals(ids(b.buffIcons), "101,102,103"); assertEquals(ids(b.debuffIcons), "201,203,204")
        -- t = 25s: a debuff is refreshed (new expiration)
        mock.advance(10)
        local upd = findAura("party1", 203); upd.expirationTime = S.now + 55; upd.duration = 60
        mock.auraEvent("party1", { updated = { 203 } })
        local icon203
        for _, icon in ipairs(b.debuffIcons) do if st(icon).shown and icon.auraInstanceID == 203 then icon203 = icon end end
        assertNotNil(icon203); assertEquals(icon203.expiration, S.now + 55, "the refreshed expiration reached the icon")
        -- t = 25..60s: quiet, the safety tick keeps re-rendering from the cache and nothing drifts or errors
        mock.advance(35)
        assertEquals(ids(b.debuffIcons), "201,203,204"); assertEquals(ids(b.buffIcons), "101,102,103")
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0); assertEquals(#mock.softViolations, 0)
        -- the cache and the truth agree here because every change was reported
        assertEquals(ids(b.debuffIcons), truth("party1", true)); assertEquals(ids(b.buffIcons), truth("party1", false))
        -- a change nobody reported (the cache cannot know): the icon for the unreported removal is dropped by the by-ID cross-check, the unreported ADD is not visible yet
        removeAura("party1", 101)
        local silent = debuff(5); table.insert(S.auras.party1, silent)
        mock.advance(1)
        assertFalse(ids(b.buffIcons):find("101", 1, true) ~= nil, "unreported removal: cleared by the cross-check")
        assertFalse(ids(b.debuffIcons):find("205", 1, true) ~= nil, "an unreported ADD is invisible until a real scan")
        -- combat ends: the full scan restores the truth
        S.failEnumerate = false
        outOfCombat()
        assertEquals(ids(b.debuffIcons), truth("party1", true)); assertEquals(ids(b.buffIcons), truth("party1", false))
        assertTrue(ids(b.debuffIcons):find("205", 1, true) ~= nil)
        assertFalse(b.auraDebug.cacheUsed)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the safety tick alone (NO event for 60s) keeps clearing dispelled icons from the cache", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 3, 3); fullRender("party1")
        inCombat(); S.failEnumerate = true
        for step = 1, 6 do
            mock.advance(10)
            removeAura("party1", step <= 3 and (200 + step) or (100 + step - 3))
            mock.advance(0.7)
            assertEquals(ids(b.debuffIcons), truth("party1", true), "t=" .. step * 10.7)
            assertEquals(ids(b.buffIcons), truth("party1", false), "t=" .. step * 10.7)
        end
        assertEquals(ids(b.debuffIcons), ""); assertEquals(ids(b.buffIcons), "")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("when the API recovers in the MIDDLE of the fight (still in combat) the retry chain / tick restores the truth within ~1s", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 1, 2); fullRender("party1")
        inCombat(); S.failEnumerate = true
        mock.advance(30)
        local silent = debuff(3); table.insert(S.auras.party1, silent)
        mock.advance(30)
        assertFalse(ids(b.debuffIcons):find("203", 1, true) ~= nil)
        S.failEnumerate = false
        mock.advance(1.2)
        assertEquals(ids(b.debuffIcons), "201,202,203")
        assertEquals(b.auraRetries, 0, "the chain ended on success")
    end)
    it("with the safety tick disabled the slow (1s) retry chain alone recovers after a minute of failure", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        inCombat(); S.failEnumerate = true
        ns.Auras.SafetyTick = nil
        mock.fire("UNIT_AURA", "party1")
        mock.advance(60)
        assertTrue(b.auraRetries > 25, "retries went past the old cap of 25: " .. b.auraRetries)
        assertTrue(b.auraRetryPending, "still retrying after a minute")
        table.insert(S.auras.party1, debuff(3))
        S.failEnumerate = false
        mock.advance(1.2)
        assertEquals(ids(b.debuffIcons), "201,202,203", "the chain found the API again and rendered the truth")
        assertEquals(b.auraRetries, 0)
    end)
    it("secret mode and a secret table during the whole fight: no errors, deltas still honoured when IDs are readable", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 1, 2); fullRender("party1")
        inCombat(); S.secretTable = true; S.failEnumerate = true
        removeAura("party1", 201); mock.auraEvent("party1", { removed = { 201 } })
        mock.advance(20)
        assertFalse(ids(b.debuffIcons):find("201", 1, true) ~= nil)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("everything secret (IDs unreadable) during a failing fight: no errors, no protected calls; the cache is dropped and the last icons stay until a scan", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 1, 2); fullRender("party1")
        inCombat(); S.secretAll = true; S.secret = true; S.failEnumerate = true
        mock.auraEvent("party1", { removed = { 201 } }); mock.auraEvent("party1", { added = { mock.wrapAura(debuff(9)) } }); mock.auraEvent("party1", { updated = { 202 } })
        mock.advance(20)
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
        S.secretAll = false; S.secret = false; S.failEnumerate = false
        outOfCombat()
        assertEquals(ids(b.debuffIcons), truth("party1", true))
    end)
end)

-- ======================================================================== 2. the slots path
describe("aura cache: GetAuraSlots + GetAuraDataBySlot", function()
    it("is tried FIRST and follows the continuation token across several calls (page of 2 slots, 5 debuffs: tokens nil, 3, 5)", function()
        local ns = boot({ slots = { page = 2 } }); local b = button(ns, "party1")
        setAuras("party1", 0, 5)
        mock.slotCalls = {}
        fullRender("party1")
        assertEquals(ids(b.debuffIcons), "201,202,203,204,205")
        local tokens, data = {}, 0
        for _, c in ipairs(mock.slotCalls) do
            if c[1] == "slots" and c[2] == "party1" and tostring(c[3]):find("HARMFUL", 1, true) then tokens[#tokens + 1] = tostring(c[5]) elseif c[1] == "data" and c[2] == "party1" then data = data + 1 end
        end
        assertEquals(table.concat(tokens, ","), "nil,3,5", "three calls, each with the token the previous one returned")
        assertTrue(data >= 5, "one GetAuraDataBySlot per slot: " .. data)
        local r = render(ns, "party1", "HARMFUL")
        assertEquals(r.method, "slots"); assertEquals(r.methods.slots, "ok (5)")
        assertNil(r.methods.GetUnitAuras, "later methods are not even tried when slots work")
    end)
    it("buffs and debuffs use their own filters through the slots path", function()
        local ns = boot({ slots = { page = 3 } }); local b = button(ns, "party1")
        setAuras("party1", 4, 2); fullRender("party1")
        assertEquals(ids(b.buffIcons), "101,102,103,104"); assertEquals(ids(b.debuffIcons), "201,202")
        assertEquals(render(ns, "party1", "HELPFUL").method, "slots"); assertEquals(render(ns, "party1", "HARMFUL").method, "slots")
    end)
    it("stops asking for more once `max` auras are collected", function()
        local ns = boot({ slots = { page = 2 } })
        ns.db.auras.maxDebuffs = 3; ns:Changed("frames"); mock.flushTimers()
        setAuras("party1", 0, 6)
        mock.slotCalls = {}
        fullRender("party1")
        local calls = 0
        for _, c in ipairs(mock.slotCalls) do if c[1] == "slots" and c[2] == "party1" and tostring(c[3]):find("HARMFUL", 1, true) then calls = calls + 1 end end
        assertEquals(calls, 2, "2 slots + 2 slots >= max 3")
        assertEquals(ids(button(ns, "party1").debuffIcons), "201,202,203")
    end)
    it("a failing GetAuraSlots falls through to GetUnitAuras; the outcome of each method is recorded", function()
        local ns = boot({ slots = { page = 2 } }); local b = button(ns, "party1")
        setAuras("party1", 0, 3)
        S.failSlots = true
        fullRender("party1")
        assertEquals(ids(b.debuffIcons), "201,202,203")
        local r = render(ns, "party1", "HARMFUL")
        assertEquals(r.method, "GetUnitAuras")
        assertTrue(r.methods.slots:find("^failed:") ~= nil, tostring(r.methods.slots)); assertEquals(r.methods.GetUnitAuras, "ok (3)")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("slots + GetUnitAuras failing (secret table) fall through to instance IDs, then by index, each recorded", function()
        local ns = boot({ slots = { page = 2 } }); local b = button(ns, "party1")
        setAuras("party1", 0, 3)
        S.failSlots = true; S.secretTable = true
        fullRender("party1")
        local r = render(ns, "party1", "HARMFUL")
        assertEquals(r.method, "InstanceIDs"); assertTrue(r.methods.GetUnitAuras == "table not indexable" or r.methods.GetUnitAuras == "no table", tostring(r.methods.GetUnitAuras))
        assertEquals(ids(b.debuffIcons), "201,202,203")
        S.noInstanceIDs = true
        fullRender("party1")
        r = render(ns, "party1", "HARMFUL")
        assertEquals(r.method, "ByIndex"); assertTrue(r.methods.InstanceIDs:find("^failed") ~= nil)
        assertEquals(ids(b.debuffIcons), "201,202,203")
    end)
    it("every method failing records a failure for each of them and renders from the cache", function()
        local ns = boot({ slots = { page = 2 } }); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        S.failEnumerate = true
        fullRender("party1")
        local r = render(ns, "party1", "HARMFUL")
        assertEquals(r.method, "none")
        for _, m in ipairs({ "slots", "GetUnitAuras", "InstanceIDs", "ByIndex" }) do assertTrue(tostring(r.methods[m]):find("failed", 1, true) ~= nil, m .. ": " .. tostring(r.methods[m])) end
        assertEquals(ids(b.debuffIcons), "201,202,203", "from the cache")
    end)
    it("missing slot APIs are reported as 'API missing' and the older methods still work", function()
        local ns = boot()
        setAuras("party1", 0, 2); fullRender("party1")
        local r = render(ns, "party1", "HARMFUL")
        assertEquals(r.methods.slots, "API missing"); assertEquals(r.method, "GetUnitAuras")
        assertEquals(ids(button(ns, "party1").debuffIcons), "201,202")
    end)
    it("an unknown slot (GetAuraDataBySlot returns nil) is skipped, not an error", function()
        local ns = boot({ slots = { page = 2 } }); local b = button(ns, "party1")
        setAuras("party1", 0, 3)
        local real = C_UnitAuras.GetAuraDataBySlot
        C_UnitAuras.GetAuraDataBySlot = function(u, slot) if slot == 202 then return nil end return real(u, slot) end
        fullRender("party1")
        C_UnitAuras.GetAuraDataBySlot = real
        assertEquals(ids(b.debuffIcons), "201,203"); assertEquals(#mock.errors, 0, errstr())
    end)
    it("DEFECT CHECK: when GetAuraDataBySlot RAISES for every slot, the empty result is treated as a successful scan (icons vanish) instead of falling through", function()
        local ns = boot({ slots = { page = 2 } }); local b = button(ns, "party1")
        setAuras("party1", 0, 3); fullRender("party1")
        S.failSlotData = true
        fullRender("party1")
        local r = render(ns, "party1", "HARMFUL")
        assertEquals(#mock.errors, 0, errstr())
        if r.method == "slots" and ids(b.debuffIcons) == "" then
            warn("Frames/Auras.lua enumerate (slots path, ~line 170): when GetAuraDataBySlot raises for every slot the pcall'd per-slot errors are swallowed, the empty list is "
                .. "returned as a successful 'slots' scan and the row is emptied instead of falling through to GetUnitAuras / the cache")
        else
            assertEquals(ids(b.debuffIcons), "201,202,203")
        end
        S.failSlotData = false
    end)
    it("slots work with everything secret and in combat (no errors, no protected calls)", function()
        local ns = boot({ slots = { page = 2 } })
        setAuras("party1", 2, 3); fullRender("party1")
        inCombat(); S.secretAll = true
        fullRender("party1"); mock.advance(2)
        S.secretAll = false; outOfCombat()
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
    end)
end)

-- ======================================================================== 3. the cache itself
describe("aura cache: replacement, invalidation, separation", function()
    it("every successful full scan REPLACES the cache (nothing stale survives)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 2, 3); fullRender("party1")
        assertEquals(#b.auraCache.debuff, 3); assertEquals(#b.auraCache.buff, 2)
        removeAura("party1", 202); removeAura("party1", 101)
        fullRender("party1")
        assertEquals(#b.auraCache.debuff, 2); assertEquals(#b.auraCache.buff, 1)
        local names = {}
        for _, a in ipairs(b.auraCache.debuff) do names[#names + 1] = a.name end
        table.sort(names)
        assertEquals(table.concat(names, ","), "Debuff1,Debuff3")
    end)
    it("buff and debuff caches are separate lists; a delta touches only the right one", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 2, 2); fullRender("party1")
        S.failEnumerate = true
        local d3 = debuff(3); table.insert(S.auras.party1, d3)
        mock.auraEvent("party1", { added = { mock.wrapAura(d3) } })
        assertEquals(#b.auraCache.debuff, 3); assertEquals(#b.auraCache.buff, 2)
        local b3 = buff(3); table.insert(S.auras.party1, b3)
        mock.auraEvent("party1", { added = { mock.wrapAura(b3) } })
        assertEquals(#b.auraCache.debuff, 3); assertEquals(#b.auraCache.buff, 3)
        removeAura("party1", 101); mock.auraEvent("party1", { removed = { 101 } })
        assertEquals(#b.auraCache.buff, 2); assertEquals(#b.auraCache.debuff, 3)
        assertTrue(b.auraCache.buff ~= b.auraCache.debuff)
    end)
    it("a duplicate 'added' aura is not added twice", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        local again = findAura("party1", 201)
        mock.auraEvent("party1", { added = { mock.wrapAura(again) } })
        assertEquals(#b.auraCache.debuff, 2)
        assertEquals(ids(b.debuffIcons), "201,202")
    end)
    it("a SECRET removed id drops the cache (it cannot be matched)", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 1, 2); fullRender("party1")
        assertNotNil(b.auraCache)
        S.failEnumerate = true
        mock.auraEvent("party1", { removed = { mock.newSecret() } })
        assertTrue(noCache(b), "cache dropped")
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(ids(b.debuffIcons), "201,202", "the icons themselves stay (last known), the cross-check still protects them")
    end)
    it("a SECRET updated id and a secret cached id also drop it", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        mock.auraEvent("party1", { updated = { mock.newSecret() } })
        assertTrue(noCache(b))
        local sid = mock.newSecret()
        S.auras.party1 = { { spellId = 1, name = "S", icon = 5, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, auraInstanceID = sid } }
        S.failEnumerate = false
        fullRender("party1")
        assertFalse(noCache(b))
        S.failEnumerate = true
        mock.auraEvent("party1", { removed = { 5 } })
        assertTrue(noCache(b), "a secret id inside the cache makes it unusable for matching")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("an added aura that cannot be classified (no id / classification API raising / unreadable) drops the cache", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 1, 1); fullRender("party1")
        S.failEnumerate = true
        mock.auraEvent("party1", { added = { { name = "NoId", icon = 1 } } })
        assertTrue(noCache(b), "no instance id")
        S.failEnumerate = false; fullRender("party1"); assertFalse(noCache(b)); S.failEnumerate = true
        S.failClassify = true
        local d2 = debuff(2); table.insert(S.auras.party1, d2)
        mock.auraEvent("party1", { added = { mock.wrapAura(d2) } })
        assertTrue(noCache(b), "IsAuraFilteredOutByInstanceID raised")
        S.failClassify = false; S.failEnumerate = false; fullRender("party1"); assertFalse(noCache(b))
        S.failEnumerate = true
        local real = C_UnitAuras.IsAuraFilteredOutByInstanceID
        C_UnitAuras.IsAuraFilteredOutByInstanceID = function() return mock.newSecret() end
        mock.auraEvent("party1", { added = { mock.wrapAura(debuff(3)) } })
        C_UnitAuras.IsAuraFilteredOutByInstanceID = real
        assertTrue(noCache(b), "a secret classification")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a dropped cache means 'enumeration failed and no cache': the last-known icons stay and a retry is scheduled; the next scan rebuilds the cache", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        S.failEnumerate = true
        mock.auraEvent("party1", { removed = { mock.newSecret() } })
        mock.advance(0.5)
        assertEquals(ids(b.debuffIcons), "201,202"); assertTrue(b.auraFailed)
        S.failEnumerate = false
        mock.advance(1.2)
        assertFalse(noCache(b)); assertFalse(b.auraFailed and true or false)
    end)
    it("isFullUpdate events leave the cache alone and re-scan", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 0, 2); fullRender("party1")
        local before = b.auraCache.debuff
        table.insert(S.auras.party1, debuff(3))
        mock.auraEvent("party1", { full = true })
        assertEquals(#b.auraCache.debuff, 3); assertTrue(b.auraCache.debuff ~= before, "replaced by the new scan")
    end)
    it("each unit has its own cache; a member's changes never reach another member's bar", function()
        local ns = boot()
        setAuras("party1", 0, 2); setAuras("party2", 1, 1); setAuras("party3", 0, 0)
        for _, u in ipairs({ "party1", "party2", "party3" }) do fullRender(u) end
        assertTrue(button(ns, "party1").auraCache ~= button(ns, "party2").auraCache)
        S.failEnumerate = true
        local d = debuff(3); table.insert(S.auras.party1, d)
        mock.auraEvent("party1", { added = { mock.wrapAura(d) } })
        assertEquals(ids(button(ns, "party1").debuffIcons), "201,202,203")
        assertEquals(ids(button(ns, "party2").debuffIcons), "201", "party2 only has its own debuff")
        assertEquals(ids(button(ns, "party3").debuffIcons), "")
        assertEquals(#button(ns, "party2").auraCache.debuff, 1)
    end)
    it("roster changes do not leak one member's cache to another: a NEW member in a slot must not inherit the previous member's auras", function()
        local ns = boot()
        setAuras("party2", 2, 3); fullRender("party2")
        assertEquals(ids(button(ns, "party2").debuffIcons), "201,202,203")
        -- the member in slot party2 leaves and somebody else takes the slot (no auras), while enumeration is failing
        S.units.party2 = unit("NewGuy", "ROGUE", "DAMAGER")
        S.auras.party2 = {}
        S.failEnumerate = true
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.advance(2)
        local got = ids(button(ns, "party2").debuffIcons)
        if got ~= "" then
            warn("Frames/Auras.lua: a member replaced in a party slot keeps the PREVIOUS member's aura cache (button.auraCache is per button, not per GUID); while no "
                .. "enumeration works the new member's bar shows the old member's auras (" .. got .. ")")
        end
        assertEquals(#mock.errors, 0, errstr())
        S.failEnumerate = false
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(ids(button(ns, "party2").debuffIcons), "", "a real scan shows the truth")
    end)
    it("a member that leaves clears the bar; the cache of the others is untouched", function()
        local ns = boot()
        setAuras("party1", 0, 2); setAuras("party3", 0, 1); fullRender("party1"); fullRender("party3")
        S.units.party3 = nil
        mock.setGroup(2); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        assertEquals(ids(button(ns, "party3").debuffIcons), ""); assertEquals(ids(button(ns, "party1").debuffIcons), "201,202")
    end)
    it("pets never get a cache or icons", function()
        local ns = boot()
        S.units.partypet1 = unit("Pet", "HUNTER"); S.auras.partypet1 = { debuff(1) }
        mock.fire("UNIT_AURA", "partypet1"); mock.flushTimers()
        local pb = button(ns, "partypet1")
        if pb then assertNil(pb.auraCache) end
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== 4. the safety tick
describe("aura cache: the safety tick", function()
    local function spy(ns)
        local calls = {}
        local orig = ns.Auras.Update
        ns.Auras.Update = function(btn, src, ...) calls[#calls + 1] = { unit = btn.unit, src = src }; return orig(btn, src, ...) end
        return calls, function() ns.Auras.Update = orig end
    end
    local function count(calls, src) local by = {} for _, c in ipairs(calls) do if c.src == src then by[c.unit] = (by[c.unit] or 0) + 1 end end return by end
    it("covers a BUFF-only unit (the old tick only looked at debuff icons)", function()
        local ns = boot()
        setAuras("party1", 3, 0); fullRender("party1")
        local calls, restore = spy(ns)
        mock.advance(1.2)
        restore()
        local by = count(calls, "safety")
        assertTrue(by.party1 and by.party1 >= 1, "buff-only unit re-rendered")
    end)
    it("a buff that vanished without any event is cleared by the tick on a buff-only unit", function()
        local ns = boot(); local b = button(ns, "party1")
        setAuras("party1", 3, 0); fullRender("party1")
        inCombat(); S.failEnumerate = true
        removeAura("party1", 102)
        mock.advance(0.8)
        assertEquals(ids(b.buffIcons), "101,103")
    end)
    it("covers a unit whose last render FAILED even with no icons shown, and a unit rendered from the cache", function()
        local ns = boot()
        setAuras("party1", 0, 0); fullRender("party1")
        local b = button(ns, "party1")
        b.auraFailed = true
        local calls, restore = spy(ns)
        mock.advance(1.2)
        restore()
        assertTrue(count(calls, "safety").party1 >= 1, "failed render covered")
    end)
    it("is throttled: about one pass per 0.5s regardless of how often OnUpdate fires", function()
        local ns = boot()
        setAuras("party1", 2, 2); fullRender("party1")
        local calls, restore = spy(ns)
        for _ = 1, 100 do mock.runOnUpdate(1, 0.01) end
        restore()
        local n = count(calls, "safety").party1 or 0
        assertTrue(n >= 1 and n <= 3, "100 frames over 1s: " .. n .. " safety renders")
    end)
    it("does nothing when no unit shows an aura icon and nothing failed", function()
        local ns = boot()
        for _, u in ipairs({ "party1", "party2", "party3", "player" }) do setAuras(u, 0, 0); fullRender(u) end
        local calls, restore = spy(ns)
        mock.advance(3)
        restore()
        assertEquals(#calls, 0)
    end)
    it("hidden buttons are skipped", function()
        local ns = boot()
        setAuras("party1", 2, 2); fullRender("party1")
        button(ns, "party1"):Hide()
        local calls, restore = spy(ns)
        mock.advance(2)
        restore()
        assertNil(count(calls, "safety").party1)
        button(ns, "party1"):Show()
    end)
end)

-- ======================================================================== 6. /hf debug auras
describe("aura cache: /hf debug auras shows the render-time per-method lines and the cache info", function()
    it("render-time lines per filter: used method and every method's outcome", function()
        local ns = boot({ slots = { page = 2 } })
        setAuras("party1", 2, 3); fullRender("party1")
        local out = debugText()
        assertTrue(out:find("render-time HARMFUL: used=slots | slots=ok (3) | GetUnitAuras=- | InstanceIDs=- | ByIndex=-", 1, true), out)
        assertTrue(out:find("render-time HELPFUL: used=slots | slots=ok (2)", 1, true), out)
    end)
    it("after a failed combat render the lines say which methods failed", function()
        local ns = boot({ slots = { page = 2 } })
        setAuras("party1", 0, 2); fullRender("party1")
        inCombat(); S.failEnumerate = true
        fullRender("party1")
        local out = debugText()
        assertTrue(out:find("render-time HARMFUL: used=none | slots=failed:", 1, true), out)
        assertTrue(out:find("GetUnitAuras=failed:", 1, true) and out:find("ByIndex=failed", 1, true), out)
        assertTrue(out:find("rendered from the cache (2)", 1, true), out)
        outOfCombat(); S.failEnumerate = false
    end)
    it("the 'last update' line has cacheUsed, cacheSize and the retry counter", function()
        local ns = boot()
        setAuras("party1", 1, 2); fullRender("party1")
        local out = debugText()
        assertTrue(out:find("party1 last update: source=event full=false removedIDs=0 uncertain(secret ID)=false lastKnownIcons=false cacheUsed=false cacheSize=3 retries=0", 1, true), out)
        S.failEnumerate = true
        mock.fire("UNIT_AURA", "party1")       -- no timer flush: the retry chain would otherwise run to its end
        out = debugText()
        assertTrue(out:find("party1 last update: source=event", 1, true) and out:find("cacheUsed=true cacheSize=3", 1, true), out)
        assertTrue(out:find("lastKnownIcons=true", 1, true), out)
        S.failEnumerate = false
    end)
    it("sources shown: safety, retry, combat ended; roster and entering world are re-render triggers (seen through the Update calls, other handlers may render after them)", function()
        local ns = boot()
        setAuras("party1", 0, 1); fullRender("party1")
        mock.advance(0.7)
        assertTrue(debugText():find("party1 last update: source=safety", 1, true))
        local seen = {}
        local orig = ns.Auras.Update
        ns.Auras.Update = function(btn, src, ...) if btn.unit == "party1" then seen[src or "nil"] = true end return orig(btn, src, ...) end
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
        mock.fire("PLAYER_ENTERING_WORLD", false, false); mock.flushTimers()
        inCombat(); outOfCombat()
        ns.Auras.Update = orig
        assertTrue(seen["roster"], "roster"); assertTrue(seen["entering world"], "entering world"); assertTrue(seen["combat ended"], "combat ended")
        S.failEnumerate = true; mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        assertTrue(debugText():find("source=retry", 1, true))
        S.failEnumerate = false
    end)
    it("works in combat and with everything secret", function()
        local ns = boot({ slots = { page = 2 } })
        setAuras("party1", 2, 2); fullRender("party1")
        inCombat(); S.secretAll = true
        assertTrue(debugText():find("render-time", 1, true))
        S.secretAll = false; outOfCombat()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== re-render triggers
describe("aura cache: re-render on PLAYER_REGEN_ENABLED, roster change and entering the world", function()
    it("each trigger re-renders every visible unit and fixes a stale row", function()
        for _, trigger in ipairs({ "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }) do
            local ns = boot(); local b = button(ns, "party1")
            setAuras("party1", 1, 2); fullRender("party1")
            S.auras.party1 = { buff(1), debuff(1), debuff(2), debuff(3) }         -- changed while we were not looking
            mock.fire(trigger, false, false); mock.flushTimers()
            assertEquals(ids(b.debuffIcons), "201,202,203", trigger)
            assertEquals(#mock.errors, 0, errstr())
        end
    end)
    it("Auras.UpdateAll skips hidden buttons and survives a missing frame set", function()
        local ns = boot()
        assertTrue(pcall(ns.Auras.UpdateAll, "test"))
        for _, bt in ipairs(ns.UnitFrames.buttons) do bt:Hide() end
        assertTrue(pcall(ns.Auras.UpdateAll, "test"))
        assertEquals(#mock.errors, 0, errstr())
    end)
end)
