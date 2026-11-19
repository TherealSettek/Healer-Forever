local ADDON_NAME, ns = ...

-- Raid layout: 40 SecureUnitButtonTemplate buttons with FIXED unit tokens (raid1..raid40), shown by RegisterUnitWatch and
-- positioned out of combat (the same model as the party frames). No SecureGroupHeaderTemplate: a header re-assigns
-- "unit" in combat, which would make the click-cast macros (baked with @raidN out of combat) cast on the wrong person.
-- With fixed tokens a click is always right; only a cell position can be stale until combat ends.
--
-- Switching (RF:Evaluate): the wanted layout comes from RaidLayout.DesiredLayout; a change in combat is queued
-- ("raid-switch") with one chat line. RF:Apply swaps the layouts out of combat:
--   raid  -> UnitFrames:SetSuspended(true), tokens, Layout (cells, unit watch, anchor), RAID_LAYOUT_CHANGED
--   party -> raid buttons unwatched + hidden, anchor hidden, RAID_LAYOUT_CHANGED (ClickCast clears them),
--            UnitFrames:SetSuspended(false) (today's party Layout).
-- Every protected call (attributes, points, size, scale, show/hide, unit watch) runs out of combat: keys rf-create,
-- raid-switch, rf-layout. Unit values are secret-safe: widget setters only, issecret before any test.
--
-- My buffs (top-right markers): worked out OUT OF COMBAT only (aura data is locked in combat) by a 0.5 s tick on the
-- raid anchor, at most 8 members per tick, only for members marked dirty (UNIT_AURA out of combat, roster, combat
-- end, settings, SPELLS_CHANGED) or whose next timed change is due (RaidLayout.NextBuffCheck). In combat the markers
-- hide (or stay dimmed: raid.buffs.inCombat = "dim"). Not clickable.
-- Dispellable debuffs (bottom-right): the game's AuraContainer with "HARMFUL|RAID_PLAYER_DISPELLABLE" draws them, also
-- in combat; its unit is set out of combat only ("none" in party mode or when the display doesn't use it). The bar glow
-- has its own container per bar (max 1 invisible carrier button, shown by the game while a debuff I can dispel is on):
-- a bar-sized texture in a plain holder frame on that carrier is handed to it with AddDispelTypeTexture, so the game
-- tints it (needs checking in game; any error -> RF.glowSupported = false, logged once, icons instead). Containers are
-- created on the first switch to the raid layout, only for the parts the display uses.
--
-- Leaving the raid in combat (Auto mode): secure visibility drivers on both anchors ("[group:raid]") hide the raid
-- frame and show the party frames at once; the party buttons keep their unit watch while the raid layout is active.
-- The full switch (layout, click-casting) still happens out of combat.
local RF = { buttons = {}, byUnit = {}, alias = {}, active = "party", buffDirty = {}, buffNext = {} }
ns.RaidFrames = RF

local issecret = ns.issecret
local max = math.max

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 8,
    insets = { left = 2, right = 2, bottom = 2, top = 2 },
}
local TEMPLATE = "SecureUnitButtonTemplate,SecureHandlerEnterLeaveTemplate,SecureHandlerStateTemplate,BackdropTemplate"
local MEMBER_UNITS = { "player", "party1", "party2", "party3", "party4" }
local RS = ns.RaidStyle
local GREY = RS.COLORS.grey
local TICK = 0.2
local PER_TICK = 10
local BUFF_TICK = 0.5
local BUFF_PER_TICK = 8
RF.BUFF_TICK, RF.BUFF_PER_TICK = BUFF_TICK, BUFF_PER_TICK
-- roster / option bursts are coalesced into one Evaluate after this delay (longer in combat: visuals only)
RF.EVAL_DELAY, RF.EVAL_DELAY_COMBAT = 0.1, 0.3

local function cfg() return ns.db.raid end
local function UF() return ns.UnitFrames end
local function Auras() return ns.Auras end

-- Unit updates (non-protected: safe in combat) ---------------------------------------------------------------------
-- Every unit value may be secret: it is only passed to widget setters (SetValue, SetText, SetStatusBarColor from a
-- curve, SetAlphaFromBoolean) or tested after issecret(). Painting goes through RaidStyle so the preview matches.

local calc

local function readableHealth(unit)
    local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
    if issecret(hp) or issecret(mx) or type(hp) ~= "number" or type(mx) ~= "number" then return nil end
    return hp, mx
end

-- curve -> colour object -> widget setter; called in pcall (any missing method or refused secret falls back)
local function barFromCurve(bar, unit, curve)
    bar:SetStatusBarColor(UnitHealthPercent(unit, false, curve):GetRGB())
end

local function textFromCurve(fs, unit, curve)
    fs:SetTextColor(UnitHealthPercent(unit, false, curve):GetRGBA())
end

-- float Step curve -> alpha (SetAlpha accepts a secret number)
local function alphaFromCurve(fs, unit, curve)
    fs:SetAlpha(UnitHealthPercent(unit, false, curve))
end

local function isMe(unit)
    if unit == "player" then return true end
    if not UnitIsUnit then return false end
    local ok, same = pcall(UnitIsUnit, unit, "player")
    if not ok or issecret(same) then return false end
    return same and true or false
end

local function nameLook(button)
    if button.isMe then return "me" end
    if (button.state and button.state ~= "alive") or button.rangeState == "hidden" then return "dim" end
    return nil
end

function RF:UpdateName(button)
    local unit = button.unit
    if not ns.Exists(unit) then return end
    button.name:SetText(UnitName(unit))
    button.isMe = isMe(unit)
    RS.SetNameColor(button, nameLook(button))
end

-- Bar colour. Alive: full class colour while hurt, muted at full health (raid.muteFull). In order:
--   1. Step colour curve per class through UnitHealthPercent (works with secret health)
--   2. readable health: hp >= max -> muted
--   3. unknown (secret, no curve API): full colour, so a hurt bar is never hidden
-- Dead / ghost / offline / not visible: grey.
function RF:ApplyColor(button)
    if button.state ~= "alive" or button.rangeState == "hidden" then
        RS.SetBarColor(button, GREY[1], GREY[2], GREY[3])
        return
    end
    local unit = button.unit
    local r, g, b, token = UF().ClassColorFor(unit)
    if not cfg().muteFull then
        RS.SetBarColor(button, r, g, b)
        return
    end
    local curve = UnitHealthPercent and RS.MuteCurve(token or "?", r, g, b)
    if curve and pcall(barFromCurve, button.health, unit, curve) then return end
    local hp, mx = readableHealth(unit)
    RS.SetBarMuted(button, r, g, b, hp ~= nil and mx > 0 and hp >= mx)
end

local function known(value) return issecret(value) or value ~= nil end

-- Missing health (may be secret): UnitHealthMissing, else the heal-prediction calculator's missing health; nil when
-- neither answers.
local function healthMissing(unit)
    if UnitHealthMissing then
        local ok, value = pcall(UnitHealthMissing, unit, false)
        if ok and known(value) then return value end
    end
    if CreateUnitHealPredictionCalculator and UnitGetDetailedHealPrediction then
        local ok, value = pcall(function()
            calc = calc or CreateUnitHealPredictionCalculator()
            UnitGetDetailedHealPrediction(unit, nil, calc)
            return calc:GetMissingHealth()
        end)
        if ok and known(value) then return value end
    end
    return nil
end
RF.HealthMissing = healthMissing

local function setColor(fs, c) fs:SetTextColor(c[1], c[2], c[3], 1) end

-- Percent text, red while hurt / grey at full (Step colour curve; readable fallback; unknown -> red).
local function paintPercent(fs, unit)
    UF().SetPercentText(fs, unit)
    local curve = UnitHealthPercent and RS.PercentColorCurve()
    if curve and pcall(textFromCurve, fs, unit, curve) then return end
    local hp, mx = readableHealth(unit)
    setColor(fs, (hp ~= nil and mx > 0 and hp >= mx) and RS.COLORS.percentFull or RS.COLORS.percentHurt)
end

-- Centre text: DEAD / CAN'T RES (dead and out of range or not visible) / GHOST / OFFLINE / "?" (not visible), else
-- the health number per raid.healthText:
--   deficit  UnitHealthMissing (else the heal-prediction calculator) -> UF.SetDeficit in a constant red, shown only
--            when hurt through FontString:SetAlpha(UnitHealthPercent(unit, false, RS.HurtAlphaCurve())) (alpha 1
--            below full, 0 at full; no truth test; if that fails the text stays visible). Fallbacks: readable
--            max > 0 -> max - hp; else the percent text (colour as below).
--   percent  UF.SetPercentText, red while hurt / grey at full (Step curve; readable fallback; unknown -> red).
--   none     no number.
function RF:UpdateCenterText(button)
    local state, range = button.state, button.rangeState
    if state == "dead" then
        RS.ShowState(button, (range == "out" or range == "hidden") and "cantres" or "dead")
        return
    elseif state and state ~= "alive" then
        RS.ShowState(button, state)
        return
    end
    if range == "hidden" then
        RS.ShowState(button, "hidden")
        return
    end
    local unit, mode = button.unit, cfg().healthText
    local fs = RS.ShowNumber(button, mode)   -- alpha back to 1
    if mode == "deficit" then
        local missing = healthMissing(unit)
        if known(missing) then
            UF().SetDeficit(fs, missing)
            setColor(fs, RS.COLORS.deficit)
            local curve = UnitHealthPercent and RS.HurtAlphaCurve()
            if curve then pcall(alphaFromCurve, fs, unit, curve) end
            return
        end
        local hp, mx = readableHealth(unit)
        if hp ~= nil and mx > 0 then
            UF().SetDeficit(fs, mx - hp)
            setColor(fs, RS.COLORS.deficit)
        else
            paintPercent(fs, unit)
        end
    elseif mode == "percent" then
        paintPercent(fs, unit)
    end
end

local function incomingHeals(unit)
    if CreateUnitHealPredictionCalculator and UnitGetDetailedHealPrediction then
        calc = calc or CreateUnitHealPredictionCalculator()
        UnitGetDetailedHealPrediction(unit, nil, calc)
        return calc:GetIncomingHeals()
    elseif UnitGetIncomingHeals then
        return UnitGetIncomingHeals(unit)
    end
    return nil
end

-- Incoming heals bar (raid.showIncoming), no text. The amount may be secret: straight into SetValue.
function RF:UpdatePrediction(button)
    local unit, pred = button.unit, button.pred
    if not cfg().showIncoming or button.state ~= "alive" or button.rangeState == "hidden" or not ns.Exists(unit) then
        pred:Hide()
        return
    end
    local ok, amount = pcall(incomingHeals, unit)
    if not ok or (not issecret(amount) and amount == nil) then
        pred:Hide()
        return
    end
    pred:SetMinMaxValues(0, UnitHealthMax(unit))
    pred:SetValue(amount)
    pred:Show()
end

function RF:UpdateHealth(button)
    local unit = button.unit
    if not ns.Exists(unit) then return end
    if button.state == "alive" then
        button.health:SetMinMaxValues(0, UnitHealthMax(unit))
        button.health:SetValue(UnitHealth(unit))
        RF:ApplyColor(button)
    end
    RF:UpdateCenterText(button)
    RF:UpdatePrediction(button)
end

function RF:UpdateState(button)
    local unit = button.unit
    if not ns.Exists(unit) then return end
    local state = UF().ComputeState(unit)
    local previous = button.state
    button.state = state
    if state == previous then return end
    if state == "alive" then
        RF:UpdateHealth(button)
    else
        -- dead / ghost: empty bar (the state text says it); offline: full grey bar
        button.health:SetMinMaxValues(0, 1)
        button.health:SetValue(state == "offline" and 1 or 0)
        RF:UpdateCenterText(button)
        RF:UpdatePrediction(button)
    end
    RF:ApplyColor(button)
    RS.SetNameColor(button, nameLook(button))
    RS.SetAggro(button, button.aggro and state == "alive")
    RF:BuffStateChanged(button)
end

-- Range: the whole button dims to raid.rangeAlpha when out of range / not visible / offline; dashed outline (out)
-- / dotted (not visible). A secret in-range answer drives the button alpha and the dashes through
-- SetAlphaFromBoolean (no truth test on it). No badge.
function RF:UpdateRange(button)
    local unit = button.unit
    local alpha = cfg().rangeAlpha / 100
    local mode, secretValue
    if unit == "player" or not ns.Exists(unit) then
        mode = "in"
    elseif button.state == "offline" then
        mode = "offline"
    else
        local state, maybeSecret = UF().RangeState(unit)
        if issecret(maybeSecret) then
            mode, secretValue = "secret", maybeSecret
        else
            mode = state
        end
    end
    RS.SetRange(button, mode, alpha, secretValue)
    if mode ~= button.rangeState then
        local previousRange = button.rangeState
        button.rangeState = mode
        RF:ApplyColor(button)
        RF:UpdateCenterText(button)
        RF:UpdatePrediction(button)
        RS.SetNameColor(button, nameLook(button))
        if mode == "hidden" or previousRange == "hidden" then RF:BuffStateChanged(button) end
    end
end

-- Target outline (white). A secret answer drives the outline alpha through SetAlphaFromBoolean.
function RF:UpdateTarget(button)
    local unit = button.unit
    if not UnitIsUnit or not ns.Exists(unit) then
        RS.SetTarget(button, false)
        return
    end
    local ok, value = pcall(UnitIsUnit, unit, "target")
    if not ok then value = false end
    RS.SetTarget(button, value)
end

-- Aggro outline (red) at threat status >= 2. A secret status keeps the last known state.
function RF:UpdateThreat(button)
    if not UnitThreatSituation or not ns.Exists(button.unit) then return end
    local ok, status = pcall(UnitThreatSituation, button.unit)
    if not ok or issecret(status) then return end
    button.aggro = type(status) == "number" and status >= 2
    RS.SetAggro(button, button.aggro and button.state == "alive")
end

local function readableGuid(unit)
    if not UnitGUID then return nil end
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or issecret(guid) or type(guid) ~= "string" then return nil end
    return guid
end

-- True when another player may now sit behind the button's token (GUID differs, or can't be read).
local function guidDiffers(button)
    local guid = readableGuid(button.unit)
    return guid == nil or guid ~= button.guid
end

-- A different (or unknown) player behind the token: last member's buff results are dropped (markers, missing
-- count, smart-buff targets) and re-checked out of combat.
function RF:SyncGuid(button)
    local guid = readableGuid(button.unit)
    if guid ~= nil and guid == button.guid then return false end
    button.guid = guid
    button.buffMarkerData, button.buffPending, button.buffMissing = nil, nil, nil
    button.buffReport, button.buffNote = nil, nil
    RF.buffNext[button] = nil
    RF.buffDirty[button] = true
    RF:RenderBuffMarkers(button)
    return true
end

function RF:UpdateAll(button)
    if not ns.Exists(button.unit) then return end
    RF:SyncGuid(button)
    button.state = nil
    RF:UpdateName(button)
    RF:UpdateState(button)
    RF:UpdateHealth(button)
    RF:UpdateRange(button)
    RF:UpdateThreat(button)
    RF:UpdateTarget(button)
    RF:ApplyColor(button)
    RF.buffDirty[button] = true
    RF:UpdateDebuffUnit(button)
end

function RF:UpdateEverything()
    if RF.active ~= "raid" then return end
    for _, button in ipairs(RF.buttons) do
        if button:IsShown() then RF:UpdateAll(button) end
    end
end

-- Roster change in combat: only the bars whose player changed (or can't be told) are refreshed.
function RF:UpdateChanged()
    if RF.active ~= "raid" then return 0 end
    local n = 0
    for _, button in ipairs(RF.buttons) do
        if button:IsShown() and guidDiffers(button) then
            RF:UpdateAll(button)
            n = n + 1
        end
    end
    return n
end

-- My buffs (out of combat) ----------------------------------------------------------------------------------------

local function buffCfg() return cfg().buffs end

local function isDown(button)
    return (button.state ~= nil and button.state ~= "alive") or button.rangeState == "hidden"
end

-- Marker data for RaidStyle (plain values): icon, colour state, count, sweep window.
local function markerData(report, percent, now)
    local b = buffCfg()
    local BB = ns.BuffButtons
    local out = {}
    for i, m in ipairs(ns.RaidLayout.BuffMarkers(report, b.multi, b.showEnding)) do
        local def = ns.Classes.BUFFS[m.key]
        local d = { kind = m.kind, key = m.key, count = m.count,
            icon = BB and BB.IconFor and BB.IconFor(def and def.name, def) or nil }
        if m.kind == "end" then
            local dur = ns.RaidLayout.ItemDuration(m.item)
            if dur and percent > 0 then
                d.window = dur * percent / 100
                d.start = now + m.item.remaining - d.window
            end
        end
        out[i] = d
    end
    return out
end

-- Draws the last worked-out markers: in combat hidden (default) or dimmed; dead / offline / not visible: none.
function RF:RenderBuffMarkers(button)
    local b = buffCfg()
    local data = button.buffMarkerData
    if RF.active ~= "raid" or not b.show or isDown(button) then data = nil end
    local dim = false
    if ns.InCombat() then
        if b.inCombat == "dim" then dim = true else data = nil end
    end
    RS.SetBuffMarkers(button, data, b.endingLook, dim)
end

-- Death, offline or "not visible": the markers go now (also in combat); the member is re-checked out of combat.
function RF:BuffStateChanged(button)
    if isDown(button) then
        button.buffMarkerData = nil
        button.buffPending, button.buffMissing = nil, nil
    end
    RF.buffDirty[button] = true
    RF:RenderBuffMarkers(button)
end

-- Works out one member's buffs (out of combat only). cache = BuffButtons gather cache for this tick.
function RF:UpdateBuffs(button, cache, now)
    RF.buffDirty[button] = nil
    if ns.InCombat() then return end
    now = now or GetTime()
    local b = buffCfg()
    local BB = ns.BuffButtons
    button.buffMarkerData, button.buffPending, button.buffMissing = nil, nil, nil
    button.buffReport, button.buffNote = nil, nil
    RF.buffNext[button] = nil
    if RF.active ~= "raid" or not b.show or not BB or not BB.EvaluateUnit or not ns.Exists(button.unit) then
        button.buffNote = not b.show and "my buff markers are off" or nil
        RF:RenderBuffMarkers(button)
        return
    end
    if isDown(button) then
        button.buffNote = button.rangeState == "hidden" and "not visible" or "dead or offline"
        RF:RenderBuffMarkers(button)
        return
    end
    -- my own bar uses "player" so the preset's "Self (you)" rule applies, like the party frames
    local unit = button.isMe and "player" or button.unit
    local percent = b.rebuffPercent
    local missing, _, diag = BB.EvaluateUnit(unit, cache, percent)
    local report = diag and diag.report or nil
    button.buffReport = report
    button.buffNote = diag and diag.hidden or nil
    button.buffMarkerData = report and markerData(report, percent, now) or nil
    RF.buffNext[button] = report and ns.RaidLayout.NextBuffCheck(report, percent, now) or nil
    button.buffMissing = #missing
    -- castable now: what the smart buff key may pick on the raid
    local pending = {}
    local info = cache and cache[unit]
    for _, key in ipairs(missing) do
        local entry = BB.ArmEntry and BB.ArmEntry(unit, key)
        if entry and entry.state == "ready" then
            pending[#pending + 1] = { unit = unit, role = info and info.role or nil, kind = "blessing",
                spell = entry.single or entry.greater, isSelf = unit == "player" }
        end
    end
    button.buffPending = pending
    RF:RenderBuffMarkers(button)
end

-- One tick: up to BUFF_PER_TICK shown members that are dirty or due, round robin. Returns how many were checked.
local buffCursor = 0
function RF:BuffTick()
    if RF.active ~= "raid" or ns.InCombat() or not ns.db then return 0 end
    local now = GetTime()
    local n, done, cache = #RF.buttons, 0, {}
    for _ = 1, n do
        buffCursor = buffCursor % n + 1
        local button = RF.buttons[buffCursor]
        if button:IsShown() then
            local due = RF.buffNext[button]
            if RF.buffDirty[button] or (due and due <= now) then
                RF:UpdateBuffs(button, cache, now)
                done = done + 1
                if done >= BUFF_PER_TICK then break end
            end
        end
    end
    RF.lastBuffTick = done
    return done
end

function RF:MarkAllBuffsDirty()
    for _, button in ipairs(RF.buttons) do RF.buffDirty[button] = true end
end

-- Combat start / end and option changes: redraw from the last known data (hide / dim / normal).
function RF:RenderAllBuffMarkers()
    for _, button in ipairs(RF.buttons) do RF:RenderBuffMarkers(button) end
end

-- Missing class buffs on the shown raid bars (minimap dot / count while the raid layout is active).
function RF:MissingCount()
    if RF.active ~= "raid" then return 0 end
    local n = 0
    for _, button in ipairs(RF.buttons) do
        if button:IsShown() and button.buffMissing then n = n + button.buffMissing end
    end
    return n
end

-- Castable missing buffs on the shown raid bars, for the smart buff key (Presets.PickNext format).
function RF:PendingList()
    local out = {}
    if RF.active ~= "raid" then return out end
    for _, button in ipairs(RF.buttons) do
        if button:IsShown() and ns.Exists(button.unit) then
            for _, e in ipairs(button.buffPending or {}) do out[#out + 1] = e end
        end
    end
    return out
end

-- Dispellable debuffs ------------------------------------------------------------------------------------------------
-- Two game-drawn parts per bar, each only while the display uses it:
--   icons  button.debuffContainer in button.debuffZone (raid template: no mouse from creation on)
--   glow   button.glowContainer in button.glowFrame: max 1 invisible carrier button; the game shows it while a debuff
--          I can dispel is on. Each carrier gets a plain holder frame (child of the carrier, so it hides with it) with
--          the glow texture, handed to the game with AddDispelTypeTexture (the game tints / shows the texture; we only
--          show / hide / alpha the holder and our own glowFrame / debuffZone). The holder sits just under the texts.
-- A display that doesn't use a part sets its container's unit to "none" and hides our zone frame (alpha 0).

function RF:DebuffMode() return RS.DebuffMode(cfg()) end

local function wantsGlow(mode) return mode == "glow" or mode == "glowIcons" end
local function wantsIcons(mode) return mode == "icons" or mode == "glowIcons" end
RF.WantsGlow, RF.WantsIcons = wantsGlow, wantsIcons

-- First failure handing the glow to the game: logged once, every bar falls back to icons (re-laid out after combat).
function RF:GlowFailed(err)
    if RF.glowSupported == false then return end
    RF.glowSupported = false
    RF.glowError = tostring(err)
    if not RF.glowLogged then
        RF.glowLogged = true
        ns.LogError("raid-glow", "dispel glow unavailable, showing icons: " .. tostring(err))
    end
    for _, button in ipairs(RF.buttons) do
        RF:StyleDebuffs(button)
        RF:UpdateDebuffUnit(button)
    end
    RF:RequestEvaluate()   -- the icon reserve changes: new text layout (out of combat)
end

-- Hands one glow carrier its glow texture (once per carrier: a carrier the game re-initialises keeps its holder).
-- Not in "icons" display: the glow is never attached there.
function RF:AttachGlow(button, frame)
    if frame.hfGlowHolder or RF.glowSupported == false or not wantsGlow(RF:DebuffMode()) then return end
    local holder
    local ok, err = pcall(function()
        if type(frame.AddDispelTypeTexture) ~= "function" then error("AddDispelTypeTexture is missing") end
        local style = Enum and Enum.CustomAuraButtonDispelTypeTextureStyle
        if not style or style.Border == nil then error("no dispel texture styles") end
        holder = ns.NewFrame("Frame", nil, frame)
        holder:SetAllPoints(button.glowFrame)
        -- above the health bar, under the name / number text and the debuff icons
        holder:SetFrameLevel(max(1, button.textFrame:GetFrameLevel() - 1))
        local glow = holder:CreateTexture(nil, "OVERLAY")
        glow:SetAllPoints(holder)
        holder.glow = glow
        frame:AddDispelTypeTexture(glow, { style = style.Border, showWhenHarmful = true })
    end)
    if not ok then
        if holder then holder:Hide() end
        RF:GlowFailed(err)
        return
    end
    frame.hfGlowHolder = holder
    button.glowHost, button.glowHolder = frame, holder
    RF.glowSupported = true
end

-- Which parts show for the current display: our own frames only (alpha / shown), safe in combat.
function RF:StyleDebuffs(button)
    local mode = RF:DebuffMode()
    local on = cfg().debuffs.show and true or false
    button.debuffZone:SetAlpha((on and wantsIcons(mode)) and 1 or 0)
    button.glowFrame:SetAlpha((on and wantsGlow(mode)) and 1 or 0)
    -- RS.Build's own glow texture is for the preview only
    if button.dispelGlow then button.dispelGlow:Hide() end
    if button.glowHolder then button.glowHolder:SetShown(on and wantsGlow(mode)) end
    if on and wantsGlow(mode) and button.glowContainer then
        Auras().EachContainerFrame(button.glowContainer, function(f) RF:AttachGlow(button, f) end)
    end
end

-- Creates the containers the display needs (out of combat; first raid layout, or when the display changes).
-- A failed creation is logged once and not retried.
function RF:EnsureDebuffContainers(button)
    if ns.InCombat() or not Auras() or not Auras().CreateDebuffContainer then return end
    local c = cfg()
    if not c.debuffs.show then return end
    local mode = RF:DebuffMode()
    if wantsIcons(mode) and not button.debuffContainer and not button.debuffTried then
        button.debuffTried = true
        local res = button.reserves or ns.RaidLayout.Reserves(c, 0, mode)
        button.debuffContainer = Auras().CreateDebuffContainer(button, button.debuffZone,
            Auras().DebuffContainerGeometry(res.isz, c.debuffs.max))
    end
    if wantsGlow(mode) and not button.glowContainer and not button.glowTried then
        button.glowTried = true
        button.glowContainer = Auras().CreateDebuffContainer(button, button.glowFrame, Auras().GlowContainerGeometry(),
            { onInit = function(frame) RF:AttachGlow(button, frame) end })
    end
end

-- Size, max and position of the debuff icons for the current settings (out of combat: layout time).
function RF:ApplyDebuffConfig(button)
    RF:EnsureDebuffContainers(button)
    RS.PlaceDebuffZone(button)
    local st = button.debuffContainer
    if st then
        local c = cfg()
        local res = button.reserves or ns.RaidLayout.Reserves(c, 0, RF:DebuffMode())
        Auras().ConfigureContainer(st, Auras().DebuffContainerGeometry(res.isz, c.debuffs.max))
    end
    RF:StyleDebuffs(button)
    RF:UpdateDebuffUnit(button)
end

-- Container units: the button's token while the raid layout is active, debuffs are on and the display uses that part,
-- else "none". Never set in combat (Auras.SetContainerUnit queues it).
function RF:UpdateDebuffUnit(button)
    local token
    if RF.active == "raid" and cfg().debuffs.show and button.unit and ns.Exists(button.unit) then token = button.unit end
    local mode = RF:DebuffMode()
    if button.debuffContainer then
        Auras().SetContainerUnit(button.debuffContainer, (token and wantsIcons(mode)) and token or "none")
    end
    if button.glowContainer then
        Auras().SetContainerUnit(button.glowContainer, (token and wantsGlow(mode)) and token or "none")
    end
end

-- Event routing: the raid button for a unit token, or for player / party1..4 through the alias map.
function RF:ButtonFor(unit)
    if RF.active ~= "raid" or not unit then return nil end
    return RF.byUnit[unit] or RF.alias[unit]
end

-- player / party1..4 -> the raid button showing the same unit (UnitIsUnit; secret answers are skipped).
function RF:RebuildAlias()
    local alias = {}
    if RF.active == "raid" then
        for _, a in ipairs(MEMBER_UNITS) do
            if not RF.byUnit[a] and ns.Exists(a) then
                for _, button in ipairs(RF.buttons) do
                    local token = button.unit
                    if token ~= a and ns.Exists(token) then
                        local ok, same = pcall(UnitIsUnit, a, token)
                        if ok and not issecret(same) and same then
                            alias[a] = button
                            break
                        end
                    end
                end
            end
        end
    end
    RF.alias = alias
end

-- Roster ---------------------------------------------------------------------------------------------------------

local function rosterInfo(i)
    if not GetRaidRosterInfo then return nil end
    local ok, _, _, subgroup, _, _, fileName = pcall(GetRaidRosterInfo, i)
    if not ok then return nil end
    if issecret(subgroup) or type(subgroup) ~= "number" then subgroup = nil end
    if issecret(fileName) or type(fileName) ~= "string" then fileName = nil end
    return subgroup, fileName
end

local function classOf(unit, fallback)
    if fallback then return fallback end
    if not UnitClass then return nil end
    local ok, _, token = pcall(UnitClass, unit)
    if not ok or issecret(token) or type(token) ~= "string" then return nil end
    return token
end

-- The members behind the 40 buttons: { index, group, role, class }. In a raid the subgroup comes from
-- GetRaidRosterInfo (fallback: ceil(i / 5)); outside a raid ("Always raid") everyone is in group 1.
function RF:ReadRoster()
    local roster = {}
    local inRaid = ns.InRaid()
    local sort = cfg().sortWithin
    for i, button in ipairs(RF.buttons) do
        local unit = button.unit
        if ns.Exists(unit) then
            local group, class
            if inRaid and unit:match("^raid%d+$") then
                group, class = rosterInfo(i)
            else
                group = 1
            end
            if not group then group = math.ceil(i / 5) end
            local entry = { index = i, group = group }
            if sort == "role" then entry.role = ns.Roles and ns.Roles.Get(unit) or nil end
            if sort == "class" then entry.class = classOf(unit, class) end
            roster[#roster + 1] = entry
        end
    end
    return roster
end

-- True when every raid member reported by the roster is in the same subgroup (unknown -> false).
function RF:OneSubgroup()
    local first
    for i = 1, ns.RaidLayout.NUM_BUTTONS do
        if ns.Exists("raid" .. i) then
            local group = rosterInfo(i)
            if not group then return false end
            first = first or group
            if group ~= first then return false end
        end
    end
    return first ~= nil
end

-- Tokens: raid1..raid40 in a raid; outside a raid ("Always raid") the first five buttons show player, party1..4.
-- Out of combat only. Returns true when any token changed (ClickCast must then re-apply).
function RF:AssignTokens()
    local inRaid = ns.InRaid()
    local changed = false
    RF.byUnit = {}
    for i, button in ipairs(RF.buttons) do
        local token = "raid" .. i
        if not inRaid and i <= #MEMBER_UNITS then token = MEMBER_UNITS[i] end
        if button.unit ~= token then
            button:SetAttribute("unit", token)
            button.unit = token
            button.state, button.rangeState, button.aggro, button.isMe = nil, nil, nil, nil
            button.guid = nil
            changed = true
        end
        RF.byUnit[token] = button
    end
    return changed
end

-- Layout (out of combat) -------------------------------------------------------------------------------------------

local function placeLabels(plan)
    local c = cfg()
    for g = 1, ns.RaidLayout.NUM_GROUPS do
        local fs = RF.labels[g]
        local spot = plan.grid.labels[g]
        fs:ClearAllPoints()
        if c.groupLabels and spot and spot.shown then
            if c.groupArrange == "rows" then
                fs:SetPoint("LEFT", RF.anchor, "TOPLEFT", spot.x, -(spot.y + c.height / 2))
            else
                fs:SetPoint("TOPLEFT", RF.anchor, "TOPLEFT", spot.x, -spot.y)
            end
            fs:Show()
        else
            fs:Hide()
        end
    end
end

-- Every raid setting except the position, plus the debuff display in use: a change means every bar is re-styled.
local function styleKey(c)
    local parts = {}
    local function add(prefix, t)
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = t[k]
            if type(v) == "table" then
                if k ~= "point" then add(prefix .. k .. ".", v) end
            else
                parts[#parts + 1] = prefix .. k .. "=" .. tostring(v)
            end
        end
    end
    add("", c)
    parts[#parts + 1] = "mode=" .. tostring(RS.DebuffMode(c))
    return table.concat(parts, ";")
end
RF.StyleKey = styleKey

-- Auto layout inside a raid: the anchors are handed to secure visibility drivers (see the header).
local function wantSoft()
    return cfg().layoutMode == "auto" and ns.InRaid() and true or false
end

-- RF.anchor visibility driver ("[group:raid] show; hide"), out of combat only. Off: the addon shows / hides it.
function RF:SetSoftDriver(on)
    on = on and true or false
    if ns.InCombat() or on == (RF.softDriver or false) then return end
    if on then
        RF.anchor:Show()
        RegisterStateDriver(RF.anchor, "visibility", "[group:raid] show; hide")
        RF.softDriver = true
    else
        UnregisterStateDriver(RF.anchor, "visibility")
        RF.softDriver = nil
    end
end

function RF:Layout(fromApply)
    if not RF.anchor or RF.active ~= "raid" then return end
    if ns.InCombat() then
        -- roster changes in combat: refresh only the bars whose player changed now, move the cells after combat
        ns:AfterCombat("rf-layout", function() RF:Layout() end, true)
        RF:RebuildAlias()
        RF:UpdateChanged()
        return
    end
    local c = cfg()
    local soft = wantSoft()
    UF():SetSuspended(true, soft)
    local tokensChanged = RF:AssignTokens()
    local plan = ns.RaidLayout.AssignCells(RF:ReadRoster(), c)
    RF.plan = plan
    local key = styleKey(c)
    local restyle = RF.styleKey ~= key
    RF.styleKey = key
    for i, button in ipairs(RF.buttons) do
        local cell = plan.byButton[i]
        if restyle or not button.hfCfg then
            RS.Apply(button, c)
            button.rangeState = nil   -- rebuild the dashes for the new size
        end
        RF:ApplyDebuffConfig(button)
        if restyle or button.cellX ~= cell.x or button.cellY ~= cell.y then
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", RF.anchor, "TOPLEFT", cell.x, -cell.y)
            button.cellX, button.cellY = cell.x, cell.y
        end
        button.raidGroup = cell.group
        if not button.watched then RegisterUnitWatch(button); button.watched = true end
    end
    RF.anchor:SetSize(max(1, plan.grid.width), max(1, plan.grid.height))
    RF.anchor:SetScale(c.scale / 100)
    placeLabels(plan)
    RF:ApplyPoint()
    RF:ApplyLock()
    RF:SetSoftDriver(soft)
    if not RF.softDriver then RF.anchor:Show() end
    RF:RebuildAlias()
    RF:MarkAllBuffsDirty()
    RF:UpdateEverything()
    if tokensChanged and not fromApply then ns:Fire("RAID_LAYOUT_CHANGED", "tokens") end
    ns:Fire("RAID_LAID_OUT")
end

function RF:ApplyPoint()
    if not RF.anchor or ns.InCombat() then return end
    local p = cfg().point
    RF.anchor:ClearAllPoints()
    RF.anchor:SetPoint(p.point, UIParent, p.relativePoint, p.x, p.y)
end

-- Handle and outline are plain frames: safe in combat. Shares the party "Lock frames" setting.
function RF:ApplyLock()
    if not RF.handle then return end
    local unlocked = not ns.db.frames.locked
    RF.handle:SetShown(unlocked)
    RF.outline:SetShown(unlocked)
end

-- Switching --------------------------------------------------------------------------------------------------------

function RF:Context()
    local c = cfg()
    local inRaid = ns.InRaid()
    return {
        mode = c.layoutMode, onlyAbove5 = c.onlyAbove5, inRaid = inRaid, size = ns.GroupSize(),
        instanceType = ns.InstanceType(), oneSubgroup = inRaid and RF:OneSubgroup() or false,
    }
end

-- Roster and option bursts: one Evaluate shortly after the last request (a slider drag or a raid forming fires many
-- events). C_Timer works in combat; the layout itself still waits for combat end.
function RF:RequestEvaluate()
    if not RF.anchor or RF.evalPending then return end
    -- party layout and not in a raid: Evaluate is cheap (no roster read, no layout), so it runs at once as before
    if not (C_Timer and C_Timer.After) or (RF.active ~= "raid" and not ns.InRaid()) then
        RF:Evaluate()
        return
    end
    RF.evalPending = true
    C_Timer.After(ns.InCombat() and RF.EVAL_DELAY_COMBAT or RF.EVAL_DELAY, function()
        RF.evalPending = nil
        RF:Evaluate()
    end)
end

function RF:Evaluate()
    if not RF.anchor or not ns.db then return end
    local want, reason = ns.RaidLayout.DesiredLayout(RF:Context())
    RF.wanted, RF.reason = want, reason
    if want == RF.active then
        if want == "raid" then RF:Layout() end
        return
    end
    if ns.InCombat() then
        -- leaving the raid in Auto: the visibility drivers already show the party frames; no chat line needed
        local quiet = want == "party" and RF.softDriver
        if not RF.switchQueued then
            RF.switchQueued = true
            if not quiet then ns:Print((want == "raid" and "Raid" or "Party") .. " layout: switching after combat.") end
        end
        ns:AfterCombat("raid-switch", function()
            RF.switchQueued = nil
            RF:Evaluate()
        end, true)
        return
    end
    RF:Apply(want)
end

function RF:Apply(layout)
    if not RF.anchor then return end
    if ns.InCombat() then
        ns:AfterCombat("raid-switch", function() RF.switchQueued = nil; RF:Evaluate() end, true)
        return
    end
    if layout == "raid" then
        UF():SetSuspended(true, wantSoft())
        RF.active = "raid"
        RF:Layout(true)
        ns:Fire("RAID_LAYOUT_CHANGED", "raid")
    else
        RF.active = "party"
        if RF.hovered and GameTooltip then GameTooltip:Hide() end
        RF.hovered = nil
        for _, button in ipairs(RF.buttons) do
            if button.watched then UnregisterUnitWatch(button); button.watched = false end
            button:Hide()
            button.buffMarkerData, button.buffPending, button.buffMissing, button.buffReport = nil, nil, nil, nil
            RF.buffNext[button], RF.buffDirty[button] = nil, nil
            RF:RenderBuffMarkers(button)
            RF:UpdateDebuffUnit(button)
        end
        RF:SetSoftDriver(false)
        RF.anchor:Hide()
        RF.alias = {}
        ns:Fire("RAID_LAYOUT_CHANGED", "party")
        UF():SetSuspended(false)
    end
end

-- The buttons ClickCast arms: all 40 while the raid layout is active, none otherwise.
function RF:ActiveButtons()
    if RF.active == "raid" then return RF.buttons end
    return {}
end

function RF:IsActive() return RF.active == "raid" end

-- Construction -----------------------------------------------------------------------------------------------------

local function buffLine(tooltip, item, percent)
    local def = ns.Classes.BUFFS[item.key]
    local name = def and def.name or tostring(item.key)
    local state = ns.RaidLayout.BuffItemState(item)
    local fmt = ns.Util.FormatAuraTime
    if state == "miss" then
        tooltip:AddLine(name .. ": missing", 1, 0.82, 0)
    elseif state == "end" then
        local dur = ns.RaidLayout.ItemDuration(item)
        local text = name .. ": ending, " .. fmt(item.remaining) .. " left"
        if dur then text = text .. " of " .. fmt(dur) end
        if type(item.pct) == "number" then text = text .. string.format(" (%.1f %%, rebuff under %s %%)", item.pct, tostring(percent)) end
        tooltip:AddLine(text, 1, 0.54, 0.1)
    elseif type(item.remaining) == "number" and item.remaining > 0 then
        tooltip:AddLine(name .. ": " .. fmt(item.remaining) .. " left", 0.7, 0.7, 0.7)
    else
        tooltip:AddLine(name .. ": on", 0.7, 0.7, 0.7)
    end
end

-- Extra bar-tooltip lines (UnitFrames ShowTooltip): raid group and my buffs (last check, out of combat only).
local function tooltipExtra(button, tooltip)
    if button.raidGroup and button.unit and button.unit:match("^raid%d+$") then
        tooltip:AddLine("Raid group " .. button.raidGroup, 0.6, 0.6, 0.6)
    end
    local b = ns.db and ns.db.raid and ns.db.raid.buffs
    if not b or not b.show then return end
    if ns.InCombat() then
        tooltip:AddLine("My buffs are re-checked after combat", 0.6, 0.6, 0.6)
        return
    end
    if isDown(button) then
        tooltip:AddLine("My buffs: not checked (" .. (button.rangeState == "hidden" and "not visible" or "dead or offline") .. ")", 0.6, 0.6, 0.6)
        return
    end
    local report = button.buffReport
    if not report or #report == 0 then return end
    tooltip:AddLine("My buffs:", 1, 0.82, 0)
    for _, item in ipairs(report) do buffLine(tooltip, item, b.rebuffPercent) end
end
RF.TooltipExtra = tooltipExtra

local function createButton(i)
    local button = ns.NewFrame("Button", "HealerForeverRaidUnit" .. i, RF.anchor, TEMPLATE)
    local token = "raid" .. i
    button.unit = token
    button.raidIndex = i
    button.isRaid = true
    button:SetAttribute("unit", token)
    -- SecureUnitButton_OnClick has no down/up filter: AnyUp only, or every click would act twice
    button:RegisterForClicks("AnyUp")
    ns.RaidStyle.Build(button)
    button.tooltipExtra = tooltipExtra
    -- debuff / glow containers come on the first switch to the raid layout (RF:EnsureDebuffContainers)
    ns.SecureHook(button, "OnShow", function(self) RF:UpdateAll(self) end)
    ns.SecureHook(button, "OnEnter", function(self) RF.hovered = self; UF():ShowTooltip(self) end)
    ns.SecureHook(button, "OnLeave", function(self)
        if RF.hovered == self then RF.hovered = nil end
        if GameTooltip then GameTooltip:Hide() end
    end)
    button:Hide()
    RF.buttons[i] = button
    RF.byUnit[token] = button
    return button
end

local function createAnchor()
    local anchor = ns.NewFrame("Frame", "HealerForeverRaidFrame", UIParent)
    anchor:SetSize(200, 50)
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    RF.anchor = anchor

    local handle = ns.NewFrame("Button", "HealerForeverRaidHandle", anchor, "BackdropTemplate")
    handle:SetBackdrop(BACKDROP)
    handle:SetBackdropColor(0, 0, 0, 0.8)
    handle:SetHeight(18)
    handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 1)
    handle:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 1)
    handle.label = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    handle.label:SetPoint("CENTER")
    handle.label:SetText("Healer Forever raid - drag to move")
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function()
        if not ns.InCombat() then anchor:StartMoving() end
    end)
    handle:SetScript("OnDragStop", function()
        if ns.InCombat() then return end
        anchor:StopMovingOrSizing()
        local point, _, relativePoint, x, y = anchor:GetPoint()
        if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then return end
        local p = cfg().point
        p.point, p.relativePoint, p.x, p.y = point, relativePoint or point, x, y
    end)
    RF.handle = handle

    local outline = ns.NewFrame("Frame", nil, anchor, "BackdropTemplate")
    outline:SetPoint("TOPLEFT", -4, 4)
    outline:SetPoint("BOTTOMRIGHT", 4, -4)
    outline:SetFrameLevel(anchor:GetFrameLevel() + 20)
    outline:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    outline:SetBackdropBorderColor(1, 0.82, 0, 0.6)
    outline:EnableMouse(false)
    RF.outline = outline

    RF.labels = {}
    for g = 1, ns.RaidLayout.NUM_GROUPS do
        local fs = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetText("G" .. g)
        fs:SetTextColor(1, 0.82, 0)
        fs:Hide()
        RF.labels[g] = fs
    end

    -- one OnUpdate for the whole raid (runs only while the anchor is shown): every 0.2 s ten buttons get their
    -- state and range refreshed (round robin); the hovered tooltip refreshes every 0.5 s; every 0.5 s up to 8 dirty
    -- or due members get their buff markers re-checked (out of combat only)
    local acc, tipAcc, buffAcc, cursor = 0, 0, 0, 0
    anchor:SetScript("OnUpdate", function(_, elapsed)
        if RF.active ~= "raid" then return end
        buffAcc = buffAcc + elapsed
        if buffAcc >= BUFF_TICK then
            buffAcc = 0
            local t0 = ns.perfOn and debugprofilestop()
            RF:BuffTick()
            if t0 then ns.Perf.Add("rfbuffs", t0) end
        end
        tipAcc = tipAcc + elapsed
        if tipAcc >= 0.5 then
            tipAcc = 0
            if RF.hovered then UF():ShowTooltip(RF.hovered) end
        end
        acc = acc + elapsed
        if acc < TICK then return end
        acc = 0
        local t0 = ns.perfOn and debugprofilestop()
        local n = #RF.buttons
        for _ = 1, PER_TICK do
            cursor = cursor % n + 1
            local button = RF.buttons[cursor]
            if button:IsShown() then
                RF:UpdateState(button)
                RF:UpdateRange(button)
            end
        end
        if t0 then ns.Perf.Add("rf", t0) end
    end)
    anchor:Hide()
end

function RF:Create()
    if RF.anchor or RF.creating then return end
    RF.creating = true
    ns:AfterCombat("rf-create", function()
        RF.creating = nil
        RF:CreateNow()
    end, true)
end

function RF:CreateNow()
    if RF.anchor then return end
    createAnchor()
    for i = 1, ns.RaidLayout.NUM_BUTTONS do createButton(i) end
    ns:Fire("RAID_FRAMES_CREATED")
    RF:Evaluate()
end

-- /hf raid and /hf debug raid ----------------------------------------------------------------------------------------

function RF:StatusLine()
    local c = ns.db and ns.db.raid
    local active = RF.active or "party"
    local line = "Layout: " .. active .. (RF.reason and (" (" .. RF.reason .. ")") or "")
        .. " | setting: " .. tostring(c and c.layoutMode) .. ", raid layout only above 5: " .. tostring(c and c.onlyAbove5)
    if RF.switchQueued then line = line .. " | switching to " .. tostring(RF.wanted) .. " after combat" end
    return line
end

function RF:Debug()
    local say = function(text) ns:Print(text) end
    if not RF.anchor then say("raid frames not created yet") return end
    local ctx = RF:Context()
    say(RF:StatusLine())
    say(string.format("context: inRaid=%s size=%s instance=%s oneSubgroup=%s combat=%s", tostring(ctx.inRaid),
        tostring(ctx.size), tostring(ctx.instanceType), tostring(ctx.oneSubgroup), tostring(ns.InCombat())))
    local c = cfg()
    say(string.format("style: muteFull=%s healthText=%s incoming=%s rangeAlpha=%s | curves=%s UnitHealthPercent=%s UnitHealthMissing=%s",
        tostring(c.muteFull), tostring(c.healthText), tostring(c.showIncoming), tostring(c.rangeAlpha),
        tostring(RS.CurvesSupported() and true or false), tostring(UnitHealthPercent ~= nil), tostring(UnitHealthMissing ~= nil)))
    say(string.format("anchor: shown=%s scale=%s point=%s %s %s,%s groups=%s x%s labels=%s sort=%s hideEmpty=%s",
        tostring(RF.anchor:IsShown()), tostring(c.scale), tostring(c.point.point), tostring(c.point.relativePoint),
        tostring(c.point.x), tostring(c.point.y), tostring(c.groupArrange), tostring(c.groupsPerLine),
        tostring(c.groupLabels), tostring(c.sortWithin), tostring(c.hideEmptyGroups)))
    local shown = 0
    for i, button in ipairs(RF.buttons) do
        if button:IsShown() then shown = shown + 1 end
        local cell = RF.plan and RF.plan.byButton[i]
        if button:IsShown() or i <= 5 then
            say(string.format("  #%d unit=%s shown=%s watched=%s group=%s cell=%s,%s range=%s state=%s aggro=%s text=%s",
                i, tostring(button:GetAttribute("unit")), tostring(button:IsShown()), tostring(button.watched or false),
                tostring(button.raidGroup), tostring(cell and cell.x), tostring(cell and cell.y),
                tostring(button.rangeState), tostring(button.state), tostring(button.aggro or false),
                tostring(button.textKey)))
        end
    end
    say("shown buttons: " .. shown .. " / " .. #RF.buttons)
    local b, d = c.buffs, c.debuffs
    local dirty, markers, containers, glows = 0, 0, 0, 0
    for _, button in ipairs(RF.buttons) do
        if RF.buffDirty[button] then dirty = dirty + 1 end
        if (button.markerCount or 0) > 0 then markers = markers + 1 end
        if button.debuffContainer then containers = containers + 1 end
        if button.glowContainer then glows = glows + 1 end
    end
    say(string.format("my buffs: show=%s multi=%s ending=%s look=%s rebuff=%s%% inCombat=%s | dirty=%d bars with markers=%d last tick=%s missing=%d",
        tostring(b.show), tostring(b.multi), tostring(b.showEnding), tostring(b.endingLook), tostring(b.rebuffPercent),
        tostring(b.inCombat), dirty, markers, tostring(RF.lastBuffTick), RF:MissingCount()))
    say(string.format("debuffs: show=%s display=%s (in use: %s) max=%s size=%s | icon containers=%d glow containers=%d /%d glowSupported=%s%s",
        tostring(d.show), tostring(d.display), tostring(RF:DebuffMode()), tostring(d.max), tostring(d.size), containers,
        glows, #RF.buttons, tostring(RF.glowSupported), RF.glowError and (" (" .. RF.glowError .. ")") or ""))
    say(string.format("visibility drivers: raid=%s party=%s", tostring(RF.softDriver or false),
        tostring(UF().softSuspended or false)))
    local aliases = {}
    for a, button in pairs(RF.alias) do aliases[#aliases + 1] = a .. "->" .. tostring(button.unit) end
    table.sort(aliases)
    say("alias: " .. (#aliases > 0 and table.concat(aliases, ", ") or "none"))
end

-- Events -----------------------------------------------------------------------------------------------------------

local function route(updateFn)
    return function(_, unit)
        local button = RF:ButtonFor(unit)
        if button and button:IsShown() then updateFn(RF, button) end
    end
end

local function evaluate()
    if RF.anchor then RF:Evaluate() end
end

local function requestEvaluate()
    if RF.anchor then RF:RequestEvaluate() end
end

function RF:Init()
    ns:On("FRAMES_CREATED", function() RF:Create() end)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", evaluate)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", evaluate)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", requestEvaluate)
    ns:RegisterEvent("UNIT_HEALTH", route(RF.UpdateHealth))
    ns:RegisterEvent("UNIT_MAXHEALTH", route(RF.UpdateHealth))
    ns:RegisterEvent("UNIT_NAME_UPDATE", route(RF.UpdateName))
    ns:RegisterEvent("UNIT_CONNECTION", route(RF.UpdateState))
    ns:RegisterEvent("UNIT_FLAGS", route(RF.UpdateState))
    ns:RegisterEvent("UNIT_IN_RANGE_UPDATE", route(RF.UpdateRange))
    ns:RegisterEvent("UNIT_HEAL_PREDICTION", route(RF.UpdatePrediction))
    ns:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE", function(_, unit)
        if RF.active ~= "raid" then return end
        if unit then
            local button = RF:ButtonFor(unit)
            if button and button:IsShown() then RF:UpdateThreat(button) end
        else
            for _, button in ipairs(RF.buttons) do
                if button:IsShown() then RF:UpdateThreat(button) end
            end
        end
    end)
    ns:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        if RF.active ~= "raid" then return end
        for _, button in ipairs(RF.buttons) do
            if button:IsShown() then RF:UpdateTarget(button) end
        end
    end)
    ns:RegisterEvent("MODIFIER_STATE_CHANGED", function()
        if RF.hovered and RF.active == "raid" then UF():ShowTooltip(RF.hovered) end
    end)
    ns:On("LOCK_CHANGED", function() RF:ApplyLock() end)
    -- my buffs: aura changes are only read out of combat; combat start hides / dims, combat end re-checks everyone
    ns:RegisterEvent("UNIT_AURA", function(_, unit)
        if RF.active ~= "raid" or ns.InCombat() then return end
        local button = RF:ButtonFor(unit)
        if button then RF.buffDirty[button] = true end
    end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if RF.anchor then RF:RenderAllBuffMarkers() end
    end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if not RF.anchor then return end
        RF:MarkAllBuffsDirty()
        RF:RenderAllBuffMarkers()
        if RF.active == "raid" then
            for _, button in ipairs(RF.buttons) do
                RS.PlaceDebuffZone(button)
                RF:UpdateDebuffUnit(button)
            end
        end
    end)
    ns:RegisterEvent("SPELLS_CHANGED", function() RF:MarkAllBuffsDirty() end)
    ns:RegisterEvent("PLAYER_ROLES_ASSIGNED", function() RF:MarkAllBuffsDirty() end)
    ns:On("CONFIG_CHANGED", function(group)
        if not RF.anchor then return end
        -- presets, buff or raid options: every marker is re-checked on the next tick (out of combat)
        RF:MarkAllBuffsDirty()
        if group == "raid" or group == "all" then
            RF:RenderAllBuffMarkers()
            for _, button in ipairs(RF.buttons) do RF:StyleDebuffs(button) end
        end
        if group == "raid" or group == "all" then
            RF:RequestEvaluate()   -- switches, or re-lays out the active raid layout (coalesced; queued in combat)
        elseif group == "roles" then
            if RF.active == "raid" and cfg().sortWithin == "role" then RF:Layout() end
        elseif group == "frames" then
            RF:ApplyLock()
        end
    end)
end

RF:Init()
