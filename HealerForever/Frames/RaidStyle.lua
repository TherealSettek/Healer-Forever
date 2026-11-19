local ADDON_NAME, ns = ...

-- Raid bar look (style D "Hurt stands out", mockup/raid-style-d.html), shared by the real secure raid buttons
-- (Frames/RaidFrames.lua) and the preview frames (Phase 4), so both look identical.
--   RS.Build(frame)               creates every region once (never per update)
--   RS.Apply(frame, cfg)          sizes them and places the texts (RaidLayout.TextLayout); out of combat on secure buttons
--   RS.SetBuffReserve(frame, n)   top-right room for n buff markers (Phase 3); re-places the texts when it changes
--   painters (no unit API, safe in combat, accept secret values where noted):
--     RS.ShowState, RS.ShowNumber, RS.SetNameColor, RS.SetTarget (secret ok), RS.SetAggro, RS.SetRange (secret ok),
--     RS.SetBarColor, RS.SetBarMuted
--   my buffs / debuffs (Phase 3, plain data, shared with the preview):
--     RS.SetBuffMarkers(frame, markers, look, dim)  top-right spell icons (gold = missing, orange = ending)
--     RS.PlaceDebuffZone(frame)                      bottom-right debuff zone (out of combat)
--     RS.SetFakeDebuffs(frame, types, showIcons)     preview-only debuff icons (the real ones are game-drawn)
--     RS.SetGlowColor(frame, color)                  preview-only bar glow (the real one is tinted by the game)
--   RS.Render(frame, data, cfg)   draws a plain data table (preview / tests): no unit tokens, no unit APIs
--   curves: RS.MuteCurve(key, r, g, b), RS.PercentColorCurve() (Step colour curves) and RS.HurtAlphaCurve() (Step float
--           curve) for UnitHealthPercent; nil when the client lacks them
local RS = {}
ns.RaidStyle = RS

local floor, max = math.floor, math.max
local issecret = ns.issecret

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local INSET = 1

RS.BAR_TEXTURE = BAR_TEXTURE
RS.INSET = INSET
RS.MAX_MARKERS = 3
RS.GLOW_OUTSET = 2
-- Frame levels above the bar frame: glow 3 (real glow holder = text - 1 = 4), texts 5, buff markers / debuff icons 6.
RS.GLOW_LEVEL = 3
RS.TEXT_LEVEL = 5
-- Representative spell per dispel type for the preview debuff icons (texture only; question mark if unknown).
RS.FAKE_DEBUFF_SPELL = { Magic = 118, Poison = 2818, Disease = 3427, Curse = 980 }
RS.FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
-- Step curves switch to their "full health" point at this fraction, a little below 1.0: a full bar can report
-- 0.99999 (rounding), which must still count as full (muted bar, hidden deficit).
RS.FULL_AT = 0.995
RS.DIM_ALPHA = 0.45
-- Preview glow: the classic debuff border art, tinted (the real glow's art is chosen by the game: unverified look).
RS.GLOW_TEXTURE = "Interface\\Buttons\\UI-Debuff-Overlays"
RS.GLOW_COORDS = { 0.296875, 0.5703125, 0, 0.515625 }

-- Colours (mockup values) ------------------------------------------------------------------------------------------
RS.COLORS = {
    deficit = { 1, 0.16, 0.16 },          -- #ff2a2a missing HP
    buffMissing = { 1, 0.82, 0 },         -- gold border: my buff is missing
    buffEnding = { 1, 0.54, 0.1 },        -- orange border: my buff is under the rebuff %
    percentHurt = { 1, 0.29, 0.29 },      -- #ff4a4a
    percentFull = { 0.85, 0.85, 0.85 },   -- #d8d8d8
    dead = { 0.88, 0.25, 0.25 },          -- #e04040 DEAD / CAN'T RES
    ghost = { 0.66, 0.72, 0.82 },         -- #a8b8d0
    offline = { 0.67, 0.67, 0.67 },       -- #aaa
    hidden = { 0.54, 0.65, 0.78 },        -- #8aa6c8 "?"
    name = { 0.78, 0.78, 0.78 },          -- #c8c8c8
    nameMe = { 0.91, 0.75, 0.31 },        -- #e8c050 own name (gold)
    nameDim = { 0.54, 0.54, 0.54 },       -- #8a8a8a dead / not visible
    grey = { 0.33, 0.33, 0.33 },          -- #555 dead / ghost / offline / not visible bar
    target = { 1, 1, 1 },
    aggro = { 1, 0.13, 0.13 },            -- #ff2020
    outOfRange = { r = 0.6, g = 0.6, b = 0.6 },      -- #9a9a9a dashed
    notVisible = { r = 0.42, g = 0.53, b = 0.66 },   -- #6a86a8 dotted
    incoming = { 0.49, 1, 0.61, 0.44 },              -- #7dff9b70
}
local C = RS.COLORS

-- Muted = class colour 38% + #2a2a2a 62% (CSS color-mix in the mockup).
RS.MUTE_MIX = 0.38
RS.MUTE_BASE = 42 / 255

function RS.Muted(r, g, b)
    local k, base = RS.MUTE_MIX, RS.MUTE_BASE * (1 - RS.MUTE_MIX)
    return r * k + base, g * k + base, b * k + base
end

-- State texts in the centre
RS.STATE_TEXT = { dead = "DEAD", ghost = "GHOST", offline = "OFFLINE", cantres = "CAN'T RES", hidden = "?" }
local STATE_COLOR = { dead = C.dead, cantres = C.dead, ghost = C.ghost, offline = C.offline, hidden = C.hidden }

-- Characters the TextLayout assumes for the health number ("-1.8k" / "-12k"; "100%").
RS.NUMBER_LEN = { deficit = 5, percent = 4, none = 0 }

-- Curves ------------------------------------------------------------------------------------------------------------
-- Step curves: x below RS.FULL_AT takes the point at 0, x >= RS.FULL_AT (full health) takes the second point. Only
-- successes are cached, so a client without the API simply gets nil every time (callers fall back).
local curves = {}

local function curvesSupported()
    return C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor and Enum and Enum.LuaCurveType
        and Enum.LuaCurveType.Step ~= nil
end

local function stepColorCurve(key, c0, c1)
    local cached = curves[key]
    if cached then return cached end
    if not curvesSupported() then return nil end
    local ok, curve = pcall(function()
        local c = C_CurveUtil.CreateColorCurve()
        c:SetType(Enum.LuaCurveType.Step)
        c:AddPoint(0, CreateColor(c0[1], c0[2], c0[3], c0[4] or 1))
        c:AddPoint(RS.FULL_AT, CreateColor(c1[1], c1[2], c1[3], c1[4] or 1))
        return c
    end)
    if ok and curve then
        curves[key] = curve
        return curve
    end
    return nil
end

-- Plain number Step curve (C_CurveUtil.CreateCurve): `below` under RS.FULL_AT, `full` from there on.
local function floatCurvesSupported()
    return C_CurveUtil and C_CurveUtil.CreateCurve and Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step ~= nil
end

local function stepFloatCurve(key, below, full)
    local cached = curves[key]
    if cached then return cached end
    if not floatCurvesSupported() then return nil end
    local ok, curve = pcall(function()
        local c = C_CurveUtil.CreateCurve()
        c:SetType(Enum.LuaCurveType.Step)
        c:AddPoint(0, below)
        c:AddPoint(RS.FULL_AT, full)
        return c
    end)
    if ok and curve then
        curves[key] = curve
        return curve
    end
    return nil
end

-- Per class: hurt (x < FULL_AT) = full class colour, full health = muted.
function RS.MuteCurve(key, r, g, b)
    local mr, mg, mb = RS.Muted(r, g, b)
    return stepColorCurve("mute:" .. tostring(key), { r, g, b, 1 }, { mr, mg, mb, 1 })
end

-- Deficit text alpha: 1 while hurt, 0 at full health. UnitHealthPercent(unit, false, curve) -> FontString:SetAlpha
-- ("only when hurt" without a truth test; the text colour stays constant).
function RS.HurtAlphaCurve()
    return stepFloatCurve("hurtAlpha", 1, 0)
end

-- Percent text colour: red while hurt, light grey at full health.
function RS.PercentColorCurve()
    return stepColorCurve("percent", C.percentHurt, C.percentFull)
end

function RS.ResetCurves() curves = {} end
function RS.CurvesSupported() return curvesSupported() end

-- Build -------------------------------------------------------------------------------------------------------------

-- 1 px outline made of four WHITE8X8 edges on its own plain frame (so the whole outline can take SetAlphaFromBoolean).
local function makeOutline(frame, level, outset, color)
    local o = ns.NewFrame("Frame", nil, frame)
    o:SetPoint("TOPLEFT", frame, "TOPLEFT", -outset, outset)
    o:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", outset, -outset)
    o:SetFrameLevel(frame:GetFrameLevel() + level)
    o:EnableMouse(false)
    local function edge(p1, p2, horizontal)
        local t = o:CreateTexture(nil, "OVERLAY")
        t:SetTexture(WHITE)
        t:SetVertexColor(color[1], color[2], color[3], 1)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if horizontal then t:SetHeight(1) else t:SetWidth(1) end
        return t
    end
    o.edges = { edge("TOPLEFT", "TOPRIGHT", true), edge("BOTTOMLEFT", "BOTTOMRIGHT", true),
        edge("TOPLEFT", "BOTTOMLEFT", false), edge("TOPRIGHT", "BOTTOMRIGHT", false) }
    o:Hide()
    return o
end

function RS.Build(frame)
    if frame.hfRaidBuilt then return frame end
    frame.hfRaidBuilt = true

    -- 1 px dark frame behind the bar (border look)
    frame.frameBG = frame:CreateTexture(nil, "BACKGROUND")
    frame.frameBG:SetAllPoints()
    frame.frameBG:SetTexture(WHITE)
    frame.frameBG:SetVertexColor(0, 0, 0, 1)

    -- health bar: explicit size (RS.Apply) so the dashes can measure it before the first layout pass
    local health = ns.NewFrame("StatusBar", nil, frame)
    health:SetStatusBarTexture(BAR_TEXTURE)
    health:SetMinMaxValues(0, 1)
    health:SetValue(1)
    health:SetPoint("TOPLEFT", frame, "TOPLEFT", INSET, -INSET)
    if health.SetClipsChildren then health:SetClipsChildren(true) end
    frame.health = health
    frame.healthBG = health:CreateTexture(nil, "BACKGROUND")
    frame.healthBG:SetAllPoints()
    frame.healthBG:SetTexture(WHITE)
    frame.healthBG:SetVertexColor(0.16, 0.05, 0.05, 1)

    -- incoming heals: a bar starting at the end of the health fill (clipped by the health bar), no text
    local pred = ns.NewFrame("StatusBar", nil, health)
    pred:SetStatusBarTexture(WHITE)
    pred:SetStatusBarColor(C.incoming[1], C.incoming[2], C.incoming[3], C.incoming[4])
    pred:SetMinMaxValues(0, 1)
    pred:SetValue(0)
    pred:SetFrameLevel(health:GetFrameLevel() + 1)
    pred:SetPoint("TOPLEFT", health:GetStatusBarTexture(), "TOPRIGHT")
    pred:SetPoint("BOTTOMLEFT", health:GetStatusBarTexture(), "BOTTOMRIGHT")
    pred:Hide()
    frame.pred = pred

    -- texts: NOT a child of the health bar. A clipping frame's children did not draw above the bar glow (frame + 3)
    -- in game: the glow's left edge hid the first letter of the name and the number's minus. Own level above the
    -- glow (holder = text - 1), under the buff markers and debuff icons (frame + 6); clips its own text to the bar.
    local text = ns.NewFrame("Frame", nil, frame)
    text:SetAllPoints(health)
    text:SetFrameLevel(frame:GetFrameLevel() + RS.TEXT_LEVEL)
    if text.SetClipsChildren then text:SetClipsChildren(true) end
    frame.textFrame = text
    frame.name = text:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.name:SetJustifyH("LEFT")
    frame.name:SetWordWrap(false)
    frame.name:SetTextColor(C.name[1], C.name[2], C.name[3])
    -- the centre text is never given a width: it always shows whole (the name gives way instead)
    frame.centerText = text:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.centerText:SetJustifyH("CENTER")
    frame.centerText:SetWordWrap(false)
    frame.centerText:SetTextColor(C.deficit[1], C.deficit[2], C.deficit[3])

    -- outlines: red aggro on the 1 px border, white target 1 px outside it (drawn over the aggro edge)
    frame.aggroFrame = makeOutline(frame, 12, 0, C.aggro)
    frame.targetFrame = makeOutline(frame, 13, 1, C.target)

    -- dashed (out of range) / dotted (not visible) outline, drawn by UnitFrames.LayoutDashes
    frame.dashFrame = ns.NewFrame("Frame", nil, frame)
    frame.dashFrame:SetAllPoints(frame)
    frame.dashFrame:SetFrameLevel(frame:GetFrameLevel() + 14)
    frame.dashFrame:EnableMouse(false)
    frame.dashFrame:Hide()

    RS.BuildMarkers(frame)
    return frame
end

-- My buff markers, debuff zone and bar glow. Created once at Build (out of combat); every frame gets EnableMouse(false)
-- here and never again: the markers are not clickable and never take the mouse from the secure button underneath.
local function buildSlot(frame, i)
    local slot = ns.NewFrame("Frame", nil, frame)
    slot:SetFrameLevel(frame:GetFrameLevel() + 6)
    slot:EnableMouse(false)
    slot:SetSize(10, 10)
    slot.border = slot:CreateTexture(nil, "BACKGROUND")
    slot.border:SetAllPoints()
    slot.border:SetTexture(WHITE)
    slot.border:SetVertexColor(C.buffMissing[1], C.buffMissing[2], C.buffMissing[3], 1)
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetPoint("TOPLEFT", 1, -1)
    slot.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    slot.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    -- clock sweep across the ending window (endingLook "sweep"): the game animates it, no OnUpdate of ours
    local cd = ns.NewFrame("Cooldown", nil, slot, "CooldownFrameTemplate")
    cd:SetPoint("TOPLEFT", 1, -1)
    cd:SetPoint("BOTTOMRIGHT", -1, 1)
    cd:EnableMouse(false)
    if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
    if cd.SetDrawEdge then cd:SetDrawEdge(false) end
    cd:Hide()
    slot.cd = cd
    -- count badge ("2"): several buffs in this state
    slot.countBG = slot:CreateTexture(nil, "OVERLAY")
    slot.countBG:SetTexture(WHITE)
    slot.countBG:SetVertexColor(0, 0, 0, 0.85)
    slot.count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    slot.count:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", 1, -1)
    slot.count:SetText("")
    slot.countBG:SetPoint("TOPLEFT", slot.count, "TOPLEFT", -1, 1)
    slot.countBG:SetPoint("BOTTOMRIGHT", slot.count, "BOTTOMRIGHT", 1, -1)
    slot.countBG:Hide()
    -- pulse (endingLook "pulse"): fades out and in once a second; Play/Stop only when the state changes
    slot.pulse = slot:CreateAnimationGroup()
    slot.pulse:SetLooping("BOUNCE")
    local anim = slot.pulse:CreateAnimation("Alpha")
    anim:SetFromAlpha(1)
    anim:SetToAlpha(0.35)
    anim:SetDuration(0.5)
    slot.pulsing = false
    slot.index = i
    slot:Hide()
    return slot
end

function RS.BuildMarkers(frame)
    if frame.buffSlots then return end
    frame.buffSlots = {}
    for i = 1, RS.MAX_MARKERS do frame.buffSlots[i] = buildSlot(frame, i) end

    -- bottom-right zone for the debuff icons (real bars: the game's aura container; preview: plain textures)
    local zone = ns.NewFrame("Frame", nil, frame)
    zone:SetFrameLevel(frame:GetFrameLevel() + 6)
    zone:EnableMouse(false)
    zone:SetSize(1, 1)
    zone:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    frame.debuffZone = zone

    -- bar glow in the colour of the first dispellable debuff. Real bars: handed to the game's aura button 1 through
    -- AddDispelTypeTexture, which tints and shows it (no secret debuff type in our code). Above the bar, below the text.
    -- glowFrame is the bar rect plus the outset (RS.GlowOutset); the real bars anchor their game-tinted glow to it.
    local glowFrame = ns.NewFrame("Frame", nil, frame)
    glowFrame:SetFrameLevel(frame:GetFrameLevel() + RS.GLOW_LEVEL)
    glowFrame:EnableMouse(false)
    frame.glowFrame = glowFrame
    RS.PlaceGlow(frame, RS.GLOW_OUTSET)
    local glow = glowFrame:CreateTexture(nil, "OVERLAY")
    glow:SetAllPoints(glowFrame)
    frame.dispelGlow = glow
end

-- Glow outset: at most RS.GLOW_OUTSET, and never more than half the bar spacing, so neighbouring glows never overlap
-- (spacing 2 -> 1 px each side).
function RS.GlowOutset(cfg)
    local sp = cfg and type(cfg.spacing) == "number" and cfg.spacing or RS.GLOW_OUTSET * 2
    return math.max(0, math.min(RS.GLOW_OUTSET, floor(sp / 2)))
end

function RS.PlaceGlow(frame, outset)
    local g = frame.glowFrame
    if not g or frame.glowOutset == outset then return end
    frame.glowOutset = outset
    g:ClearAllPoints()
    g:SetPoint("TOPLEFT", frame, "TOPLEFT", -outset, outset)
    g:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", outset, -outset)
end

-- Font size change that keeps the template's font file (a FontString without a font is left alone).
local function setFontSize(fs, size, flags)
    local ok, path, _, current = pcall(fs.GetFont, fs)
    if ok and type(path) == "string" and path ~= "" then
        pcall(fs.SetFont, fs, path, size, flags or current)
    end
end

-- "Name length" (raid.nameLength, in characters) caps the name width. Names can be secret, so they are never cut with
-- string functions: the FontString just gets this width (about 0.6 x font size per character) and the game cuts it.
function RS.NameWidthCap(cfg)
    local n, size = cfg and cfg.nameLength, cfg and cfg.nameSize
    if type(n) ~= "number" or type(size) ~= "number" then return nil end
    return math.ceil(n * size * 0.6)
end

-- Text placement ------------------------------------------------------------------------------------------------------
-- kind "num" = the health number (big, bold, outlined), "state" = DEAD / GHOST / OFFLINE / CAN'T RES / "?",
-- "none" = no centre text. len = characters the layout must fit. Re-anchors only when (kind, len) changes.
function RS.PlaceText(frame, kind, len)
    local cfg = frame.hfCfg
    if not cfg then return nil end
    local key = kind .. ":" .. len
    if frame.textKey == key then return frame.textLayout end
    local layout = ns.RaidLayout.TextLayout(cfg, frame.reserveRight or 0,
        { len = len, big = kind == "num", buffW = frame.reserveBuffW or 0 })
    frame.textKey, frame.textLayout = key, layout
    local fs, name = frame.centerText, frame.name
    setFontSize(fs, layout.tfs, "OUTLINE")
    fs:ClearAllPoints()
    -- Placed from TextLayout's numLeft (never left of the bar's inner edge), not from the free area: a text wider
    -- than the free area moves right (over the icons, last resort) instead of being clipped on the left. The text
    -- itself is never measured (it can be secret); numW is a generous estimate of its width.
    if layout.stacked then
        -- centred in the free area (left of the right-hand icons, below the name)
        fs:SetPoint("TOP", frame, "TOPLEFT", layout.numLeft + layout.numW / 2, -layout.top)
    else
        -- short bar: number centre-right, the name only to its left
        fs:SetPoint("TOPRIGHT", frame, "TOPLEFT", layout.numLeft + layout.numW, -layout.top)
    end
    setFontSize(name, cfg.nameSize)
    name:ClearAllPoints()
    if cfg.showNames and layout.nameW >= 6 then
        if layout.stacked then
            name:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -1)
        else
            name:SetPoint("TOPRIGHT", fs, "TOPLEFT", -3, 0)
        end
        local nameW = layout.nameW
        local cap = RS.NameWidthCap(cfg)
        if cap and cap < nameW then nameW = max(6, cap) end
        name:SetWidth(nameW)
        name:Show()
    else
        name:SetWidth(0)
        name:Hide()
    end
    return layout
end

-- Apply ---------------------------------------------------------------------------------------------------------------

-- Sizes the frame and its regions, computes the reserves and places the texts. Returns the TextLayout result for
-- the health number. SetSize on a secure button: out of combat only (RaidFrames:Layout).
function RS.Apply(frame, cfg)
    frame.hfCfg = cfg
    frame:SetSize(cfg.width, cfg.height)
    local bw, bh = max(1, cfg.width - 2 * INSET), max(1, cfg.height - 2 * INSET)
    frame.health:SetSize(bw, bh)
    frame.pred:SetSize(bw, bh)
    -- re-assert the stacking (glow < texts < icons): a later parent level change can raise children unevenly
    local lvl = frame:GetFrameLevel()
    frame.textFrame:SetFrameLevel(lvl + RS.TEXT_LEVEL)
    if frame.glowFrame then frame.glowFrame:SetFrameLevel(lvl + RS.GLOW_LEVEL) end
    if frame.glowHolder then frame.glowHolder:SetFrameLevel(lvl + RS.TEXT_LEVEL - 1) end
    local res = ns.RaidLayout.Reserves(cfg, frame.buffMarkers or 0, RS.DebuffMode(cfg))
    frame.reserves = res
    frame.reserveRight, frame.reserveBuffW = res.right, res.buffW
    frame.textKey = nil
    -- create the dash segments now (out of combat) so a range change in combat only re-uses them
    if not frame.hfDashesBuilt and ns.UnitFrames and ns.UnitFrames.LayoutDashes then
        ns.UnitFrames.LayoutDashes(frame, C.notVisible, 2, 3)
        frame.dashFrame:Hide()
        frame.hfDashesBuilt = true
    end
    frame.dashKey = nil
    frame.zoneKey = nil
    RS.PlaceGlow(frame, RS.GlowOutset(cfg))
    RS.PlaceDebuffZone(frame)
    local kind = frame.centerKind or "num"
    local layout = RS.PlaceText(frame, kind, frame.centerLen or (RS.NUMBER_LEN[cfg.healthText] or 5))
    if kind ~= "num" then
        -- the number layout is what callers measure (tests, preview)
        layout = ns.RaidLayout.TextLayout(cfg, res.right, { len = RS.NUMBER_LEN[cfg.healthText] or 5,
            big = cfg.healthText ~= "none", buffW = res.buffW })
    end
    return layout
end

-- Top-right room for n buff markers (Phase 3 calls this when the marker count changes; 0 = none).
function RS.SetBuffReserve(frame, n)
    n = n or 0
    if frame.buffMarkers == n then return end
    frame.buffMarkers = n
    local cfg = frame.hfCfg
    if not cfg then return end
    local res = ns.RaidLayout.Reserves(cfg, n, RS.DebuffMode(cfg))
    frame.reserves = res
    frame.reserveRight, frame.reserveBuffW = res.right, res.buffW
    frame.textKey = nil
    RS.PlaceText(frame, frame.centerKind or "num", frame.centerLen or 5)
    RS.PlaceDebuffZone(frame)
end

-- Debuff zone: bottom-right, max icons of reserves.isz px (1 px gaps); it moves left of the buff markers when both
-- can't share the bar height (reserves.shift). A plain frame on the secure button: moved out of combat only (a
-- pending move is applied by the next call after combat).
function RS.PlaceDebuffZone(frame)
    local res, cfg, zone = frame.reserves, frame.hfCfg, frame.debuffZone
    if not res or not cfg or not zone then return end
    local d = cfg.debuffs or {}
    local cnt = math.max(1, d.max or 1)
    local key = res.shift .. ":" .. res.isz .. ":" .. cnt
    if frame.zoneKey == key then return end
    if ns.InCombat and ns.InCombat() then return end
    frame.zoneKey = key
    zone:SetSize(cnt * (res.isz + 1) + 1, res.isz + 1)
    zone:ClearAllPoints()
    zone:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(1 + res.shift), 1)
end

-- My buff markers -------------------------------------------------------------------------------------------------
-- markers = list of { kind = "miss"|"end", icon, count, start, window } (plain values; nil/{} = none), top-right,
-- right to left. look = endingLook (pulse | sweep | border); dim = keep last known in combat (alpha 0.45, desaturated,
-- no pulse). The text reserve follows the number of icons.
local function setSlot(frame, slot, m, size, look, dim)
    local i = slot.index
    local posKey = size .. ":" .. i
    if slot.posKey ~= posKey then
        slot.posKey = posKey
        slot:SetSize(size, size)
        slot:ClearAllPoints()
        slot:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(1 + (i - 1) * (size + 1)), -1)
        setFontSize(slot.count, max(6, floor(size * 0.6 + 0.5)), "OUTLINE")
    end
    local ending = m.kind == "end"
    local c = ending and C.buffEnding or C.buffMissing
    slot.border:SetVertexColor(c[1], c[2], c[3], 1)
    slot.icon:SetTexture(m.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    slot.icon:SetDesaturated(dim and true or false)
    local count = type(m.count) == "number" and m.count or 1
    slot.count:SetText(count > 1 and tostring(count) or "")
    slot.countBG:SetShown(count > 1)
    local sweep = ending and look == "sweep" and type(m.window) == "number" and m.window > 0
        and type(m.start) == "number"
    if sweep then
        local cdKey = m.start .. ":" .. m.window
        if slot.cdKey ~= cdKey then
            slot.cdKey = cdKey
            slot.cd:SetCooldown(m.start, m.window)
        end
        slot.cd:Show()
    else
        slot.cdKey = nil
        slot.cd:Hide()
    end
    local pulse = ending and look == "pulse" and not dim
    if pulse ~= slot.pulsing then
        slot.pulsing = pulse
        if pulse then slot.pulse:Play() else slot.pulse:Stop() end
    end
    slot.kind = m.kind
    slot:SetAlpha(dim and RS.DIM_ALPHA or 1)
    slot:Show()
end

function RS.SetBuffMarkers(frame, markers, look, dim)
    if not frame.buffSlots then return end
    local n = 0
    if type(markers) == "table" then n = math.min(#markers, RS.MAX_MARKERS) end
    RS.SetBuffReserve(frame, n)
    local size = frame.reserves and frame.reserves.bsz or 10
    for i, slot in ipairs(frame.buffSlots) do
        if i <= n then
            setSlot(frame, slot, markers[i], size, look, dim)
        else
            if slot.pulsing then
                slot.pulsing = false
                slot.pulse:Stop()
            end
            slot.kind, slot.cdKey = nil, nil
            slot:Hide()
        end
    end
    frame.markerCount = n
end

-- Preview-only debuffs ---------------------------------------------------------------------------------------------
-- types = dispel type names ("Magic", ...), already limited to what the player's class can dispel and to debuffs.max.
-- Plain textures in the debuff zone with the dispel-colour border (real bars: the game draws them).
local function fakeIcon(frame, i)
    frame.fakeDebuffs = frame.fakeDebuffs or {}
    local icon = frame.fakeDebuffs[i]
    if icon then return icon end
    local zone = frame.debuffZone
    icon = { border = zone:CreateTexture(nil, "ARTWORK"), fill = zone:CreateTexture(nil, "OVERLAY") }
    icon.border:SetTexture(WHITE)
    icon.fill:SetTexture(RS.FALLBACK_ICON)
    icon.fill:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- cropped like the real aura icons
    icon.fill:SetPoint("TOPLEFT", icon.border, "TOPLEFT", 1, -1)
    icon.fill:SetPoint("BOTTOMRIGHT", icon.border, "BOTTOMRIGHT", -1, 1)
    frame.fakeDebuffs[i] = icon
    return icon
end

-- Spell icon for a preview debuff of dispel type t (C_Spell.GetSpellTexture of a representative spell; plain
-- spell IDs, never unit data). Falls back to the question mark.
local fakeIconCache = {}
function RS.FakeDebuffIcon(t)
    local cached = fakeIconCache[t]
    if cached then return cached end
    local tex = RS.FALLBACK_ICON
    local spell = RS.FAKE_DEBUFF_SPELL[t]
    if spell and C_Spell and C_Spell.GetSpellTexture then
        local ok, v = pcall(C_Spell.GetSpellTexture, spell)
        if ok and v ~= nil and not issecret(v) then
            tex = v
            fakeIconCache[t] = v   -- the question mark is not cached: spell data may load later
        end
    end
    return tex
end

function RS.SetFakeDebuffs(frame, types, showIcons)
    types = type(types) == "table" and types or {}
    local size = frame.reserves and frame.reserves.isz or 10
    local shown = 0
    if showIcons then
        for i, t in ipairs(types) do
            local col = ns.Classes and ns.Classes.DISPEL_COLORS and ns.Classes.DISPEL_COLORS[t]
            if col and i <= RS.MAX_MARKERS then
                local icon = fakeIcon(frame, i)
                icon.border:SetSize(size, size)
                icon.border:ClearAllPoints()
                icon.border:SetPoint("BOTTOMRIGHT", frame.debuffZone, "BOTTOMRIGHT", -((i - 1) * (size + 1)), 0)
                icon.border:SetVertexColor(col.r, col.g, col.b, 1)
                if icon.type ~= t then icon.fill:SetTexture(RS.FakeDebuffIcon(t)) end
                icon.fill:SetVertexColor(1, 1, 1, 1)
                icon.border:Show()
                icon.fill:Show()
                icon.type = t
                shown = i
            end
        end
    end
    for i, icon in ipairs(frame.fakeDebuffs or {}) do
        if i > shown then
            icon.border:Hide()
            icon.fill:Hide()
            icon.type = nil
        end
    end
    frame.fakeDebuffCount = shown
end

-- Preview-only glow: color = { r, g, b } or nil (off).
function RS.SetGlowColor(frame, color)
    local glow = frame.dispelGlow
    if not glow then return end
    if not color then
        glow:Hide()
        frame.glowColor = nil
        return
    end
    glow:SetTexture(RS.GLOW_TEXTURE)
    glow:SetTexCoord(RS.GLOW_COORDS[1], RS.GLOW_COORDS[2], RS.GLOW_COORDS[3], RS.GLOW_COORDS[4])
    glow:SetVertexColor(color.r, color.g, color.b, 1)
    glow:SetAlpha(1)
    glow:Show()
    frame.glowColor = color
end

-- Debuff display after the glow fallback: a client where the glow can't be handed to the game shows icons instead.
-- Every user of the display setting (reserves, styling, preview, options) goes through this.
function RS.DebuffMode(cfg)
    local mode = cfg and cfg.debuffs and cfg.debuffs.display or "glowIcons"
    local RF = ns.RaidFrames
    if RF and RF.glowSupported == false and mode ~= "icons" then return "icons" end
    return mode
end

-- Painters ------------------------------------------------------------------------------------------------------------

-- Centre text for a state: kind = dead | ghost | offline | cantres | hidden.
function RS.ShowState(frame, kind)
    local text = RS.STATE_TEXT[kind] or ""
    frame.centerKind, frame.centerLen = "state", #text
    RS.PlaceText(frame, "state", #text)
    local c = STATE_COLOR[kind] or C.offline
    frame.centerText:SetText(text)
    frame.centerText:SetTextColor(c[1], c[2], c[3], 1)
    frame.centerText:SetAlpha(1)
end

-- Prepares the centre text for the health number (mode = deficit | percent | none). The caller sets the text, colour
-- and (deficit) alpha; they can be secret. The alpha is reset to 1 here. Returns the FontString.
function RS.ShowNumber(frame, mode)
    local len = RS.NUMBER_LEN[mode] or 5
    frame.centerText:SetAlpha(1)
    if mode == "none" then
        frame.centerKind, frame.centerLen = "none", 0
        RS.PlaceText(frame, "none", 0)
        frame.centerText:SetText("")
    else
        frame.centerKind, frame.centerLen = "num", len
        RS.PlaceText(frame, "num", len)
    end
    return frame.centerText
end

-- look = "me" | "dim" | nil
function RS.SetNameColor(frame, look)
    local c = look == "me" and C.nameMe or look == "dim" and C.nameDim or C.name
    frame.name:SetTextColor(c[1], c[2], c[3])
end

-- Target outline. value may be secret: then the outline is shown and its alpha follows the boolean.
function RS.SetTarget(frame, value)
    local o = frame.targetFrame
    if issecret(value) then
        o:Show()
        if o.SetAlphaFromBoolean then
            if not pcall(o.SetAlphaFromBoolean, o, value, 1, 0) then o:Hide() end
        else
            o:Hide()
        end
        return
    end
    o:SetAlpha(1)
    o:SetShown(value and true or false)
end

function RS.SetAggro(frame, on)
    frame.aggroFrame:SetShown(on and true or false)
end

function RS.SetBarColor(frame, r, g, b)
    frame.health:SetStatusBarColor(r, g, b)
end

-- Readable muting: full colour, or the muted tint when muted is true.
function RS.SetBarMuted(frame, r, g, b, muted)
    if muted then r, g, b = RS.Muted(r, g, b) end
    frame.health:SetStatusBarColor(r, g, b)
end

-- Range look. mode = in | out | hidden | offline | secret; alpha = the out-of-range alpha (0..1).
-- secret: the in-range answer is a secret boolean; the button alpha and the dashed outline follow it through
-- SetAlphaFromBoolean (no truth test). The dash segments are only re-laid out when the look changes.
function RS.SetRange(frame, mode, alpha, secretValue)
    local dashKey
    if mode == "out" or mode == "secret" then dashKey = "out" elseif mode == "hidden" then dashKey = "hidden" end
    if dashKey ~= frame.dashKey then
        frame.dashKey = dashKey
        local UF = ns.UnitFrames
        if dashKey == "out" and UF and UF.LayoutDashes then
            UF.LayoutDashes(frame, C.outOfRange, 4, 3)
        elseif dashKey == "hidden" and UF and UF.LayoutDashes then
            UF.LayoutDashes(frame, C.notVisible, 2, 3)
        else
            frame.dashFrame:Hide()
        end
    end
    local dash = frame.dashFrame
    if mode == "secret" then
        local ok = frame.SetAlphaFromBoolean and pcall(frame.SetAlphaFromBoolean, frame, secretValue, 1, alpha)
        if not ok then frame:SetAlpha(1) end
        ok = dash.SetAlphaFromBoolean and pcall(dash.SetAlphaFromBoolean, dash, secretValue, 0, 1)
        if not ok then dash:Hide() end
        return
    end
    dash:SetAlpha(1)
    if mode == "out" or mode == "hidden" or mode == "offline" then
        frame:SetAlpha(alpha)
    else
        frame:SetAlpha(1)
    end
end

-- Render: plain data (preview / tests) --------------------------------------------------------------------------------
-- data = { name, class (token), me, hp, maxHp, incoming, state = alive|dead|ghost|offline, range = in|out|hidden,
--          target, aggro, combat,
--          buffs = { { kind = "miss"|"end", icon, count, start, window } ... } (RaidLayout.BuffMarkers order),
--          debuffs = { "Magic", "Poison", ... } (types the player can dispel, first = glow colour),
--          buffMarkers = n (reserve only, when no buffs list is given) }.
-- Every value is a plain readable Lua value. Call RS.Apply when cfg changes.
local function abbreviate(n)
    if n >= 10000 then return string.format("%dk", floor(n / 1000 + 0.5)) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(floor(n + 0.5))
end
RS.Abbreviate = abbreviate

function RS.Render(frame, data, cfg)
    RS.Build(frame)
    if frame.hfCfg ~= cfg or not frame.textLayout then RS.Apply(frame, cfg) end
    data = data or {}
    local state = data.state or "alive"
    local range = data.range or "in"
    local down = state ~= "alive"

    -- my buffs: hidden while down / not visible; in combat hidden or dimmed (raid.buffs.inCombat)
    local bc, d = cfg.buffs or {}, cfg.debuffs or {}
    if type(data.buffs) == "table" then
        local markers, dim = data.buffs, false
        if down or range == "hidden" or bc.show == false then markers = nil end
        if data.combat then
            if bc.inCombat == "dim" then dim = true else markers = nil end
        end
        RS.SetBuffMarkers(frame, markers, bc.endingLook, dim)
    else
        RS.SetBuffMarkers(frame, nil)
        RS.SetBuffReserve(frame, data.buffMarkers or 0)
    end

    -- dispellable debuffs: icons bottom-right and/or the bar glow in the first type's colour
    local types = {}
    if d.show ~= false and not down and range ~= "hidden" and type(data.debuffs) == "table" then
        for i, t in ipairs(data.debuffs) do
            if i <= (d.max or 3) then types[#types + 1] = t end
        end
    end
    local mode = RS.DebuffMode(cfg)
    RS.SetFakeDebuffs(frame, types, mode ~= "glow")
    local first = types[1] and ns.Classes and ns.Classes.DISPEL_COLORS and ns.Classes.DISPEL_COLORS[types[1]]
    RS.SetGlowColor(frame, (mode ~= "icons" and first) or nil)
    local maxHp = type(data.maxHp) == "number" and data.maxHp > 0 and data.maxHp or 1
    local hp = type(data.hp) == "number" and math.min(max(data.hp, 0), maxHp) or maxHp
    local bar = frame.health

    -- bar
    if state == "dead" or state == "ghost" then
        bar:SetMinMaxValues(0, 1); bar:SetValue(0)
    elseif state == "offline" then
        bar:SetMinMaxValues(0, 1); bar:SetValue(1)
    else
        bar:SetMinMaxValues(0, maxHp); bar:SetValue(hp)
    end
    if down or range == "hidden" then
        RS.SetBarColor(frame, C.grey[1], C.grey[2], C.grey[3])
    else
        local col = ns.Classes and ns.Classes.GetColor and data.class and ns.Classes.GetColor(data.class)
        local r, g, b = 1, 1, 1
        if col then r, g, b = col.r, col.g, col.b end
        RS.SetBarMuted(frame, r, g, b, cfg.muteFull and hp >= maxHp)
    end

    -- incoming heals
    local inc = type(data.incoming) == "number" and data.incoming or 0
    if cfg.showIncoming and not down and range ~= "hidden" and inc > 0 then
        frame.pred:SetMinMaxValues(0, maxHp)
        frame.pred:SetValue(inc)
        frame.pred:Show()
    else
        frame.pred:Hide()
    end

    -- centre text
    if state == "dead" then
        RS.ShowState(frame, (range == "out" or range == "hidden") and "cantres" or "dead")
    elseif down then
        RS.ShowState(frame, state)
    elseif range == "hidden" then
        RS.ShowState(frame, "hidden")
    else
        local fs = RS.ShowNumber(frame, cfg.healthText)
        if cfg.healthText == "deficit" then
            local missing = maxHp - hp
            if missing > 0 then fs:SetText("-" .. abbreviate(missing)) else fs:SetText("") end
            fs:SetTextColor(C.deficit[1], C.deficit[2], C.deficit[3], 1)
        elseif cfg.healthText == "percent" then
            fs:SetText(floor(hp / maxHp * 100 + 0.5) .. "%")
            local c = hp < maxHp and C.percentHurt or C.percentFull
            fs:SetTextColor(c[1], c[2], c[3], 1)
        end
    end

    -- name
    frame.name:SetText(data.name or "")
    RS.SetNameColor(frame, data.me and "me" or ((down or range == "hidden") and "dim" or nil))

    -- outlines and range
    RS.SetTarget(frame, data.target and true or false)
    RS.SetAggro(frame, data.aggro and not down)
    RS.SetRange(frame, state == "offline" and "offline" or range, (cfg.rangeAlpha or 50) / 100)
end
