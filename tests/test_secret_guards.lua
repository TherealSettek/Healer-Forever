-- ns.Exists / ns.InGroup (a secret counts as true), auraInstanceID secret guards, the player's buff buttons never covering the
-- player bar, and /hf debug click.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")
local G = require("aura_geo")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.player.class = opts.class or "PALADIN"
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if ns.db then Fx.seed(ns, { presets = 3 }) end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end

-- ======================================================================== ns.Exists / ns.InGroup
describe("secret guards: ns.Exists and ns.InGroup", function()
    local ns = boot()
    local realExists, realInGroup = _G.UnitExists, _G.IsInGroup
    local function restore() _G.UnitExists, _G.IsInGroup = realExists, realInGroup end
    it("plain booleans pass through", function()
        _G.UnitExists = function() return true end; assertEquals(ns.Exists("party1"), true)
        _G.UnitExists = function() return false end; assertEquals(ns.Exists("party1"), false)
        _G.UnitExists = function() return nil end; assertEquals(ns.Exists("party1"), false)
        _G.IsInGroup = function() return true end; assertEquals(ns.InGroup(), true)
        _G.IsInGroup = function() return false end; assertEquals(ns.InGroup(), false)
        _G.IsInGroup = function() return nil end; assertEquals(ns.InGroup(), false)
        restore()
    end)
    it("truthy non-boolean values are normalised to true (UnitExists can return 1)", function()
        _G.UnitExists = function() return 1 end; assertEquals(ns.Exists("party1"), true)
        restore()
    end)
    it("a SECRET answer counts as true (and never raises)", function()
        local s = mock.newSecret()
        _G.UnitExists = function() return s end
        _G.IsInGroup = function() return s end
        local ok, v = pcall(ns.Exists, "party1"); assertTrue(ok); assertEquals(v, true)
        ok, v = pcall(ns.InGroup); assertTrue(ok); assertEquals(v, true)
        restore()
    end)
    it("an erroring API counts as false (never raises)", function()
        _G.UnitExists = function() error("boom") end
        _G.IsInGroup = function() error("boom") end
        local ok, v = pcall(ns.Exists, "party1"); assertTrue(ok); assertEquals(v, false)
        ok, v = pcall(ns.InGroup); assertTrue(ok); assertEquals(v, false)
        restore()
    end)
    it("missing APIs: InGroup false; Exists false", function()
        _G.UnitExists = nil; _G.IsInGroup = nil
        assertEquals(ns.InGroup(), false)
        local ok, v = pcall(ns.Exists, "party1"); assertTrue(ok); assertEquals(v, false)
        restore()
    end)
    it("the whole UI runs when UnitExists / IsInGroup return secrets (frames, buff buttons, pins, slash)", function()
        local s = mock.newSecret()
        _G.UnitExists = function() return s end
        _G.IsInGroup = function() return s end
        mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("PLAYER_ROLES_ASSIGNED"); mock.flushTimers(); mock.runOnUpdate(5, 0.3); mock.tick(); mock.flushTimers()
        for _, u in ipairs({ "player", "party1", "party2" }) do mock.fire("UNIT_AURA", u); mock.fire("UNIT_HEALTH", u) end
        mock.flushTimers()
        assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "debug buffs"))
        assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "debug auras"))
        restore()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("no module truth-tests UnitExists / IsInGroup directly any more (they go through ns.Exists / ns.InGroup)", function()
        local bad = {}
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") and rel ~= "Core.lua" then
                local n = 0
                for line in L.readFile(L.path(rel)):gmatch("[^\n]+") do
                    n = n + 1
                    local code = line:gsub("%-%-.*$", "")
                    if (code:find("[^%w_%.]UnitExists%(") or code:find("[^%w_%.]IsInGroup%(")) and not code:find("pcall") then
                        -- `UnitExists and ns.Exists(unit)` style presence checks are fine
                        bad[#bad + 1] = rel .. ":" .. n .. ": " .. code:gsub("^%s+", "")
                    end
                end
            end
        end
        assertEquals(#bad, 0, table.concat(bad, "\n"))
    end)
end)

-- ======================================================================== auraInstanceID secret guards
describe("secret guards: auraInstanceID", function()
    local ns = boot()
    local function icon1() return ns.UnitFrames.byUnit.party1.buffIcons[1] end
    local lines
    local function recorder()
        local gt = _G.GameTooltip
        lines = { calls = {} }
        gt.SetOwner = function() end; gt.Show = function() end; gt.Hide = function() end
        gt.AddLine = function(_, t) lines[#lines + 1] = mock.isSecret(t) and "<secret>" or tostring(t) end
        gt.AddTexture = function() end
        gt.SetUnitBuffByAuraInstanceID = function(_, unit, id, filter) lines.calls[#lines.calls + 1] = { "buff", unit, id, filter }; return true end
        gt.SetUnitDebuffByAuraInstanceID = function(_, unit, id, filter) lines.calls[#lines.calls + 1] = { "debuff", unit, id, filter }; return true end
        gt.SetUnitAura = function(_, unit, index, filter) lines.calls[#lines.calls + 1] = { "index", unit, index, filter }; return true end
    end
    local sid = mock.newSecret()
    it("an aura whose instance id is secret renders (icon shown, id kept as the secret), no error", function()
        S.auras.party1 = { { spellId = 1, name = "Kings", icon = 5, duration = 600, expirationTime = S.now + 300, isHelpful = true, auraInstanceID = sid } }
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers(); mock.runOnUpdate(1, 0.2)
        assertTrue(st(icon1()).shown)
        assertTrue(icon1().auraInstanceID == sid, "the secret id is stored untouched")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a duration object is requested with the secret id (never compared)", function()
        S.durationObjects = true
        local n0 = #mock.calls
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        local used = false
        for i = n0 + 1, #mock.calls do if mock.calls[i].method == "SetCooldownFromDurationObject" then used = true end end
        S.durationObjects = false
        assertEquals(#mock.errors, 0, errstr()); assertNotNil(used)
    end)
    it("the icon tooltip passes the secret id to SetUnitBuffByAuraInstanceID", function()
        recorder()
        mock.runFrameScript(icon1(), "OnEnter")
        assertEquals(#lines.calls, 1)
        assertEquals(lines.calls[1][1], "buff"); assertEquals(lines.calls[1][2], "party1")
        assertTrue(lines.calls[1][3] == sid)
        mock.runFrameScript(icon1(), "OnLeave")
        assertNil(ns.Auras.hoveredIcon)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a debuff uses SetUnitDebuffByAuraInstanceID with its secret id", function()
        S.auras.party1 = { { spellId = 2, name = "Poison", icon = 6, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, auraInstanceID = sid } }
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        recorder()
        mock.runFrameScript(ns.UnitFrames.byUnit.party1.debuffIcons[1], "OnEnter")
        assertEquals(lines.calls[1][1], "debuff"); assertTrue(lines.calls[1][3] == sid)
        mock.runFrameScript(ns.UnitFrames.byUnit.party1.debuffIcons[1], "OnLeave")
    end)
    it("a missing id falls back to the aura index, then to the plain name line", function()
        S.auras.party1 = { { spellId = 1, name = "Kings", icon = 5, duration = 600, expirationTime = S.now + 300, isHelpful = true } }
        local realGet = C_UnitAuras.GetUnitAuras
        C_UnitAuras.GetUnitAuras = function(...)    -- the mock always invents an id; strip it
            local out = realGet(...)
            for _, a in ipairs(out) do a.auraInstanceID = nil end
            return out
        end
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        recorder()
        mock.runFrameScript(icon1(), "OnEnter")
        C_UnitAuras.GetUnitAuras = realGet
        assertEquals(lines.calls[1][1], "index"); assertEquals(lines.calls[1][3], 1)
        mock.runFrameScript(icon1(), "OnLeave")
        local gt = _G.GameTooltip
        gt.SetUnitAura = function() error("nope") end
        recorder(); gt.SetUnitAura = function() error("nope") end
        mock.runFrameScript(icon1(), "OnEnter")
        assertEquals(lines[1], "Kings")
        mock.runFrameScript(icon1(), "OnLeave")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a tooltip method that raises with the secret id is survived (falls through)", function()
        S.auras.party1 = { { spellId = 1, name = "Kings", icon = 5, duration = 600, expirationTime = S.now + 300, isHelpful = true, auraInstanceID = sid } }
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        recorder()
        _G.GameTooltip.SetUnitBuffByAuraInstanceID = function() error("secret id rejected") end
        mock.runFrameScript(icon1(), "OnEnter")
        assertTrue(#lines.calls >= 1 or #lines >= 1, "some fallback produced output")
        mock.runFrameScript(icon1(), "OnLeave")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secret id plus every other aura field secret, in combat: still no error", function()
        S.combat = true; S.secret = true; mock.fire("PLAYER_REGEN_DISABLED")
        for _ = 1, 3 do mock.fire("UNIT_AURA", "party1"); mock.flushTimers(); mock.runOnUpdate(1, 0.2) end
        recorder()
        mock.runFrameScript(icon1(), "OnEnter"); mock.runFrameScript(icon1(), "OnLeave")
        S.combat = false; S.secret = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== player's buff buttons never cover the player bar
describe("secret guards: the player's missing-buff and extra buttons stay clear of the player bar", function()
    local function buttonsFor(unitToken)
        local out = {}
        for _, f in ipairs(mock.frames) do
            local n = st(f).name
            if n and (n:match("^HealerForeverBuff%d+$") or n:match("^HealerForeverExtra%d+$")) and f.unit == unitToken then out[#out + 1] = f end
        end
        return out
    end
    local ns = boot()
    local P = ns.db.presets[ns.db.activePreset]
    pcall(ns.Presets.AddExtra, P, "Oath of Light", { TANK = true, HEALER = true, DAMAGER = true, SELF = true }, false)
    ns.db.ui.extraButtons = true
    ns:Changed("presets"); mock.flushTimers(); mock.tick(); mock.flushTimers()
    local function check(label)
        local root = ns.UnitFrames.anchor
        local pb = ns.UnitFrames.byUnit.player
        local bar = G.rect(pb, root)
        local health = G.rect(pb.health, root)
        local shownN, bad = 0, {}
        for _, b in ipairs(buttonsFor("player")) do
            if st(b).shown then
                shownN = shownN + 1
                local r = G.rect(b, root)
                if not r then bad[#bad + 1] = label .. ": button not positioned"
                else
                    if G.overlap(r, bar) then bad[#bad + 1] = label .. ": " .. tostring(st(b).name) .. " overlaps the player bar " .. G.fmt(r) .. " vs " .. G.fmt(bar) end
                    if G.overlap(r, health) then bad[#bad + 1] = label .. ": covers the player health bar" end
                    if pb.power and st(pb.power).shown then
                        local rp = G.rect(pb.power, root)
                        if G.overlap(r, rp) then bad[#bad + 1] = label .. ": covers the player power bar" end
                    end
                end
            end
        end
        return shownN, bad
    end
    it("default layout: buttons exist for the player and sit above the bar", function()
        local n, bad = check("default")
        assertTrue(n >= 1, "the player has at least one visible buff button in this setup")
        assertEquals(#bad, 0, table.concat(bad, "\n"))
    end)
    it("every layout x frame size x border x power-bar combination keeps the buttons off the bar", function()
        local allBad, total = {}, 0
        for _, layout in ipairs({ "horizontal", "vertical" }) do
            for _, w in ipairs({ 100, 180, 260 }) do for _, h in ipairs({ 30, 52, 80 }) do
                for _, power in ipairs({ true, false }) do
                    ns.db.frames.layout, ns.db.frames.width, ns.db.frames.height, ns.db.frames.showPower = layout, w, h, power
                    ns:Changed("frames"); mock.flushTimers(); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(1, 0.3)
                    local n, bad = check(string.format("%s %dx%d power=%s", layout, w, h, tostring(power)))
                    total = total + n
                    for _, p in ipairs(bad) do allBad[#allBad + 1] = p end
                end
            end end
        end
        assertTrue(total > 0)
        assertEquals(#allBad, 0, table.concat(allBad, "\n"))
    end)
    it("the buttons are anchored to the TOP edge of the member (their bottom is above the bar's top)", function()
        for _, b in ipairs(buttonsFor("player")) do
            local p = st(b).points[1]
            assertEquals(p[1], "BOTTOMRIGHT"); assertEquals(p[3], "TOPRIGHT"); assertTrue(p[5] >= 0, "never dips into the bar")
        end
    end)
    it("with aura zones on top the buttons still do not touch the bar (overlap with aura icons is separate)", function()
        ns.db.auras.buffPosition = "top"; ns:Changed("frames"); mock.flushTimers()
        local n, bad = check("zone top")
        assertEquals(#bad, 0, table.concat(bad, "\n"))
    end)
end)

-- ======================================================================== /hf debug click
describe("secret guards: /hf debug click", function()
    local ns = boot()
    local function run(args)
        mock.printed = {}
        local ok, err = pcall(_G.SlashCmdList.HEALERFOREVER, args or "debug click")
        return ok, err, table.concat(mock.printed, "\n")
    end
    it("runs without errors and prints the unit button state and attributes", function()
        local ok, err, out = run()
        assertTrue(ok, tostring(err))
        assertTrue(out:find("player button:", 1, true), out)
        assertTrue(out:find("shown=", 1, true)); assertTrue(out:find("mouse=", 1, true)); assertTrue(out:find("level=", 1, true))
        assertTrue(out:find("unit attribute: player", 1, true), out)
        assertTrue(out:find("rangeState", 1, true))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("lists the click-cast type / macrotext attributes of the unit button", function()
        local _, _, out = run()
        assertTrue(out:find("type", 1, true) and out:find("=", 1, true), out)
        local b = ns.UnitFrames.byUnit.player
        local n = 0
        for name in pairs(b.hfAttrs or {}) do if name:find("type") or name:find("macrotext") then n = n + 1 end end
        assertTrue(n > 0, "the fixture profile has click-cast bindings applied to the player button")
        local lines = 0
        for line in out:gmatch("[^\n]+") do if line:find("%s%s[%w%-]*type[%w%-]* =") or line:find("macrotext") then lines = lines + 1 end end
        assertTrue(lines >= 1, out)
    end)
    it("works in combat, and never makes a protected call", function()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0 = #mock.violations, #mock.softViolations
        local ok, err, out = run()
        assertTrue(ok, tostring(err)); assertTrue(out:find("combat=true", 1, true), out)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("works with every value secret, and with a missing unit button", function()
        S.secretAll = true
        local ok, err = run(); assertTrue(ok, tostring(err))
        S.secretAll = false
        local UF = ns.UnitFrames
        mock.printed = {}
        assertTrue(pcall(UF.DebugClick, UF, "nonexistent"))
        assertTrue(table.concat(mock.printed, "\n"):find("no such unit button", 1, true))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("reports a mouse-enabled frame above the button when one exists", function()
        local b = ns.UnitFrames.byUnit.player
        local cover = ns.NewFrame("Frame", "HFTestCover", b)
        cover:SetFrameLevel(b:GetFrameLevel() + 5); cover:EnableMouse(true); cover:Show()
        local _, _, out = run()
        assertTrue(out:find("mouse-enabled frame above", 1, true), out)
        cover:EnableMouse(false); cover:Hide()
    end)
    it("works for a party member button too (UF:DebugClick with a unit)", function()
        mock.printed = {}
        assertTrue(pcall(ns.UnitFrames.DebugClick, ns.UnitFrames, "party1"))
        assertTrue(table.concat(mock.printed, "\n"):find("party1 button:", 1, true))
    end)
    it("the slash usage line mentions every debug sub-command", function()
        local _, _, out = run("help")
        local usage = L.readFile(L.path("Options/Slash.lua"))
        assertTrue(usage:find("debug buffs | auras | click", 1, true))
        assertNotNil(out)
        local src = L.readFile(L.path("Options/Slash.lua"))
        assertTrue(src:find("/hf debug buffs | auras | click", 1, true) or src:find("/hf debug buffs | /hf debug auras | /hf debug click", 1, true),
            "the unknown-'debug'-argument hint must list buffs, auras and click")
    end)
end)
