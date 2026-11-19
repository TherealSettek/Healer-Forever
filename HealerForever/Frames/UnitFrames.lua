local ADDON_NAME, ns = ...

-- Party unit frames built from SecureUnitButtonTemplate buttons with fixed unit tokens
-- ("player", "party1".."party4", "pet", "partypet1".."partypet4"). Visibility is handled by
-- RegisterUnitWatch (works in combat). Anything that touches a protected frame (size, anchors,
-- unit watch, attributes) runs out of combat only and is queued via ns:AfterCombat.
local UF = { buttons = {}, byUnit = {}, members = {}, pets = {} }
ns.UnitFrames = UF

local issecret = ns.issecret
local floor, min, max = math.floor, math.min, math.max

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 8,
    insets = { left = 2, right = 2, bottom = 2, top = 2 },
}
local MEMBER_UNITS = { "player", "party1", "party2", "party3", "party4" }
local PET_UNITS = { player = "pet", party1 = "partypet1", party2 = "partypet2", party3 = "partypet3", party4 = "partypet4" }
local Util = ns.Util
local POWER_HEIGHT = 6
local PET_VERTICAL_WIDTH = 90
local RED = { r = 1, g = 0.13, b = 0.13 }
local TARGET_GLOW = { r = 1, g = 0.95, b = 0.6 }
local RANGE_ALPHA = 0.45
local GREY = { 0.45, 0.45, 0.45 }

UF.MEMBER_UNITS = MEMBER_UNITS
UF.PET_UNITS = PET_UNITS

local calc
local healthCurve
local scale100

-- Colors ----------------------------------------------------------------------

local function classColorFor(unit)
    if UnitClass then
        local _, token = UnitClass(unit)
        if not issecret(token) and token then
            local c = ns.Classes.GetColor(token)
            return c.r, c.g, c.b, token
        end
    end
    return 1, 1, 1
end

local function getHealthCurve()
    if healthCurve ~= nil then return healthCurve or nil end
    healthCurve = false
    if C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor then
        local ok, c = pcall(function()
            local curve = C_CurveUtil.CreateColorCurve()
            curve:AddPoint(0, CreateColor(0.88, 0.19, 0.12, 1))
            curve:AddPoint(0.3, CreateColor(0.91, 0.75, 0.12, 1))
            curve:AddPoint(0.6, CreateColor(0.18, 0.8, 0.25, 1))
            curve:AddPoint(1, CreateColor(0.18, 0.8, 0.25, 1))
            return curve
        end)
        if ok then healthCurve = c end
    end
    return healthCurve or nil
end

local function applyHealthColor(button)
    local unit = button.unit
    local bar = button.health
    if button.state ~= "alive" or button.rangeState == "hidden" then
        bar:SetStatusBarColor(GREY[1], GREY[2], GREY[3])
        return
    end
    local mode = ns.db.frames.colorMode
    if mode == "custom" then
        local c = ns.db.frames.customColor
        bar:SetStatusBarColor(c.r, c.g, c.b)
    elseif mode == "gradient" then
        local curve = getHealthCurve()
        local done = false
        if curve and UnitHealthPercent then
            done = pcall(function()
                local color = UnitHealthPercent(unit, true, curve)
                bar:SetStatusBarColor(color:GetRGB())
            end)
        end
        if not done then
            local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
            if not issecret(hp) and not issecret(mx) and mx > 0 then
                local p = hp / mx
                if p > 0.6 then bar:SetStatusBarColor(0.18, 0.8, 0.25)
                elseif p > 0.3 then bar:SetStatusBarColor(0.91, 0.75, 0.12)
                else bar:SetStatusBarColor(0.88, 0.19, 0.12) end
            else
                bar:SetStatusBarColor(0.18, 0.8, 0.25)
            end
        end
    else
        local owner = button.ownerUnit or unit
        local r, g, b = classColorFor(owner)
        bar:SetStatusBarColor(r, g, b)
    end
end

-- Updates -----------------------------------------------------------------------

local function getScale100()
    if CurveConstants and CurveConstants.ScaleTo100 then return CurveConstants.ScaleTo100 end
    if scale100 == nil then
        scale100 = false
        if C_CurveUtil and C_CurveUtil.CreateCurve then
            local ok, curve = pcall(function()
                local c = C_CurveUtil.CreateCurve()
                c:AddPoint(0, 0)
                c:AddPoint(1, 100)
                return c
            end)
            if ok then scale100 = curve end
        end
    end
    return scale100 or nil
end

local function setPercentText(fs, unit)
    local scale = getScale100()
    if UnitHealthPercent and scale then
        if pcall(function() fs:SetFormattedText("%.0f%%", UnitHealthPercent(unit, true, scale)) end) then
            return
        end
    end
    local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
    if not issecret(hp) and not issecret(mx) and mx > 0 then
        fs:SetFormattedText("%d%%", floor(hp / mx * 100 + 0.5))
    else
        fs:SetText("")
    end
end

-- Deficit such as "-2.7k", secret-safe: only values the game allows are formatted; otherwise the text is hidden.
local function setDeficit(fs, missing)
    if issecret(missing) then
        local ok = pcall(function() fs:SetFormattedText("-%s", AbbreviateNumbers(missing)) end)
        if not ok then ok = pcall(function() fs:SetFormattedText("-%d", missing) end) end
        if not ok then fs:SetText("") end
        return
    end
    if missing == nil or missing <= 0 then
        fs:SetText("")
    elseif AbbreviateNumbers then
        fs:SetFormattedText("-%s", AbbreviateNumbers(missing))
    else
        fs:SetFormattedText("-%d", missing)
    end
end

-- shared with the raid frames (Frames/RaidFrames.lua, Frames/RaidStyle.lua)
UF.ClassColorFor = classColorFor
UF.SetPercentText = setPercentText
UF.SetDeficit = setDeficit

function UF:UpdateHealthText(button)
    local fs = button.healthText
    if button.isPet or button.state ~= "alive" then
        fs:SetText("")
        return
    end
    if button.rangeState == "hidden" then
        fs:SetText("?")
        return
    end
    local unit, mode = button.unit, ns.db.frames.healthText
    if mode == "percent" then
        setPercentText(fs, unit)
    elseif mode == "current" then
        fs:SetText(UnitHealth(unit))
    elseif mode == "deficit" then
        local missing
        if UnitHealthMissing then missing = UnitHealthMissing(unit, true) end
        setDeficit(fs, missing)
    else
        fs:SetText("")
    end
end

function UF:UpdatePrediction(button)
    local unit = button.unit
    local bar = button.pred
    if button.isPet or not ns.db.frames.showPrediction or button.state ~= "alive" then
        bar:Hide()
        button.overheal:Hide()
        button.incomingText:SetText("")
        return
    end
    local amount
    if CreateUnitHealPredictionCalculator and UnitGetDetailedHealPrediction then
        calc = calc or CreateUnitHealPredictionCalculator()
        UnitGetDetailedHealPrediction(unit, nil, calc)
        amount = calc:GetIncomingHeals()
    elseif UnitGetIncomingHeals then
        amount = UnitGetIncomingHeals(unit)
    end
    if not issecret(amount) and amount == nil then
        bar:Hide()
        return
    end
    bar:SetMinMaxValues(0, UnitHealthMax(unit))
    bar:SetValue(amount)
    bar:Show()

    button.overheal:Hide()
    button.incomingText:SetText("")
    if not issecret(amount) and amount > 0 then
        local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
        if not issecret(hp) and not issecret(mx) and mx > 0 then
            local missing = mx - hp
            local over = amount - missing
            button.incomingText:SetFormattedText("+%d", min(amount, missing))
            if ns.db.frames.showOverheal and over > 0 then
                local w = button.health:GetWidth()
                button.overheal:SetWidth(max(2, min(over / mx * w, w * 0.3)))
                button.overheal:Show()
                button.incomingText:SetFormattedText("+%d (%d over)", min(amount, missing), over)
            end
        end
    end
end

function UF:UpdateHealth(button)
    local unit = button.unit
    if not ns.Exists(unit) then return end
    if button.state == "alive" then
        button.health:SetMinMaxValues(0, UnitHealthMax(unit))
        button.health:SetValue(UnitHealth(unit))
        if ns.db.frames.colorMode == "gradient" then applyHealthColor(button) end
    end
    UF:UpdateLowPulse(button)
    UF:UpdateHealthText(button)
    UF:UpdatePrediction(button)
end

-- Optional low-HP pulse. Secret-safe: only evaluated when health values are readable; skipped otherwise.
function UF:UpdateLowPulse(button)
    local fx = button.lowfx
    if not fx then return end
    local low = false
    if ns.db.frames.lowHpPulse and button.state == "alive" and not button.isPet then
        local hp, mx = UnitHealth(button.unit), UnitHealthMax(button.unit)
        if not issecret(hp) and not issecret(mx) and mx > 0 then
            low = hp / mx < 0.3
        elseif fx:IsShown() then
            return
        end
    end
    fx:SetShown(low)
end

function UF:UpdatePower(button)
    local unit = button.unit
    if button.isPet or not button.power:IsShown() or not ns.Exists(unit) then return end
    local _, token = UnitPowerType(unit)
    local c
    if not issecret(token) and token then
        c = ns.Classes.POWER_COLORS[token] or (PowerBarColor and PowerBarColor[token])
    end
    c = c or ns.Classes.POWER_COLORS.MANA
    button.power:SetStatusBarColor(c.r, c.g, c.b)
    button.power:SetMinMaxValues(0, UnitPowerMax(unit))
    button.power:SetValue(UnitPower(unit))
end

local function computeState(unit)
    local connected = UnitIsConnected(unit)
    if issecret(connected) then connected = true end
    if connected == false then return "offline" end
    local dead = UnitIsDeadOrGhost(unit)
    if issecret(dead) or not dead then return "alive" end
    local ghost = UnitIsGhost(unit)
    if not issecret(ghost) and ghost then return "ghost" end
    return "dead"
end

UF.ComputeState = computeState

local function resIconFor(button)
    local cls = button.classToken
    local res = cls and ns.Classes.GetResSpell(cls)
    local playerRes = ns.PlayerRes and ns.PlayerRes()
    if playerRes then return ns.SpellTexture(playerRes) end
    if res then return ns.SpellTexture(res) end
    return "Interface\\RaidFrame\\Raid-Icon-Rez"
end

function UF:UpdateState(button)
    local unit = button.unit
    if not ns.Exists(unit) then return end
    local _, token = UnitClass(unit)
    if issecret(token) or not token then token = nil end
    button.classToken = token
    local state = computeState(unit)
    local previous = button.state
    button.state = state
    if state == previous then return end

    local dimmed = state ~= "alive"
    button.auraRow:SetAlpha(dimmed and 0.35 or 1)
    if state == "alive" then
        button.stateText:SetText("")
        button.resIcon:Hide()
        UF:UpdateHealth(button)
        applyHealthColor(button)
    else
        button.health:SetMinMaxValues(0, 1)
        button.health:SetValue(1)
        applyHealthColor(button)
        if state == "offline" then
            button.stateText:SetText("OFFLINE")
            button.resIcon:Hide()
        else
            button.stateText:SetText(state == "ghost" and "GHOST" or "DEAD")
            if not button.isPet then
                button.resIcon:SetTexture(resIconFor(button))
                button.resIcon:Show()
            end
        end
        button.pred:Hide()
        button.overheal:Hide()
        button.incomingText:SetText("")
        UF:UpdateHealthText(button)
    end
end

function UF:UpdateName(button)
    local unit = button.unit
    if not ns.Exists(unit) then return end
    button.name:SetText(UnitName(unit))
    if ns.db.frames.colorMode == "class" then
        button.name:SetTextColor(1, 1, 1)
    else
        -- only r, g, b: classColorFor also returns the class token, which SetTextColor would take as alpha
        local r, g, b = classColorFor(button.ownerUnit or unit)
        button.name:SetTextColor(r, g, b)
    end
end

-- Range / visibility -----------------------------------------------------------------------------------------
-- Everything here only touches non-secure visuals (alpha, textures, text), so it works in combat. All checks are
-- pcall'd and secret-safe; an unknown result counts as "in range".

local rangeSpellName, rangeSpellChecked

function UF.RangeSpell()
    if not rangeSpellChecked then
        rangeSpellChecked = true
        local class = ns.PlayerClass()
        local data = class and ns.Classes.DATA[class]
        for _, spell in ipairs(data and data.heals or {}) do
            if ns.SpellKnown(spell.name) then rangeSpellName = spell.name; break end
        end
    end
    return rangeSpellName
end

-- Returns "in" | "out" | "hidden", plus the raw (possibly secret) UnitInRange value when it could not be read.
function UF.RangeState(unit)
    if unit == "player" then return "in" end
    local ok, state, secretInRange = pcall(function()
        local visible = UnitIsVisible and UnitIsVisible(unit)
        if not issecret(visible) and visible == false then return "hidden" end
        local inRange = UnitInRange(unit)
        local inRangeSecret = issecret(inRange)
        if not inRangeSecret and inRange == false then return "out" end
        local spell = UF.RangeSpell()
        if spell and C_Spell and C_Spell.IsSpellInRange then
            local r = C_Spell.IsSpellInRange(spell, unit)
            if not issecret(r) and r ~= nil then return r and "in" or "out" end
        end
        if inRangeSecret then return "in", inRange end
        return "in"
    end)
    if not ok then return "in" end
    return state, secretInRange
end

-- Approximate distance in yards, only where the game lets us compute it (never in instances).
function UF.Distance(unit)
    local ok, distance = pcall(function()
        if IsInInstance and IsInInstance() then return nil end
        local y1, x1, _, i1 = UnitPosition("player")
        local y2, x2, _, i2 = UnitPosition(unit)
        if issecret(y1) or issecret(x1) or issecret(y2) or issecret(x2) then return nil end
        if not (y1 and x1 and y2 and x2) or i1 ~= i2 then return nil end
        return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
    end)
    return ok and distance or nil
end

local DASH_THICKNESS = 2

-- Dashed (out of range) or dotted (not visible) outline around the health bar, built from WHITE8X8 segments.
local function layoutDashes(button, color, dash, gap)
    local frame = button.dashFrame
    if not frame then return end
    button.dashTex = button.dashTex or {}
    local used = 0
    local function segment(point, x, y, w, h)
        used = used + 1
        local tex = button.dashTex[used]
        if not tex then
            tex = frame:CreateTexture(nil, "OVERLAY")
            tex:SetTexture(WHITE)
            button.dashTex[used] = tex
        end
        tex:ClearAllPoints()
        tex:SetPoint(point, button.health, point, x, y)
        tex:SetSize(w, h)
        tex:SetVertexColor(color.r, color.g, color.b, 1)
        tex:Show()
    end
    local w, h = button.health:GetWidth(), button.health:GetHeight()
    if w and h and w > 0 and h > 0 then
        local step = dash + gap
        for x = 0, w - dash, step do
            segment("TOPLEFT", x, DASH_THICKNESS / 2, dash, DASH_THICKNESS)
            segment("BOTTOMLEFT", x, -DASH_THICKNESS / 2, dash, DASH_THICKNESS)
        end
        for y = 0, h - dash, step do
            segment("TOPLEFT", -DASH_THICKNESS / 2, -y, DASH_THICKNESS, dash)
            segment("TOPRIGHT", DASH_THICKNESS / 2, -y, DASH_THICKNESS, dash)
        end
    end
    for i = used + 1, #button.dashTex do button.dashTex[i]:Hide() end
    frame:SetShown(used > 0)
end

UF.LayoutDashes = layoutDashes

function UF:ApplyRangeVisuals(button)
    local range = Util.NormalizeRange(ns.db.frames.range)
    local state = button.rangeState or "in"
    local badgeStyle = range.style == "badge"
    local faded = badgeStyle and state == "out"
    local dim = range.dim / 100
    button.health:SetAlpha(faded and dim or 1)
    if button.power then button.power:SetAlpha(faded and dim or 1) end

    -- "secret" = the game will not tell us whether the unit is in range: the dashes, badge and green edge are
    -- shown here and their alpha is driven by the secret boolean in ApplySecretRange (no truth test on it)
    if button.dashFrame then button.dashFrame:SetAlpha(1) end
    if button.badge then button.badge:SetAlpha(1) end
    if badgeStyle and (state == "out" or state == "hidden" or state == "secret") then
        local color = state == "hidden" and range.hiddenColor or range.outColor
        if state == "hidden" then layoutDashes(button, color, 2, 3) else layoutDashes(button, color, 6, 4) end
    elseif button.dashFrame then
        button.dashFrame:Hide()
    end

    local badge = button.badge
    if badge then
        local text
        if badgeStyle and range.badge and state ~= "in" then
            local dead = button.state == "dead" or button.state == "ghost"
            if dead and not button.isPet then
                text = "CAN'T RESURRECT"
            else
                text = state == "hidden" and "NOT VISIBLE" or "OUT OF RANGE"
            end
        end
        if text then
            local color = state == "hidden" and range.hiddenColor or { r = 1, g = 0.45, b = 0.4 }
            badge.text:SetText(text)
            badge.text:SetTextColor(color.r, color.g, color.b)
            badge:SetSize(badge.text:GetStringWidth() + 10, 14)
            badge:Show()
        else
            badge:Hide()
        end
    end
    if button.edgeGlow then
        local show = badgeStyle and range.healable and state == "secret"
        if show then
            local c = range.healableColor
            button.edgeGlow:SetBackdropBorderColor(c.r, c.g, c.b, 0.9)
        end
        button.edgeGlow:SetShown(show and true or false)
    end
    UF:ApplyBorderColor(button)
    applyHealthColor(button)
    UF:UpdateHealthText(button)
end

-- Drives the range visuals from a secret boolean using widget APIs that accept it:
-- Region:SetAlphaFromBoolean(value, alphaIfTrue, alphaIfFalse). Never a truth test or comparison on the value.
local function applySecretRange(button, secretInRange)
    local range = Util.NormalizeRange(ns.db.frames.range)
    local dim = range.dim / 100
    local function drive(region, ifIn, ifOut)
        if region and region.SetAlphaFromBoolean then
            pcall(region.SetAlphaFromBoolean, region, secretInRange, ifIn, ifOut)
        end
    end
    if range.style == "dim" then
        drive(button, 1, dim)
        return
    end
    button:SetAlpha(1)
    drive(button.health, 1, dim)
    drive(button.power, 1, dim)
    drive(button.badge, 0, 1)
    drive(button.dashFrame, 0, 1)
    drive(button.edgeGlow, 1, 0)
end

function UF:UpdateRange(button)
    local unit = button.unit
    if unit == "player" or not ns.Exists(unit) then
        button:SetAlpha(1)
        if button.rangeState ~= "in" then
            button.rangeState = "in"
            UF:ApplyRangeVisuals(button)
        end
        return
    end
    if button.state == "offline" then
        button:SetAlpha(RANGE_ALPHA)
        return
    end
    local state, maybeSecret = UF.RangeState(unit)
    local isSecret = issecret(maybeSecret)
    local range = Util.NormalizeRange(ns.db.frames.range)
    local mode = isSecret and "secret" or state
    if mode ~= button.rangeState or button.rangeStyle ~= range.style then
        button.rangeState = mode
        button.rangeStyle = range.style
        UF:ApplyRangeVisuals(button)
    end
    if isSecret then
        applySecretRange(button, maybeSecret)
    elseif range.style == "dim" then
        button:SetAlpha(state == "in" and 1 or range.dim / 100)
    else
        button:SetAlpha(1)
    end
end

function UF:UpdateTargetHighlight(button)
    local isTarget = UnitIsUnit(button.unit, "target")
    if issecret(isTarget) then isTarget = false end
    button.isTarget = isTarget and true or false
    if button.glow then button.glow:SetShown(button.isTarget) end
    UF:ApplyBorderColor(button)
end

-- Aggro (red border). The threat situation may be secret in combat: then the last known state is kept.
function UF:UpdateThreat(button)
    if not UnitThreatSituation then return end
    local status = UnitThreatSituation(button.unit)
    if issecret(status) then return end
    button.aggro = status ~= nil and status >= 2
    UF:ApplyBorderColor(button)
end

local ROLE_ATLAS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }
local ROLE_COORDS = {
    TANK = { 0, 19 / 64, 22 / 64, 41 / 64 },
    HEALER = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
    DAMAGER = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
}

function UF:UpdateRole(button)
    local icon = button.roleIcon
    if not icon then return end
    local role = ns.db.frames.showRoleIcon and not button.isPet and ns.Roles.Get(button.unit) or nil
    if not role or not ROLE_ATLAS[role] then
        icon:Hide()
        return
    end
    local hasAtlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ROLE_ATLAS[role])
    if hasAtlas then
        icon:SetAtlas(ROLE_ATLAS[role])
    else
        icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
        icon:SetTexCoord(unpack(ROLE_COORDS[role]))
    end
    icon:Show()
end

function UF:UpdateAll(button)
    if not ns.Exists(button.unit) then return end
    button.state = nil
    UF:UpdateName(button)
    UF:UpdateState(button)
    UF:UpdateHealth(button)
    UF:UpdatePower(button)
    UF:UpdateRange(button)
    UF:UpdateTargetHighlight(button)
    UF:UpdateThreat(button)
    UF:UpdateRole(button)
    ns.Auras.Update(button)
end

function UF:UpdateEverything()
    -- hard-suspended (raid layout, not Auto in a raid): nothing to update. Soft: the bars stay current because a
    -- visibility driver may show them in combat when the raid ends.
    if UF.suspended and not UF.softSuspended then return end
    for _, button in ipairs(UF.buttons) do
        UF:UpdateAll(button)
    end
end

-- Construction ----------------------------------------------------------------------

local function createBar(parent)
    local bar = ns.NewFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    return bar
end

local function createButton(unit, ownerUnit, isPet, index)
    local template = "SecureUnitButtonTemplate,SecureHandlerEnterLeaveTemplate,SecureHandlerStateTemplate,BackdropTemplate"
    local button = ns.NewFrame("Button", "HealerForeverUnit" .. index, UF.anchor, template)
    button.unit = unit
    button.ownerUnit = ownerUnit
    button.isPet = isPet
    button:SetAttribute("unit", unit)
    -- SecureUnitButton_OnClick has no down/up filter (unlike SecureActionButton_OnClick): AnyUp only, or every
    -- click would act on press and again on release
    button:RegisterForClicks("AnyUp")

    button.dashFrame = ns.NewFrame("Frame", nil, button)
    button.dashFrame:SetAllPoints(button)
    button.dashFrame:SetFrameLevel(button:GetFrameLevel() + 14)
    button.dashFrame:EnableMouse(false)
    button.dashFrame:Hide()

    button.edgeGlow = ns.NewFrame("Frame", nil, button, "BackdropTemplate")
    button.edgeGlow:SetFrameLevel(button:GetFrameLevel() + 13)
    button.edgeGlow:EnableMouse(false)
    button.edgeGlow:Hide()

    button.glow = ns.NewFrame("Frame", nil, button, "BackdropTemplate")
    button.glow:SetPoint("TOPLEFT", -2, 2)
    button.glow:SetPoint("BOTTOMRIGHT", 2, -2)
    button.glow:SetBackdrop({ edgeFile = WHITE, edgeSize = 2 })
    button.glow:SetBackdropBorderColor(TARGET_GLOW.r, TARGET_GLOW.g, TARGET_GLOW.b, 0.9)
    button.glow:EnableMouse(false)
    button.glow:Hide()

    local health = createBar(button)
    health:SetClipsChildren(true)
    button.healthBG = health:CreateTexture(nil, "BACKGROUND")
    button.healthBG:SetAllPoints()
    button.healthBG:SetTexture(WHITE)
    button.healthBG:SetVertexColor(0.16, 0.05, 0.05, 1)
    button.health = health
    button.edgeGlow:SetPoint("TOPLEFT", health, "TOPLEFT", -1, 1)
    button.edgeGlow:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", 1, -1)
    button.edgeGlow:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })

    local pred = createBar(health)
    pred:SetStatusBarColor(0.49, 1, 0.61, 0.6)
    pred:SetFrameLevel(health:GetFrameLevel() + 1)
    pred:SetPoint("TOPLEFT", health:GetStatusBarTexture(), "TOPRIGHT")
    pred:SetPoint("BOTTOMLEFT", health:GetStatusBarTexture(), "BOTTOMRIGHT")
    pred:Hide()
    button.pred = pred

    local overheal = health:CreateTexture(nil, "OVERLAY")
    overheal:SetTexture(WHITE)
    overheal:SetVertexColor(0.18, 0.62, 0.29, 0.7)
    overheal:SetPoint("TOPRIGHT")
    overheal:SetPoint("BOTTOMRIGHT")
    overheal:Hide()
    button.overheal = overheal

    local text = ns.NewFrame("Frame", nil, health)
    text:SetAllPoints()
    text:SetFrameLevel(pred:GetFrameLevel() + 2)
    button.name = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.name:SetPoint("TOPLEFT", 4, -3)
    button.name:SetJustifyH("LEFT")
    button.healthText = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.healthText:SetPoint("TOPRIGHT", -4, -3)
    button.incomingText = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.incomingText:SetPoint("BOTTOMRIGHT", -4, 2)
    button.incomingText:SetTextColor(0.49, 1, 0.61)
    button.badge = ns.NewFrame("Frame", nil, text, "BackdropTemplate")
    button.badge:SetPoint("BOTTOM", health, "BOTTOM", 0, 3)
    button.badge:SetFrameLevel(text:GetFrameLevel() + 4)
    button.badge:SetBackdrop({ bgFile = WHITE })
    button.badge:SetBackdropColor(0, 0, 0, 0.75)
    button.badge:EnableMouse(false)
    button.badge.text = button.badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.badge.text:SetPoint("CENTER")
    button.badge:Hide()
    button.stateText = text:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    button.stateText:SetPoint("CENTER", 0, 0)
    button.stateText:SetTextColor(1, 0.25, 0.25)
    button.lowfx = health:CreateTexture(nil, "OVERLAY")
    button.lowfx:SetAllPoints()
    button.lowfx:SetTexture(WHITE)
    button.lowfx:SetVertexColor(1, 0.1, 0.1)
    button.lowfx:SetBlendMode("ADD")
    do
        local group = button.lowfx:CreateAnimationGroup()
        group:SetLooping("BOUNCE")
        local a = group:CreateAnimation("Alpha")
        a:SetFromAlpha(0)
        a:SetToAlpha(0.55)
        a:SetDuration(0.7)
        group:Play()
        button.lowfx:SetAlpha(0)
    end
    button.lowfx:Hide()
    if not isPet then
        button.roleIcon = text:CreateTexture(nil, "OVERLAY")
        button.roleIcon:SetSize(14, 14)
        button.roleIcon:SetPoint("BOTTOMLEFT", 3, 2)
        button.roleIcon:Hide()
    end
    button.resIcon = text:CreateTexture(nil, "OVERLAY")
    button.resIcon:SetPoint("LEFT", 6, 0)
    button.resIcon:Hide()

    if not isPet then
        button.power = createBar(button)
        local bg = button.power:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(WHITE)
        bg:SetVertexColor(0.07, 0.07, 0.07, 1)
        ns.Auras.Create(button)
    else
        button.auraRow = ns.NewFrame("Frame", nil, button)
        button.auraRow:Hide()
    end

    ns.SecureHook(button, "OnShow", function(self) UF:UpdateAll(self) end)
    ns.SecureHook(button, "OnEnter", function(self) UF.hovered = self; UF:ShowTooltip(self) end)
    ns.SecureHook(button, "OnLeave", function(self)
        if UF.hovered == self then UF.hovered = nil end
        if GameTooltip then GameTooltip:Hide() end
    end)

    UF.buttons[#UF.buttons + 1] = button
    UF.byUnit[unit] = button
    return button
end

local function createAnchor()
    local anchor = ns.NewFrame("Frame", "HealerForeverPartyFrame", UIParent)
    anchor:SetSize(200, 50)
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    UF.anchor = anchor


    local handle = ns.NewFrame("Button", "HealerForeverPartyHandle", anchor, "BackdropTemplate")
    handle:SetBackdrop(BACKDROP)
    handle:SetBackdropColor(0, 0, 0, 0.8)
    handle:SetHeight(18)
    handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 1)
    handle:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 1)
    handle.label = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    handle.label:SetPoint("CENTER")
    handle.label:SetText("Healer Forever - drag to move")
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function()
        if not ns.InCombat() then anchor:StartMoving() end
    end)
    handle:SetScript("OnDragStop", function()
        if ns.InCombat() then return end
        anchor:StopMovingOrSizing()
        local point, _, relativePoint, x, y = anchor:GetPoint()
        local p = ns.db.frames.point
        p.point, p.relativePoint, p.x, p.y = point, relativePoint, x, y
    end)
    UF.handle = handle

    -- subtle gold outline shown while unlocked (non-protected, never intercepts the mouse)
    local outline = ns.NewFrame("Frame", nil, anchor, "BackdropTemplate")
    outline:SetPoint("TOPLEFT", -4, 4)
    outline:SetPoint("BOTTOMRIGHT", 4, -4)
    outline:SetFrameLevel(anchor:GetFrameLevel() + 20)
    outline:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    outline:SetBackdropBorderColor(1, 0.82, 0, 0.6)
    outline:EnableMouse(false)
    UF.outline = outline

    local acc, tipAcc = 0, 0
    anchor:SetScript("OnUpdate", function(_, elapsed)
        tipAcc = tipAcc + elapsed
        if tipAcc >= 0.5 then
            tipAcc = 0
            if UF.hovered then UF:ShowTooltip(UF.hovered) end
        end
        acc = acc + elapsed
        if acc < 0.25 then return end
        acc = 0
        local t0 = ns.perfOn and debugprofilestop()
        for _, button in ipairs(UF.buttons) do
            if button:IsShown() then
                UF:UpdateState(button)
                UF:UpdateRange(button)
            end
        end
        if t0 then ns.Perf.Add("uf", t0) end
    end)
end

-- Layout ------------------------------------------------------------------------------

local function sortedUnits()
    local frames = ns.db.frames
    local list = {}
    for _, unit in ipairs(frames.order) do
        if unit ~= "player" or frames.showPlayer then
            list[#list + 1] = unit
        end
    end
    for _, unit in ipairs(MEMBER_UNITS) do
        local found = false
        for _, u in ipairs(list) do if u == unit then found = true end end
        if not found and (unit ~= "player" or frames.showPlayer) then list[#list + 1] = unit end
    end

    local mode = frames.sortMode
    if mode == "manual" then
        return list
    end
    local present, absent = {}, {}
    for _, unit in ipairs(list) do
        if ns.Exists(unit) then present[#present + 1] = unit else absent[#absent + 1] = unit end
    end
    local function key(unit)
        if mode == "role" then
            local role
            if UnitGroupRolesAssigned then role = UnitGroupRolesAssigned(unit) end
            if issecret(role) or not role then return 4 end
            return ({ TANK = 1, HEALER = 2, DAMAGER = 3 })[role] or 4
        elseif mode == "class" then
            local _, token = UnitClass(unit)
            if issecret(token) or not token then return "ZZZ" end
            return token
        end
        local name = UnitName(unit)
        if issecret(name) or not name then return "" end
        return name
    end
    local keys = {}
    for i, unit in ipairs(present) do keys[unit] = { key(unit), i } end
    table.sort(present, function(a, b)
        local ka, kb = keys[a], keys[b]
        if ka[1] ~= kb[1] then return ka[1] < kb[1] end
        return ka[2] < kb[2]
    end)
    for _, unit in ipairs(absent) do present[#present + 1] = unit end
    return present
end

-- Appearance helpers -------------------------------------------------------------------------
-- The original party frame look (no tile box, no group panel); only the health and power bars get a border.

local PAD_MIN = 1

local function metrics()
    local f = ns.db.frames
    local border = Util.NormalizeBorder(f.border)
    local spec = Util.BorderSpec(border.style, border.width)
    local margin = spec.outset + PAD_MIN + 1
    local powerH = f.showPower and POWER_HEIGHT or 0
    local frameH = margin * 2 + f.height + powerH
    local petH = margin * 2 + max(12, floor(f.height * 0.55))
    return border, spec, margin, powerH, frameH, petH
end

function UF:GetSizes()
    local _, _, _, _, frameH, petH = metrics()
    return frameH, petH, 0
end

-- Border frame around a bar (non-secure child of the button, never intercepts the mouse).
local function barBorder(button, bar)
    local frame = bar.hfBorder
    if not frame then
        frame = ns.NewFrame("Frame", nil, button, "BackdropTemplate")
        frame:EnableMouse(false)
        bar.hfBorder = frame
        button.borders = button.borders or {}
        button.borders[#button.borders + 1] = frame
    end
    return frame
end

function UF:ApplyBorderColor(button)
    if not button.borders then return end
    local border = Util.NormalizeBorder(ns.db.frames.border)
    local r, g, b = classColorFor(button.ownerUnit or button.unit)
    local color = Util.BarBorderColor(border, { r = r, g = g, b = b })
    local range = Util.NormalizeRange(ns.db.frames.range)
    local state = button.rangeState
    if range.style == "badge" then
        if state == "out" then
            color = range.outColor
        elseif state == "hidden" then
            color = range.hiddenColor
        elseif state == "in" and range.healable and border.style ~= "none" then
            -- subtle green edge: half way between the normal border colour and the healable colour
            local h = range.healableColor
            color = { r = (color.r + h.r) / 2, g = (color.g + h.g) / 2, b = (color.b + h.b) / 2 }
        end
    end
    if button.aggro then color = RED end
    for _, frame in ipairs(button.borders) do
        frame:SetBackdropBorderColor(color.r, color.g, color.b, 1)
    end
end

local function styleBorder(button, bar, spec)
    local frame = barBorder(button, bar)
    frame:ClearAllPoints()
    if not spec.edgeFile then
        frame:Hide()
        return
    end
    frame:SetPoint("TOPLEFT", bar, "TOPLEFT", -spec.outset, spec.outset)
    frame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", spec.outset, -spec.outset)
    frame:SetFrameLevel(bar:GetFrameLevel() + 8)
    frame:SetBackdrop({ edgeFile = spec.edgeFile, edgeSize = spec.edgeSize })
    frame:Show()
end

-- Positions the bars, texts and bar borders of one button (original layout).
function UF:StyleButton(button, ctx)
    local spec, margin = ctx.spec, ctx.margin
    local pet = ctx.pet
    button:SetSize(ctx.w, ctx.h)
    local innerW = ctx.w - margin * 2
    local healthH = pet and (ctx.h - margin * 2) or ns.db.frames.height

    button.health:ClearAllPoints()
    button.health:SetPoint("TOPLEFT", margin, -margin)
    button.health:SetSize(innerW, healthH)
    button.pred:SetWidth(innerW)
    styleBorder(button, button.health, spec)
    if button.power then
        button.power:ClearAllPoints()
        button.power:SetPoint("TOPLEFT", button.health, "BOTTOMLEFT", 0, 0)
        button.power:SetSize(innerW, ctx.powerH)
        button.power:SetShown(ctx.powerH > 0)
        styleBorder(button, button.power, spec)
        if ctx.powerH <= 0 then button.power.hfBorder:Hide() end
    end
    button.name:SetWidth(innerW * 0.6)
    local iconSize = max(10, min(healthH - 10, 24))
    button.resIcon:SetSize(iconSize, iconSize)
    UF:ApplyBorderColor(button)
    button.rangeStyle = nil   -- force the range visuals (dashes) to be rebuilt for the new size
end

-- Reserved aura zones around a member frame (nothing for pets).
local function zoneDescriptors()
    local cfg = ns.db.auras
    local out = {}
    local timerH = cfg.timerPos == "inside" and 0 or Util.TIMER_HEIGHT
    if cfg.showBuffs and cfg.buffPosition ~= "inside" then
        local w, h = Util.ZoneSize(cfg.buffSize, ns.Auras.PerRowFor("buff"), cfg.maxBuffs, cfg.grow, 0, timerH, Util.ICON_GAP)
        out[#out + 1] = { kind = "buff", pos = cfg.buffPosition, w = w, h = h }
    end
    if cfg.showDebuffs and cfg.debuffPosition ~= "inside" then
        local w, h = Util.ZoneSize(cfg.debuffSize, ns.Auras.PerRowFor("debuff"), cfg.maxDebuffs, cfg.grow, 0, timerH, Util.ICON_GAP)
        out[#out + 1] = { kind = "debuff", pos = cfg.debuffPosition, w = w, h = h }
    end
    return out
end

-- Anchors the zone frames (non-secure, no boxes) to a member button: outside in the reserved space, or inside the bar.
function UF:PlaceZones(button, descriptors)
    local zones = button.zones
    if not zones then return end
    local cfg = ns.db.auras
    for _, z in pairs(zones) do z:ClearAllPoints(); z:Hide() end
    local off = { top = 0, bottom = 0, left = 0, right = 0 }
    local ordered = {}
    for _, d in ipairs(descriptors) do ordered[#ordered + 1] = d end
    -- on the top side the debuff zone is nearest the frame
    table.sort(ordered, function(x, y)
        if x.pos == "top" and y.pos == "top" then return x.kind == "debuff" and y.kind ~= "debuff" end
        return x.kind == "buff" and y.kind ~= "buff"
    end)
    local gap = cfg.zoneGap
    local timerH = cfg.timerPos == "inside" and 0 or Util.TIMER_HEIGHT
    for _, d in ipairs(ordered) do
        local zone = zones[d.kind]
        zone:SetSize(d.w, d.h)
        zone.grow = cfg.grow
        zone.timerH, zone.iconGap = timerH, Util.ICON_GAP
        if d.pos == "top" then
            zone:SetPoint("BOTTOMLEFT", button, "TOPLEFT", 0, off.top + gap)
            off.top = off.top + d.h + gap
        elseif d.pos == "bottom" then
            zone:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -(off.bottom + gap))
            off.bottom = off.bottom + d.h + gap
        elseif d.pos == "left" then
            zone:SetPoint("TOPRIGHT", button, "TOPLEFT", -gap, -off.left)
            off.left = off.left + d.h + gap
        else
            zone:SetPoint("TOPLEFT", button, "TOPRIGHT", gap, -off.right)
            off.right = off.right + d.h + gap
        end
        zone:Show()
    end
    -- inside the health bar: buffs top-right, debuffs bottom-right, growing left, small icons
    for kind, pos in pairs({ buff = cfg.buffPosition, debuff = cfg.debuffPosition }) do
        local enabled = kind == "buff" and cfg.showBuffs or kind == "debuff" and cfg.showDebuffs
        if enabled and pos == "inside" then
            local zone = zones[kind]
            local sz = kind == "buff" and min(cfg.buffSize, 14) or min(cfg.debuffSize, 16)
            local w, h = Util.ZoneSize(sz, ns.Auras.PerRowFor(kind), kind == "buff" and cfg.maxBuffs or cfg.maxDebuffs, "left", 0)
            zone:SetSize(w, h)
            zone.grow = "left"
            zone.timerH, zone.iconGap = 0, 2
            zone:SetPoint(kind == "buff" and "TOPRIGHT" or "BOTTOMRIGHT", button.health,
                kind == "buff" and "TOPRIGHT" or "BOTTOMRIGHT", -2, kind == "buff" and -2 or 2)
            zone:Show()
        end
    end
end

function UF:Layout(silent)
    if not UF.anchor then return end
    -- the raid layout is active: the party frames stay hidden; un-suspending runs the layout
    if UF.suspended then return end
    if ns.InCombat() then
        ns:AfterCombat("uf-layout", function() UF:Layout() end, silent)
        return
    end
    local f = ns.db.frames
    local _, spec, margin, powerH, frameH, petH = metrics()
    local w = f.width
    local vertical = f.layout == "vertical"
    local petW = vertical and PET_VERTICAL_WIDTH or w
    local units = sortedUnits()
    local descriptors = zoneDescriptors()
    local cell = Util.CellLayout(w, frameH, descriptors, ns.db.auras.zoneGap)
    local rowH = max(cell.height, petH)
    local sp = f.spacing

    for slot, unit in ipairs(units) do
        local member = UF.byUnit[unit]
        local pet = UF.byUnit[PET_UNITS[unit]]
        member:ClearAllPoints()
        pet:ClearAllPoints()
        UF:StyleButton(member, { spec = spec, margin = margin, powerH = powerH, w = w, h = frameH })
        UF:StyleButton(pet, { spec = spec, margin = margin, powerH = 0, w = petW, h = petH, pet = true })
        UF:PlaceZones(member, descriptors)
        ns.Auras.Prepare(member)
        if vertical then
            local y0 = (slot - 1) * (rowH + sp)
            member:SetPoint("TOPLEFT", UF.anchor, "TOPLEFT", cell.left, -(y0 + cell.top))
            pet:SetPoint("TOPLEFT", UF.anchor, "TOPLEFT", cell.width + 2, -(y0 + cell.top))
        else
            local x0 = (slot - 1) * (cell.width + sp)
            member:SetPoint("TOPLEFT", UF.anchor, "TOPLEFT", x0 + cell.left, -cell.top)
            pet:SetPoint("TOPLEFT", UF.anchor, "TOPLEFT", x0 + cell.left, -(cell.height + 2))
        end
    end

    local n = max(1, #units)
    if vertical then
        UF.anchor:SetSize(cell.width + (f.showPets and (petW + 2) or 0), max(1, n * rowH + (n - 1) * sp))
    else
        UF.anchor:SetSize(max(1, n * cell.width + (n - 1) * sp), cell.height + (f.showPets and (petH + 2) or 0))
    end

    for _, unit in ipairs(MEMBER_UNITS) do
        local member, pet = UF.byUnit[unit], UF.byUnit[PET_UNITS[unit]]
        local wantMember = unit ~= "player" or f.showPlayer
        if wantMember then
            if not member.watched then RegisterUnitWatch(member); member.watched = true end
        else
            if member.watched then UnregisterUnitWatch(member); member.watched = false end
            member:Hide()
        end
        if wantMember and f.showPets then
            if not pet.watched then RegisterUnitWatch(pet); pet.watched = true end
        else
            if pet.watched then UnregisterUnitWatch(pet); pet.watched = false end
            pet:Hide()
        end
    end
    UF:ApplyPoint()
    UF:ApplyLock()
    UF:UpdateEverything()
    ns:Fire("FRAMES_LAID_OUT")
end

-- Raid layout switch (out of combat only; the caller queues it otherwise). Un-suspended: today's party Layout runs
-- again unchanged (the only state when no raid layout is active). Suspended:
--   hard (soft = false: "Always raid", or Auto outside a raid): the party / pet buttons lose their unit watch and are
--        hidden with the party anchor.
--   soft (Auto inside a raid): the buttons keep their unit watch and layout; the party anchor gets the secure
--        visibility driver "[group:raid] hide; show", so when the raid ends in combat the party frames show at once
--        (the game drives Show/Hide; no addon code runs in the protected path). Unregistered on un-suspend.
function UF:SetSuspended(suspended, soft)
    if not UF.anchor then return end
    suspended = suspended and true or false
    soft = (suspended and soft) and true or false
    if ns.InCombat() then
        ns:AfterCombat("uf-suspend", function() UF:SetSuspended(suspended, soft) end, true)
        return
    end
    if suspended == (UF.suspended or false) and soft == (UF.softSuspended or false) then return end
    if UF.softSuspended then
        UnregisterStateDriver(UF.anchor, "visibility")
        UF.softSuspended = nil
    end
    if suspended then
        if UF.hovered and GameTooltip then GameTooltip:Hide() end
        UF.hovered = nil
        if soft then
            if UF.suspended then
                -- hard -> soft: the party layout (unit watch, cells) comes back first
                UF.suspended = nil
                UF:Layout(true)
            end
            UF.suspended, UF.softSuspended = true, true
            UF.anchor:Hide()
            RegisterStateDriver(UF.anchor, "visibility", "[group:raid] hide; show")
        else
            UF.suspended = true
            for _, button in ipairs(UF.buttons) do
                if button.watched then UnregisterUnitWatch(button); button.watched = false end
                button:Hide()
            end
            UF.anchor:Hide()
        end
    else
        UF.suspended = nil
        UF.anchor:Show()
        UF:Layout()
    end
end

function UF:ApplyPoint()
    local p = ns.db.frames.point
    UF.anchor:ClearAllPoints()
    UF.anchor:SetPoint(p.point, UIParent, p.relativePoint, p.x, p.y)
end

-- The handle and outline are plain non-protected frames, so locking is safe in combat.
function UF:ApplyLock()
    if not UF.handle then return end
    local unlocked = not ns.db.frames.locked
    UF.handle:SetShown(unlocked)
    UF.outline:SetShown(unlocked)
end

function UF:SetLocked(locked)
    ns.db.frames.locked = locked and true or false
    UF:ApplyLock()
    ns:Fire("LOCK_CHANGED", ns.db.frames.locked)
end

-- Tooltip ---------------------------------------------------------------------------

local function actionLabel(action)
    if action.type == "spell" then return action.spell or "?" end
    if action.type == "target" then return "Target unit" end
    if action.type == "menu" then return "Unit menu" end
    if action.type == "macro" then return "Macro" end
    return "?"
end

-- /hf debug click: what the player's unit button would do on a click, and what could be covering it.
function UF:DebugClick(unit)
    local button = UF.byUnit[unit or "player"]
    local RF = ns.RaidFrames
    if (not button or (unit and unit:match("^raid%d+$"))) and RF and RF.byUnit then button = RF.byUnit[unit] or button end
    if not button then ns:Print("no such unit button") return end
    local function say(text) ns:Print(text) end
    say(string.format("%s button: shown=%s alpha=%.2f mouse=%s level=%d strata=%s combat=%s", button.unit,
        tostring(button:IsShown()), button:GetAlpha(), tostring(button:IsMouseEnabled()), button:GetFrameLevel(),
        tostring(button:GetFrameStrata()), tostring(ns.InCombat())))
    say("unit attribute: " .. tostring(button:GetAttribute("unit")) .. ", state-hfdead: "
        .. tostring(button:GetAttribute("state-hfdead")) .. ", rangeState: " .. tostring(button.rangeState))
    local names = {}
    for name in pairs(button.hfAttrs or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        if name:find("type") or name:find("macrotext") then
            say("  " .. name .. " = " .. tostring(button:GetAttribute(name)))
        end
    end
    say("Cmd: IsMetaKeyDown=" .. tostring(IsMetaKeyDown and IsMetaKeyDown() or "n/a")
        .. " state-hfmeta=" .. tostring(button:GetAttribute("state-hfmeta"))
        .. " swap entries=" .. tostring(button:GetAttribute("hf-mn"))
        .. " parse[mod:meta]=" .. tostring(SecureCmdOptionParse and SecureCmdOptionParse("[mod:meta] meta; none") or "n/a"))
    for _, k in ipairs({ "META-BUTTON1", "META-BUTTON2", "META-BUTTON3" }) do
        say("  GetBindingAction(" .. k .. ") = " .. tostring(GetBindingAction and GetBindingAction(k) or "n/a"))
    end
    for _, mod in ipairs({ "", "shift-", "ctrl-", "alt-" }) do
        for i = 1, 3 do
            local t = button:GetAttribute(mod .. "type" .. i)
            if t then say("  " .. mod .. "type" .. i .. " = " .. tostring(t) .. " | " .. tostring(button:GetAttribute(mod .. "macrotext" .. i))) end
        end
    end
    local n = tonumber(button:GetAttribute("hf-nbinds")) or 0
    for i = 1, n do
        local key = button:GetAttribute("hf-bkey" .. i)
        say("  override slot HFB" .. i .. " -> " .. tostring(key) .. " (bound now: "
            .. tostring(key and GetBindingAction and GetBindingAction(key) or "?") .. ")")
    end
    -- frames that could sit on top of the button and take the click
    local function visit(frame, label)
        if frame and frame.IsShown and frame:IsShown() and frame.IsMouseEnabled and frame:IsMouseEnabled()
            and frame:GetFrameLevel() >= button:GetFrameLevel() then
            say(string.format("  mouse-enabled frame above: %s level=%d alpha=%.2f overlaps=%s", label,
                frame:GetFrameLevel(), frame:GetAlpha(), tostring(frame:IsMouseOver())))
        end
    end
    local BB = ns.BuffButtons
    if BB then
        for _, b in ipairs(BB.buttons) do if b.unit == button.unit then visit(b, b:GetName() or "buff button") end end
        for _, b in ipairs(BB.extraButtons) do if b.unit == button.unit then visit(b, b:GetName() or "extra button") end end
    end
    for _, child in ipairs({ button:GetChildren() }) do visit(child, tostring(child:GetName() or "child frame")) end
    if GetMouseFoci then
        local foci = GetMouseFoci()
        local list = {}
        for _, f in ipairs(foci or {}) do list[#list + 1] = tostring(f.GetName and f:GetName() or f) end
        say("frames under the mouse right now: " .. (#list > 0 and table.concat(list, ", ") or "none"))
    elseif GetMouseFocus then
        local f = GetMouseFocus()
        say("frame under the mouse right now: " .. tostring(f and f.GetName and f:GetName() or f))
    end
end

function UF:ShowTooltip(button)
    if not button or not GameTooltip then return end
    -- an aura icon tooltip owns the tooltip while the mouse is over the icon
    if ns.Auras.hoveredIcon then return end
    -- native aura buttons show their own tooltip: never fight it with the bar tooltip
    if ns.Auras.IsHoveringContainerButton(button) then
        button.barTooltipSuppressed = true
        if GameTooltip.GetOwner and GameTooltip:GetOwner() == button then GameTooltip:Hide() end
        return
    end
    button.barTooltipSuppressed = false
    local mod = ns.GetHeldModifierKey()
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    local unit = button.unit
    if ns.Exists(unit) then
        local r, g, b = classColorFor(button.ownerUnit or unit)
        GameTooltip:AddLine(UnitName(unit), r, g, b)
    end
    if button.state == "offline" and ns.Exists(unit) then
        GameTooltip:AddLine("Offline", 0.67, 0.67, 0.67)
    elseif button.unit ~= "player" and ns.Exists(unit) then
        local state = button.rangeState or "in"
        if state == "secret" or state == "offline" then
            state = nil
        elseif state == "hidden" then
            GameTooltip:AddLine("Not visible (too far or in another phase)", 0.5, 0.6, 0.75)
        elseif state == "out" then
            local d = UF.Distance(unit)
            GameTooltip:AddLine("Out of range (can't heal)" .. (d and string.format(" - about %d yd", d) or ""), 1, 0.45, 0.4)
        elseif state then
            GameTooltip:AddLine("In range", 0.3, 0.9, 0.4)
        end
        if state and (state ~= "in") and (button.state == "dead" or button.state == "ghost") and not button.isPet then
            GameTooltip:AddLine("Can't resurrect from here", 1, 0.3, 0.3)
        end
    end
    local resSpell = ns.PlayerRes and ns.PlayerRes()
    local deadRes = resSpell and ns.db.resurrectOnClick and not button.isPet
        and button.state and button.state ~= "alive" and button.state ~= "offline"
    if ns.db.auras.tooltipDebuffs then ns.Auras.AppendTooltip(GameTooltip, unit, true) end
    if ns.db.auras.tooltipBuffs then ns.Auras.AppendTooltip(GameTooltip, unit, false) end
    GameTooltip:AddLine("Click-casting: " .. ns.Bindings.DisplayLabel(mod, ns.IsMac()), 1, 0.82, 0)
    local list = ns.Bindings.FilterForModifier(ns.ClickCast and ns.ClickCast:EffectiveBindings() or ns.db.bindings, mod)
    for _, entry in ipairs(list) do
        local label = deadRes and resSpell or actionLabel(entry.action)
        GameTooltip:AddDoubleLine(ns.Bindings.ButtonLabel(entry.button), label, 0.8, 0.8, 0.8, 1, 1, 1)
    end
    GameTooltip:AddLine("Hold Shift / Ctrl / Alt / Cmd to see other bindings", 0.5, 0.5, 0.5)
    if button.tooltipExtra then button.tooltipExtra(button, GameTooltip) end
    GameTooltip:Show()
end

-- Setup -----------------------------------------------------------------------------

function UF:Create()
    if UF.anchor or UF.creating then return end
    UF.creating = true
    ns:AfterCombat("uf-create", function()
        UF.creating = nil
        UF:CreateNow()
    end)
end

function UF:CreateNow()
    if UF.anchor then return end
    createAnchor()
    for i, unit in ipairs(MEMBER_UNITS) do
        createButton(unit, nil, false, i)
        createButton(PET_UNITS[unit], unit, true, i + 5)
    end
    UF:Layout()
    ns:Fire("FRAMES_CREATED")
end

local function route(updateFn)
    return function(_, unit)
        local button = unit and UF.byUnit[unit]
        if button and button:IsShown() then updateFn(UF, button) end
    end
end

function UF:Init()
    ns:RegisterEvent("PLAYER_LOGIN", function()
        UF:Create()
    end)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if UF.anchor then UF:UpdateEverything() end
    end)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if UF.anchor then
            UF:UpdateEverything()
            if ns.db.frames.sortMode ~= "manual" then UF:Layout(true) end
        end
    end)
    ns:RegisterEvent("UNIT_PET", function(_, owner)
        local button = owner and UF.byUnit[PET_UNITS[owner] or ""]
        if button then UF:UpdateAll(button) end
    end)
    ns:RegisterEvent("UNIT_HEALTH", route(UF.UpdateHealth))
    ns:RegisterEvent("UNIT_MAXHEALTH", route(UF.UpdateHealth))
    ns:RegisterEvent("UNIT_HEAL_PREDICTION", route(UF.UpdatePrediction))
    ns:RegisterEvent("UNIT_POWER_UPDATE", route(UF.UpdatePower))
    ns:RegisterEvent("UNIT_MAXPOWER", route(UF.UpdatePower))
    ns:RegisterEvent("UNIT_DISPLAYPOWER", route(UF.UpdatePower))
    ns:RegisterEvent("UNIT_NAME_UPDATE", route(UF.UpdateName))
    ns:RegisterEvent("UNIT_CONNECTION", route(UF.UpdateState))
    ns:RegisterEvent("UNIT_IN_RANGE_UPDATE", route(UF.UpdateRange))
    ns:RegisterEvent("SPELLS_CHANGED", function() rangeSpellChecked = nil end)
    ns:RegisterEvent("UNIT_FLAGS", route(UF.UpdateState))
    ns:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE", function(_, unit)
        if unit then
            local button = UF.byUnit[unit]
            if button and button:IsShown() then UF:UpdateThreat(button) end
        else
            for _, button in ipairs(UF.buttons) do
                if button:IsShown() then UF:UpdateThreat(button) end
            end
        end
    end)
    ns:RegisterEvent("UNIT_AURA", function(_, unit, updateInfo)
        local button = unit and UF.byUnit[unit]
        if button and button:IsShown() then
            ns.Auras.Update(button, "event", updateInfo)
            if UF.hovered == button then UF:ShowTooltip(button) end
        end
    end)
    ns:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        for _, button in ipairs(UF.buttons) do
            if button:IsShown() then UF:UpdateTargetHighlight(button) end
        end
    end)
    ns:RegisterEvent("PLAYER_ROLES_ASSIGNED", function()
        for _, button in ipairs(UF.buttons) do
            if UF.anchor then UF:UpdateRole(button) end
        end
    end)
    ns:RegisterEvent("MODIFIER_STATE_CHANGED", function()
        if UF.debugClickWatch then ns.RunDebug("click watch", function() UF:DebugClick("player") end) end
        if UF.hovered then UF:ShowTooltip(UF.hovered) end
    end)
    ns:On("CONFIG_CHANGED", function(group)
        if not UF.anchor then return end
        if group == "roles" then
            for _, button in ipairs(UF.buttons) do UF:UpdateRole(button) end
            return
        end
        if group == "presets" or group == "bindings" or group == "pins" or group == "minimap" then return end
        if group == "raid" then return end
        UF:Layout()
    end)
end

UF:Init()
