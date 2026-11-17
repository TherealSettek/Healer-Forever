-- Per-icon aura tooltips: fallback chain, filters, leave/return behaviour, mouse handling, combat safety.
local L = require("loader")
local mock = require("wow_mock")

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

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.player.class = "PALADIN"
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER")
    if opts.setup then opts.setup() end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(2)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local function btn(ns, u) return ns.UnitFrames.byUnit[u] end
local function setAuras(u, nBuff, nDebuff, base)
    base = base or 0
    local list = {}
    for i = 1, nBuff do list[#list + 1] = { spellId = 8000 + i + base, name = "Buff " .. (i + base), icon = i, duration = 600, expirationTime = S.now + 300, isHelpful = true, auraInstanceID = 2000 + i + base, sourceUnit = "player" } end
    for i = 1, nDebuff do list[#list + 1] = { spellId = 7000 + i + base, name = "Debuff " .. (i + base), icon = i, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, dispelName = "Magic", auraInstanceID = 1000 + i + base, sourceUnit = "party2" } end
    S.auras[u] = list
end
local function update(u) mock.fire("UNIT_AURA", u or "party1"); mock.flushTimers(); mock.runOnUpdate(1, 0.2) end

-- recording tooltip
local rec
local function recorder(opts)
    opts = opts or {}
    rec = { calls = {}, lines = {}, owners = 0, shows = 0, hides = 0 }
    local gt = _G.GameTooltip
    gt.SetOwner = function() rec.owners = rec.owners + 1; rec.lines = {} end
    gt.Show = function() rec.shows = rec.shows + 1 end
    gt.Hide = function() rec.hides = rec.hides + 1 end
    gt.AddLine = function(_, text) rec.lines[#rec.lines + 1] = mock.isSecret(text) and "<secret>" or tostring(text) end
    gt.AddDoubleLine = function(_, l, r) rec.lines[#rec.lines + 1] = tostring(l) .. " " .. tostring(r) end
    gt.AddTexture = function() end
    gt.SetUnitBuffByAuraInstanceID = function(_, u, id, filter)
        rec.calls[#rec.calls + 1] = { "buff", u, id, filter }
        if opts.failBuff then error("buff tooltip failed") end
    end
    gt.SetUnitDebuffByAuraInstanceID = function(_, u, id, filter)
        rec.calls[#rec.calls + 1] = { "debuff", u, id, filter }
        if opts.failDebuff then error("debuff tooltip failed") end
    end
    gt.SetUnitAura = function(_, u, index, filter)
        rec.calls[#rec.calls + 1] = { "aura", u, index, filter }
        if opts.failAura then error("SetUnitAura failed") end
    end
end
local function enter(icon) st(icon).scripts.OnEnter(icon) end
local function leave(icon) st(icon).scripts.OnLeave(icon) end
local function joined() return table.concat(rec.lines, "\n") end

-- ======================================================================== fallback chain
describe("icon tips: the fallback chain", function()
    local ns = boot()
    setAuras("party1", 3, 4); update()
    local b = btn(ns, "party1")
    it("icons exist for every aura and carry the data needed for the tooltip", function()
        assertEquals(#mock.errors, 0, errstr())
        local d = b.debuffIcons[2]
        assertEquals(d.unit, "party1"); assertNotNil(d.auraInstanceID); assertEquals(d.auraIndex, 2); assertEquals(d.filter, "HARMFUL")
        assertEquals(d.auraName, "Debuff 2")
        assertEquals(b.buffIcons[1].filter, "HELPFUL")
    end)
    it("debuff icon -> SetUnitDebuffByAuraInstanceID with unit, id and filter (and nothing else)", function()
        recorder()
        local icon = b.debuffIcons[2]
        enter(icon)
        assertEquals(#rec.calls, 1)
        assertEquals(rec.calls[1][1], "debuff"); assertEquals(rec.calls[1][2], "party1"); assertEquals(rec.calls[1][3], icon.auraInstanceID); assertEquals(rec.calls[1][4], "HARMFUL")
        assertEquals(rec.shows, 1); assertEquals(rec.owners, 1)
        assertEquals(ns.Auras.hoveredIcon, icon)
    end)
    it("buff icon -> SetUnitBuffByAuraInstanceID", function()
        recorder()
        local icon = b.buffIcons[3]
        enter(icon)
        assertEquals(#rec.calls, 1); assertEquals(rec.calls[1][1], "buff"); assertEquals(rec.calls[1][3], icon.auraInstanceID); assertEquals(rec.calls[1][4], "HELPFUL")
        assertEquals(rec.shows, 1)
    end)
    it("the filter follows 'only my buffs' and 'only dispellable debuffs'", function()
        ns.db.auras.onlyMine = true; ns.db.auras.onlyDispellable = true
        update()
        recorder()
        enter(b.buffIcons[1]); enter(b.debuffIcons[1])
        assertEquals(rec.calls[1][4], "HELPFUL|PLAYER"); assertEquals(rec.calls[2][4], "HARMFUL|RAID_PLAYER_DISPELLABLE")
        ns.db.auras.onlyMine = false; ns.db.auras.onlyDispellable = false; update()
        recorder(); enter(b.buffIcons[1]); enter(b.debuffIcons[1])
        assertEquals(rec.calls[1][4], "HELPFUL"); assertEquals(rec.calls[2][4], "HARMFUL")
    end)
    it("the instance id is passed untouched in combat with secret values", function()
        S.combat = true; S.secret = true; mock.fire("PLAYER_REGEN_DISABLED"); update()
        recorder()
        local icon = b.debuffIcons[1]
        assertEquals(#mock.errors, 0, errstr())
        enter(icon)
        assertEquals(rec.calls[1][1], "debuff"); assertEquals(type(rec.calls[1][3]), "number"); assertEquals(rec.shows, 1)
        S.combat = false; S.secret = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers(); update()
    end)
    it("the by-instance-id method errors -> SetUnitAura(unit, index, filter)", function()
        recorder({ failDebuff = true })
        local icon = b.debuffIcons[3]
        enter(icon)
        assertEquals(#rec.calls, 2)
        assertEquals(rec.calls[1][1], "debuff"); assertEquals(rec.calls[2][1], "aura")
        assertEquals(rec.calls[2][2], "party1"); assertEquals(rec.calls[2][3], 3); assertEquals(rec.calls[2][4], "HARMFUL")
        assertEquals(rec.shows, 1)
        recorder({ failBuff = true }); enter(b.buffIcons[2])
        assertEquals(rec.calls[2][1], "aura"); assertEquals(rec.calls[2][3], 2); assertEquals(rec.calls[2][4], "HELPFUL")
    end)
    it("the by-instance-id methods are missing from the client -> SetUnitAura", function()
        recorder()
        mock.missingMethods.SetUnitDebuffByAuraInstanceID = true; mock.missingMethods.SetUnitBuffByAuraInstanceID = true
        _G.GameTooltip.SetUnitDebuffByAuraInstanceID = nil; _G.GameTooltip.SetUnitBuffByAuraInstanceID = nil
        enter(b.debuffIcons[1])
        assertEquals(rec.calls[#rec.calls][1], "aura")
        assertEquals(rec.shows, 1)
        mock.missingMethods = {}
    end)
    it("both fail -> the plain name line is shown (and Show is called)", function()
        recorder({ failDebuff = true, failAura = true })
        enter(b.debuffIcons[1])
        assertEquals(#rec.calls, 2)
        assertNotNil(joined():find("Debuff 1", 1, true), joined())
        assertEquals(rec.shows, 1)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("SetUnitAura missing as well -> name line", function()
        recorder({ failDebuff = true })
        mock.missingMethods.SetUnitAura = true; _G.GameTooltip.SetUnitAura = nil
        enter(b.debuffIcons[2])
        assertNotNil(joined():find("Debuff 2", 1, true))
        mock.missingMethods = {}
    end)
    it("no instance id at all -> goes straight to SetUnitAura", function()
        recorder()
        local icon = b.debuffIcons[1]
        local saved = icon.auraInstanceID
        icon.auraInstanceID = nil
        enter(icon)
        assertEquals(rec.calls[1][1], "aura")
        icon.auraInstanceID = saved
    end)
    it("a secret name falls through to the tooltip untouched (no inspection) and errors are contained", function()
        recorder({ failDebuff = true, failAura = true })
        local icon = b.debuffIcons[1]
        local saved = icon.auraName
        icon.auraName = mock.newSecret()
        enter(icon)
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(rec.shows, 1)
        icon.auraName = saved
    end)
    it("when every step fails nothing is shown and no error escapes", function()
        recorder({ failDebuff = true, failAura = true })
        _G.GameTooltip.AddLine = function() error("AddLine refused") end
        enter(b.debuffIcons[1])
        assertEquals(rec.shows, 0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("an icon without a unit (never rendered) is ignored", function()
        recorder()
        local icon = b.debuffIcons[1]
        local u = icon.unit; icon.unit = nil
        assertTrue(pcall(enter, icon))
        assertEquals(#rec.calls, 0)
        icon.unit = u
    end)
    it("a debuff icon never uses the BUFF method, even when the debuff method is absent (latent and/or pitfall)", function()
        recorder()
        mock.missingMethods.SetUnitDebuffByAuraInstanceID = true; _G.GameTooltip.SetUnitDebuffByAuraInstanceID = nil
        enter(b.debuffIcons[1])
        local usedBuff = false
        for _, c in ipairs(rec.calls) do if c[1] == "buff" then usedBuff = true end end
        mock.missingMethods = {}
        assertFalse(usedBuff, "a debuff icon must never fall back to the BUFF tooltip method")
    end)
end)

-- ======================================================================== leave / return of the bar tooltip
describe("icon tips: OnLeave and the bar tooltip", function()
    local ns = boot()
    setAuras("party1", 2, 3); update()
    local b = btn(ns, "party1")
    local function hoverBar() st(b).hooks.OnEnter[1](b) end
    it("OnLeave hides the tooltip and clears the hovered icon", function()
        recorder()
        local icon = b.debuffIcons[1]
        enter(icon)
        leave(icon)
        assertEquals(rec.hides, 1); assertNil(ns.Auras.hoveredIcon)
    end)
    it("the bar tooltip returns if the mouse is still over the bar", function()
        recorder()
        hoverBar()
        assertNotNil(joined():find("Click-casting", 1, true))
        enter(b.debuffIcons[1])
        rec.lines = {}
        leave(b.debuffIcons[1])
        assertNotNil(joined():find("Click-casting", 1, true), "bar tooltip must be shown again:\n" .. joined())
        assertEquals(ns.UnitFrames.hovered, b)
    end)
    it("no bar tooltip when the mouse is not over the bar", function()
        recorder()
        st(b).hooks.OnLeave[1](b)
        assertNil(ns.UnitFrames.hovered)
        enter(b.debuffIcons[1]); rec.lines = {}
        leave(b.debuffIcons[1])
        assertNil(joined():find("Click-casting", 1, true))
    end)
    it("leaving the icon for another icon: the second tooltip is shown, the hovered icon is the new one", function()
        recorder()
        local i1, i2 = b.debuffIcons[1], b.debuffIcons[2]
        enter(i1); enter(i2)
        assertEquals(ns.Auras.hoveredIcon, i2)
        leave(i1)
        assertEquals(ns.Auras.hoveredIcon, i2, "leaving a stale icon must not clear the current one")
        leave(i2)
        assertNil(ns.Auras.hoveredIcon)
    end)
end)

describe("icon tips: an icon tooltip is not overwritten by the bar", function()
    local ns = boot()
    setAuras("party1", 2, 3); update()
    local b = btn(ns, "party1")
    it("the 0.5s bar refresh and UNIT_AURA leave the icon tooltip alone", function()
        recorder()
        st(b).hooks.OnEnter[1](b)                  -- mouse on the bar, then slides onto an icon
        local icon = b.debuffIcons[1]
        enter(icon)
        local owners, shows, lines = rec.owners, rec.shows, #rec.lines
        mock.runOnUpdate(6, 0.3)                     -- anchor OnUpdate refresh (0.5s tick)
        mock.fire("UNIT_AURA", "party1"); mock.fire("MODIFIER_STATE_CHANGED", "LSHIFT", 1); mock.flushTimers()
        assertEquals(rec.owners, owners, "bar refresh must not re-own the tooltip")
        assertEquals(rec.shows, shows); assertEquals(#rec.lines, lines)
        assertEquals(ns.Auras.hoveredIcon, icon)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("after leaving the icon the bar tooltip refreshes again", function()
        local icon = b.debuffIcons[1]
        leave(icon)
        local owners = rec.owners
        mock.runOnUpdate(6, 0.3)
        assertTrue(rec.owners > owners, "bar tooltip refresh resumed")
    end)
end)

-- ======================================================================== mouse handling
describe("icon tips: mouse handling and the option", function()
    local function allIcons(ns, u)
        local out = {}
        local b = btn(ns, u)
        for _, list in ipairs({ b.buffIcons, b.debuffIcons }) do for _, i in ipairs(list) do out[#out + 1] = i end end
        return out
    end
    it("option off: no icon takes the mouse (every position)", function()
        local ns = boot()
        ns.db.auras.tooltipIcons = false
        for _, pos in ipairs(ns.Util.POSITIONS) do
            ns.db.auras.buffPosition, ns.db.auras.debuffPosition = pos, pos
            ns:Changed("frames"); mock.flushTimers()
            for _, u in ipairs({ "player", "party1", "party4" }) do
                for _, icon in ipairs(allIcons(ns, u)) do assertFalse(st(icon).mouse, u .. " " .. pos) end
            end
        end
    end)
    it("option on: outside icons take the mouse and do not propagate", function()
        local ns = boot()
        ns.db.auras.tooltipIcons = true
        for _, pos in ipairs({ "top", "bottom", "left", "right" }) do
            ns.db.auras.buffPosition, ns.db.auras.debuffPosition = pos, pos
            ns:Changed("frames"); mock.flushTimers()
            for _, icon in ipairs(allIcons(ns, "party1")) do assertTrue(st(icon).mouse, pos) end
        end
    end)
    it("option on: inside-bar icons take the mouse AND propagate clicks and motion", function()
        local ns = boot()
        ns.db.auras.buffPosition, ns.db.auras.debuffPosition = "inside", "inside"
        ns:Changed("frames"); mock.flushTimers()
        for _, u in ipairs({ "player", "party1", "party3" }) do
            for _, icon in ipairs(allIcons(ns, u)) do
                assertTrue(st(icon).mouse, u); assertTrue(st(icon).propClicks, "clicks must pass through to the secure unit button")
                assertTrue(st(icon).propMotion, "motion must pass through (the bar keeps its hover and tooltip)")
            end
        end
    end)
    it("without SetPropagateMouseClicks inside-bar icons take no mouse (never block click-casting)", function()
        local ns = boot({ setup = function() mock.missingMethods.SetPropagateMouseClicks = true end })
        ns.db.auras.buffPosition, ns.db.auras.debuffPosition = "inside", "bottom"
        ns:Changed("frames"); mock.flushTimers()
        for _, icon in ipairs(btn(ns, "party1").buffIcons) do assertFalse(st(icon).mouse, "inside icon without propagation") end
        for _, icon in ipairs(btn(ns, "party1").debuffIcons) do assertTrue(st(icon).mouse, "outside icons still take it") end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("SetPropagateMouseMotion missing but clicks present: still propagates clicks and keeps the mouse", function()
        local ns = boot({ setup = function() mock.missingMethods.SetPropagateMouseMotion = true end })
        ns.db.auras.buffPosition = "inside"
        ns:Changed("frames"); mock.flushTimers()
        for _, icon in ipairs(btn(ns, "party1").buffIcons) do assertTrue(st(icon).propClicks); assertTrue(st(icon).mouse) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("changing a position from inside to outside releases the propagation-only restrictions (mouse stays on)", function()
        local ns = boot()
        ns.db.auras.buffPosition = "inside"; ns:Changed("frames"); mock.flushTimers()
        ns.db.auras.buffPosition = "top"; ns:Changed("frames"); mock.flushTimers()
        for _, icon in ipairs(btn(ns, "party1").buffIcons) do assertTrue(st(icon).mouse) end
    end)
    it("icons never intercept clicks meant for the secure button: the unit button keeps its click registration", function()
        local ns = boot()
        for _, icon in ipairs(allIcons(ns, "party1")) do assertNil(st(icon).scripts.OnClick); assertNil(st(icon).scripts.OnMouseDown) end
    end)
    it("zones themselves never take the mouse", function()
        local ns = boot()
        for _, k in ipairs({ "buff", "debuff" }) do assertFalse(st(btn(ns, "party1").zones[k]).mouse == true) end
    end)
end)

describe("icon tips: icons are pre-created and nothing is configured in combat", function()
    it("every icon up to the configured maxima exists after layout, before any aura", function()
        local ns = boot()
        for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
            assertTrue(#btn(ns, u).buffIcons >= ns.db.auras.maxBuffs, u); assertTrue(#btn(ns, u).debuffIcons >= ns.db.auras.maxDebuffs, u)
        end
        ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = 8, 6; ns:Changed("frames"); mock.flushTimers()
        assertTrue(#btn(ns, "party2").buffIcons >= 8); assertTrue(#btn(ns, "party2").debuffIcons >= 6)
    end)
    it("pets never get aura icons", function()
        local ns = boot()
        assertEquals(#(btn(ns, "partypet1").buffIcons or {}), 0)
    end)
    it("in combat no EnableMouse / SetPropagate* / CreateFrame happens, even with more auras than icons", function()
        local ns = boot()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local n0, c0 = #mock.calls, #mock.createdInCombat
        setAuras("party1", 20, 20)
        ns.db.auras.tooltipIcons = false; ns.db.auras.buffPosition = "inside"; ns:Changed("frames")
        mock.fire("UNIT_AURA", "party1"); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(3, 0.3)
        local iconSet = {}
        for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
            for _, list in ipairs({ btn(ns, u).buffIcons, btn(ns, u).debuffIcons }) do for _, ic in ipairs(list) do iconSet[ic] = true end end
        end
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(iconSet[c.obj] and (c.method == "EnableMouse" or c.method == "SetPropagateMouseClicks" or c.method == "SetPropagateMouseMotion"),
                "forbidden call on an aura icon in combat: " .. c.method)
        end
        assertEquals(#mock.createdInCombat, c0, "no frame may be created in combat")
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
    it("Prepare is queued: it runs after combat and applies the new mouse configuration then", function()
        local ns = boot()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        ns.db.auras.tooltipIcons = false; ns:Changed("frames"); mock.flushTimers()
        local icon = btn(ns, "party1").buffIcons[1]
        assertTrue(st(icon).mouse, "unchanged during combat")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertFalse(st(icon).mouse, "applied after combat")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a layout pass out of combat DOES configure the mouse (sanity for the combat checks)", function()
        local ns = boot()
        local n0 = #mock.calls
        ns:Changed("frames"); mock.flushTimers()
        local did = false
        for i = n0 + 1, #mock.calls do if mock.calls[i].method == "EnableMouse" then did = true end end
        assertTrue(did)
    end)
end)

describe("icon tips: the option saves and survives a reload", function()
    it("the checkbox writes auras.tooltipIcons, applies live, and the value is restored after a reload", function()
        local ns = boot()
        assertEquals(ns.db.auras.tooltipIcons, true)
        ns.Options:Show("auras"); mock.flushTimers()
        local cb
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "CheckButton" and f.label and st(f.label).text == "Show tooltip when hovering buff/debuff icons" then cb = f end
        end
        assertNotNil(cb)
        st(cb).checked = false; st(cb).scripts.OnClick(cb); mock.flushTimers()
        assertEquals(ns.db.auras.tooltipIcons, false)
        for _, icon in ipairs(btn(ns, "party1").buffIcons) do assertFalse(st(icon).mouse) end
        local ns2 = boot({ char = HealerForeverCharDB })
        assertEquals(ns2.db.auras.tooltipIcons, false)
        for _, icon in ipairs(btn(ns2, "party1").buffIcons) do assertFalse(st(icon).mouse) end
        ns2.Options:Show("auras"); mock.flushTimers()
        st(cb)
        local cb2
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "CheckButton" and f.label and st(f.label).text == "Show tooltip when hovering buff/debuff icons" then cb2 = f end
        end
        assertFalse(st(cb2).checked)
    end)
    it("a saved variable without the key defaults to on; a corrupted value is replaced", function()
        local ns = boot({ char = { version = 2, auras = { maxBuffs = 3 } } })
        assertEquals(ns.db.auras.tooltipIcons, true)
        local ns2 = boot({ char = { version = 2, auras = { tooltipIcons = "yes" } } })
        assertEquals(type(ns2.db.auras.tooltipIcons), "boolean")
    end)
end)

describe("icon tips: reused icons show the new aura", function()
    it("an icon reused for a different aura carries the new instance id, name and index", function()
        local ns = boot()
        setAuras("party1", 0, 3); update()
        recorder()
        local icon = btn(ns, "party1").debuffIcons[1]
        local oldId = icon.auraInstanceID
        setAuras("party1", 0, 3, 50); update()
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(icon.auraInstanceID ~= oldId)
        assertEquals(icon.auraName, "Debuff 51")
        enter(icon)
        assertEquals(rec.calls[1][3], icon.auraInstanceID); assertEquals(rec.calls[1][1], "debuff")
    end)
    it("when the list shrinks the hidden icons are not hoverable targets (hidden) and the survivors keep correct data", function()
        local ns = boot()
        ns.db.auras.maxDebuffs = 4; ns:Changed("frames"); mock.flushTimers()
        setAuras("party1", 0, 4); update()
        setAuras("party1", 0, 2, 20); update()
        local list = btn(ns, "party1").debuffIcons
        assertTrue(st(list[1]).shown and st(list[2]).shown)
        assertFalse(st(list[3]).shown); assertFalse(st(list[4]).shown)
        assertEquals(list[2].auraName, "Debuff 22"); assertEquals(list[2].auraIndex, 2)
    end)
    it("a buff icon and a debuff icon never swap kinds when reused", function()
        local ns = boot()
        setAuras("party1", 2, 2); update()
        local b = btn(ns, "party1")
        for _, i in ipairs(b.buffIcons) do assertFalse(i.isDebuff == true) end
        for _, i in ipairs(b.debuffIcons) do assertTrue(i.isDebuff == true) end
        setAuras("party1", 0, 4); update()
        for _, i in ipairs(b.buffIcons) do assertFalse(i.isDebuff == true) end
    end)
    it("hovering an icon whose aura disappeared while the tooltip is up does not error", function()
        local ns = boot()
        setAuras("party1", 0, 2); update()
        recorder()
        local icon = btn(ns, "party1").debuffIcons[1]
        enter(icon)
        setAuras("party1", 0, 0); update()
        assertEquals(#mock.errors, 0, errstr())
        leave(icon)
        assertNil(ns.Auras.hoveredIcon)
    end)
end)
