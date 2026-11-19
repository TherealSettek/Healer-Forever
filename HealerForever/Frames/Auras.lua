local ADDON_NAME, ns = ...

-- Aura icons for the unit frames. Secret-safe: in combat auraInstanceIDs are the only values we
-- inspect; textures, stacks, dispel colors and timers are piped into widgets and Cooldown frames.
local Auras = {}
ns.Auras = Auras

local issecret = ns.issecret
local GetTime = GetTime

local WHITE = "Interface\\Buttons\\WHITE8X8"
local TIMER_INTERVAL = 0.1
local DEFAULT_DEBUFF_COLOR = { r = 0.8, g = 0, b = 0 }

local liveIcons = {}
local timerFrame
local dispelCurve
local dispelCurveTried = false

local function getDispelCurve()
    if dispelCurveTried then return dispelCurve end
    dispelCurveTried = true
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor and Enum and Enum.SpellDispelType) then
        return nil
    end
    local ok, curve = pcall(function()
        local c = C_CurveUtil.CreateColorCurve()
        if Enum.LuaCurveType and c.SetType then c:SetType(Enum.LuaCurveType.Step) end
        local t = Enum.SpellDispelType
        local function add(enumValue, col)
            if enumValue then c:AddPoint(enumValue, CreateColor(col.r, col.g, col.b, 1)) end
        end
        add(t.None, DEFAULT_DEBUFF_COLOR)
        add(t.Magic, ns.Classes.DISPEL_COLORS.Magic)
        add(t.Curse, ns.Classes.DISPEL_COLORS.Curse)
        add(t.Disease, ns.Classes.DISPEL_COLORS.Disease)
        add(t.Poison, ns.Classes.DISPEL_COLORS.Poison)
        return c
    end)
    if ok then dispelCurve = curve end
    return dispelCurve
end

-- Pure (no WoW API) -------------------------------------------------------------------------------------

local PHYSICAL_COLOR = { r = 0.8, g = 0.2, b = 0.2 }
local BUFF_COLOR = { r = 0.9, g = 0.9, b = 0.9 }

-- auras: array of { name, icon, dispelName, applications, expirationTime, duration }
-- canDispelTypes: array or set of dispel type names the player can remove
-- opts.buff = true formats helpful auras (no type label)
-- returns sorted array of { text, r, g, b, dispellable }: dispellable first, then least time left first.
function Auras.BuildTooltipLines(auras, now, canDispelTypes, opts)
    local isBuff = opts and opts.buff
    local can = {}
    for k, v in pairs(canDispelTypes or {}) do
        if type(v) == "string" then can[v] = true elseif v == true and type(k) == "string" then can[k] = true end
    end
    local rows = {}
    for index, a in ipairs(auras or {}) do
        if type(a) == "table" and a.name then
            local dispelName = (a.dispelName ~= "" and a.dispelName) or nil
            local dispellable = (not isBuff) and dispelName ~= nil and can[dispelName] == true
            local remaining
            local exp = a.expirationTime
            if exp and exp > 0 and now then remaining = exp - now end
            local color = isBuff and BUFF_COLOR
                or (dispelName and ns.Classes.DISPEL_COLORS[dispelName]) or PHYSICAL_COLOR
            local text = (a.icon and ("|T" .. tostring(a.icon) .. ":14|t ") or "") .. a.name
            if not isBuff then text = text .. " - " .. (dispelName or "Physical") end
            if a.applications and a.applications > 1 then text = text .. " x" .. a.applications end
            if remaining and remaining > 0 then
                text = text .. " - " .. ns.Util.FormatAuraTime(remaining)
            end
            if dispellable then text = text .. " [dispel]" end
            rows[#rows + 1] = { text = text, r = color.r, g = color.g, b = color.b, dispellable = dispellable,
                remaining = (remaining and remaining > 0) and remaining or math.huge, index = index }
        end
    end
    table.sort(rows, function(x, y)
        if x.dispellable ~= y.dispellable then return x.dispellable end
        if x.remaining ~= y.remaining then return x.remaining < y.remaining end
        return x.index < y.index
    end)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = { text = r.text, r = r.r, g = r.g, b = r.b, dispellable = r.dispellable }
    end
    return out
end

-- Runtime tooltip listing (secret-safe) ---------------------------------------------------------------------

-- Enumeration (secret-safe) ----------------------------------------------------------------------------
-- Auras may arrive with secret fields (and tables flagged secret) in combat. We never use #, comparisons,
-- arithmetic or `or` on possibly-secret values/tables outside a pcall; secret values are only passed
-- straight into widget setters. Returns an array of aura tables, or nil when every method failed.

local debugInfo = {}      -- written by /hf debug auras (its own enumeration)
local renderInfo = {}     -- written by the real render path (what happened in combat)
Auras.debugInfo = debugInfo
Auras.renderInfo = renderInfo

local function safeLen(t)
    local ok, n = pcall(function() return #t end)
    if ok and type(n) == "number" then return n end
    return nil
end

-- Enumerates auras with the first method that works, mirroring how Blizzard's own frames read them in the
-- Midnight API: GetAuraSlots + GetAuraDataBySlot first, then GetUnitAuras, instance IDs, and by index.
-- Every call is in a pcall. Per-method outcomes are recorded in store[unit:filter].methods for /hf debug auras.
-- Returns an array of aura data, or nil when every method failed.
local function enumerate(unit, filter, max, store)
    local d = { method = "none", count = 0, errors = {}, filter = filter, methods = {} }
    store[unit .. ":" .. filter] = d
    local api = C_UnitAuras
    if not api then
        d.methods.api = "C_UnitAuras missing"
        return nil
    end
    local sortRule = Enum and Enum.UnitAuraSortRule and Enum.UnitAuraSortRule.Default

    local function gather(get, count)
        local out = {}
        for i = 1, count do
            -- the nil test happens inside the pcall: a secret table must never be compared outside it
            local ok, has, aura = pcall(function()
                local a = get(i)
                return a ~= nil, a
            end)
            if ok and has then out[#out + 1] = aura end
            if not ok then d.errors[#d.errors + 1] = tostring(has) end
        end
        return out
    end

    local function done(method, out)
        d.method, d.count = method, #out
        d.methods[method] = "ok (" .. #out .. ")"
        return out
    end

    -- 1. slots (what Blizzard's AuraUtil.ForEachAura uses)
    if api.GetAuraSlots and api.GetAuraDataBySlot then
        local ok, out = pcall(function()
            local list = {}
            local token
            local slotCount, slotErrors = 0, 0
            for _ = 1, 10 do
                local results = { api.GetAuraSlots(unit, filter, max, token) }
                token = results[1]
                for i = 2, #results do
                    slotCount = slotCount + 1
                    local sok, has, aura = pcall(function()
                        local a = api.GetAuraDataBySlot(unit, results[i])
                        return a ~= nil, a
                    end)
                    if sok and has then list[#list + 1] = aura end
                    if not sok then
                        slotErrors = slotErrors + 1
                        d.errors[#d.errors + 1] = "GetAuraDataBySlot: " .. tostring(has)
                    end
                end
                if token == nil or (max and #list >= max) then break end
            end
            -- slots existed but none could be read: this method failed (an empty slot list stays a success)
            if slotCount > 0 and slotErrors == slotCount then
                error("GetAuraDataBySlot failed for all " .. slotCount .. " slots", 0)
            end
            return list
        end)
        if ok and type(out) == "table" then return done("slots", out) end
        d.methods.slots = "failed: " .. tostring(out)
    else
        d.methods.slots = "API missing"
    end

    -- 2. GetUnitAuras
    if api.GetUnitAuras then
        local ok, list = pcall(api.GetUnitAuras, unit, filter, max, sortRule)
        if not ok then
            d.errors[#d.errors + 1] = "GetUnitAuras: " .. tostring(list)
            -- an unsupported filter string errors; retry with the base filter
            local base = filter:match("^[^|]+")
            if base ~= filter then
                ok, list = pcall(api.GetUnitAuras, unit, base, max, sortRule)
            end
        end
        if ok and type(list) == "table" then
            local n = safeLen(list)
            if n then
                d.tableSecret = issecrettable and select(2, pcall(issecrettable, list)) or false
                return done("GetUnitAuras", gather(function(i) return list[i] end, n))
            end
            d.methods.GetUnitAuras = "table not indexable"
        elseif not ok then
            d.methods.GetUnitAuras = "failed: " .. tostring(list)
        else
            d.methods.GetUnitAuras = "no table"
        end
    else
        d.methods.GetUnitAuras = "API missing"
    end

    -- 3. instance IDs
    if api.GetUnitAuraInstanceIDs and api.GetAuraDataByAuraInstanceID then
        local ok, ids = pcall(api.GetUnitAuraInstanceIDs, unit, filter, max, sortRule)
        local n = ok and type(ids) == "table" and safeLen(ids)
        if n then
            return done("InstanceIDs", gather(function(i) return api.GetAuraDataByAuraInstanceID(unit, ids[i]) end, n))
        end
        d.methods.InstanceIDs = "failed: " .. tostring(ids)
    else
        d.methods.InstanceIDs = "API missing"
    end

    -- 4. by index
    if api.GetAuraDataByIndex then
        local out = {}
        for i = 1, max or 40 do
            local ok, has, aura = pcall(function()
                local a = api.GetAuraDataByIndex(unit, i, filter)
                return a ~= nil, a
            end)
            if not ok then
                d.errors[#d.errors + 1] = "GetAuraDataByIndex: " .. tostring(has)
                if i == 1 then
                    d.methods.ByIndex = "failed at index 1: " .. tostring(has)
                    return nil
                end
                break
            end
            if not has then break end
            out[#out + 1] = aura
        end
        return done("ByIndex", out)
    end
    d.methods.ByIndex = "API missing"
    return nil
end

local function fieldsReadable(a)
    local ok, readable = pcall(function()
        return not (issecret(a.name) or issecret(a.expirationTime) or issecret(a.duration)
            or issecret(a.applications) or issecret(a.dispelName) or issecret(a.icon))
    end)
    return ok and readable
end

local function safeField(a, key)
    local ok, v = pcall(function() return a[key] end)
    if ok then return v end
end

-- Adds a "Debuffs (N)" / "Buffs (N)" section to the tooltip. Returns true if anything was added.
function Auras.AppendTooltip(tooltip, unit, harmful)
    if ns.InCombat() then
        tooltip:AddLine("Auras are shown on the bar during combat", 0.6, 0.6, 0.6)
        return true
    end
    local list = enumerate(unit, harmful and "HARMFUL" or "HELPFUL", 40, debugInfo)
    if list == nil then
        tooltip:AddLine((harmful and "Debuffs" or "Buffs") .. " hidden by the game during combat", 0.6, 0.6, 0.6)
        return true
    end
    local total = #list
    if total == 0 then return false end

    local readable, secretEntries = {}, {}
    for _, a in ipairs(list) do
        if fieldsReadable(a) then
            readable[#readable + 1] = a
        else
            secretEntries[#secretEntries + 1] = a
        end
    end
    local canDispel = {}
    local class = ns.PlayerClass()
    local data = class and ns.Classes.DATA[class]
    for _, t in ipairs(data and data.dispels or {}) do canDispel[#canDispel + 1] = t end

    tooltip:AddLine((harmful and "Debuffs (" or "Buffs (") .. total .. ")", 1, 0.82, 0)
    for _, line in ipairs(Auras.BuildTooltipLines(readable, GetTime(), canDispel, { buff = not harmful })) do
        if line.dispellable then
            tooltip:AddLine(line.text, 0.3, 1, 0.3)
        else
            tooltip:AddLine(line.text, line.r, line.g, line.b)
        end
    end
    -- secret entries: hand name and icon straight to the tooltip, with no format/concatenation/inspection
    local hidden = 0
    for _, a in ipairs(secretEntries) do
        local ok = pcall(function()
            tooltip:AddLine(a.name, 1, 0.6, 0.6)
            -- no truth test on the (possibly secret) icon: hand it straight to the tooltip
            if tooltip.AddTexture then pcall(tooltip.AddTexture, tooltip, a.icon) end
        end)
        if not ok then hidden = hidden + 1 end
    end
    if hidden > 0 then
        tooltip:AddLine(hidden .. " entries hidden by the game during combat", 0.6, 0.6, 0.6)
    end
    return true
end

local function onTimer(_, elapsed)
    if Auras.SafetyTick then Auras.SafetyTick(elapsed) end
    timerFrame.acc = (timerFrame.acc or 0) + elapsed
    if timerFrame.acc < TIMER_INTERVAL then return end
    timerFrame.acc = 0
    local now = GetTime()
    for icon in pairs(liveIcons) do
        if icon.expiration then
            local remaining = icon.expiration - now
            if remaining > 0 then
                icon.time:SetText(ns.Util.FormatAuraTime(remaining))
                if remaining < 10 then
                    icon.time:SetTextColor(1, 0.3, 0.3)
                else
                    icon.time:SetTextColor(1, 1, 1)
                end
            else
                icon.time:SetText("")
            end
        end
    end
end

local function createIcon(parent)
    local icon = ns.NewFrame("Frame", nil, parent)
    icon.border = icon:CreateTexture(nil, "BACKGROUND")
    icon.border:SetAllPoints()
    icon.border:SetTexture(WHITE)
    icon.border:SetVertexColor(0, 0, 0, 1)
    icon.texture = icon:CreateTexture(nil, "ARTWORK")
    icon.texture:SetPoint("TOPLEFT", 1, -1)
    icon.texture:SetPoint("BOTTOMRIGHT", -1, 1)
    icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon.cooldown = ns.NewFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
    icon.cooldown:SetAllPoints(icon.texture)
    icon.cooldown:SetDrawEdge(false)
    icon.cooldown:SetReverse(true)
    local overlay = ns.NewFrame("Frame", nil, icon)
    overlay:SetAllPoints()
    overlay:SetFrameLevel(icon.cooldown:GetFrameLevel() + 2)
    icon.time = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    icon.time:SetPoint("BOTTOM", 0, -1)
    icon.count = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    icon.count:SetPoint("TOPRIGHT", 1, 0)
    icon:SetScript("OnEnter", function(self) Auras.ShowIconTooltip(self) end)
    icon:SetScript("OnLeave", function(self) Auras.HideIconTooltip(self) end)
    icon:Hide()
    return icon
end

-- Per-icon aura tooltip (Blizzard's own aura tooltip, anchored at the icon). Works in combat: the aura
-- instance ID is not secret; every call is in a pcall and falls back step by step to a plain name line.
function Auras.ShowIconTooltip(icon)
    if not GameTooltip or not icon.unit then return end
    Auras.hoveredIcon = icon
    GameTooltip:SetOwner(icon, "ANCHOR_RIGHT")
    local shown = false
    local id = icon.auraInstanceID
    if issecret(id) or id ~= nil then
        local method
        if icon.isDebuff then method = GameTooltip.SetUnitDebuffByAuraInstanceID else method = GameTooltip.SetUnitBuffByAuraInstanceID end
        if method then
            shown = pcall(method, GameTooltip, icon.unit, id, icon.filter)
        end
    end
    if not shown and icon.auraIndex and GameTooltip.SetUnitAura then
        shown = pcall(GameTooltip.SetUnitAura, GameTooltip, icon.unit, icon.auraIndex, icon.filter)
    end
    if not shown then
        shown = pcall(function() GameTooltip:AddLine(icon.auraName, 1, 1, 1) end)
    end
    if shown then GameTooltip:Show() end
end

function Auras.HideIconTooltip(icon)
    if Auras.hoveredIcon == icon then Auras.hoveredIcon = nil end
    if GameTooltip then GameTooltip:Hide() end
    -- the mouse may be back over the bar: bring its tooltip back
    local UF = ns.UnitFrames
    if UF and UF.hovered then UF:ShowTooltip(UF.hovered) end
end

local function createZone(row, kind)
    -- plain container, no box or backdrop around the icons
    local zone = ns.NewFrame("Frame", nil, row)
    zone.kind = kind
    zone:EnableMouse(false)
    zone:Hide()
    return zone
end

-- Native path: Blizzard's AuraContainer draws the icons itself (including in combat), so this addon never reads
-- aura data for display. One container per zone; the group options mirror the aura settings.
Auras.mode = "fallback"
Auras.containerErrors = {}
local containerState = setmetatable({}, { __mode = "k" })
local BUTTON_TEMPLATE = "HealerForeverAuraButtonTemplate"
-- raid only (Auras.xml): no mouse from creation on; the glow carrier has no visible parts
local RAID_BUTTON_TEMPLATE = "HealerForeverRaidAuraButtonTemplate"
local RAID_GLOW_TEMPLATE = "HealerForeverRaidGlowButtonTemplate"
Auras.RAID_BUTTON_TEMPLATE, Auras.RAID_GLOW_TEMPLATE = RAID_BUTTON_TEMPLATE, RAID_GLOW_TEMPLATE

local function containerError(label, err)
    ns.LogError("aura-container:" .. label, err)
    local list = Auras.containerErrors
    if #list < 20 then list[#list + 1] = label .. ": " .. tostring(err) end
end

local function containerApiPresent()
    return type(Enum) == "table" and Enum.CustomAuraButtonDispelTypeTextureStyle ~= nil
        and type(AuraContainerSortMethod) == "table" and type(AuraContainerSortDirection) == "table"
        and type(AnchorUtil) == "table" and type(AnchorUtil.FlowDirection) == "table"
        and type(AnchorUtil.FlowLayoutAxis) == "table"
end

function Auras.ContainerFilter(kind, cfg)
    if kind == "buff" then return cfg.onlyMine and "HELPFUL|PLAYER" or "HELPFUL" end
    return cfg.onlyDispellable and "HARMFUL|RAID_PLAYER_DISPELLABLE" or "HARMFUL"
end

-- Icons per row for a zone: the saved number, or (0 = auto) as many as fit the bar width.
function Auras.PerRowFor(kind, cfg)
    cfg = cfg or ns.db.auras
    if cfg.perRow and cfg.perRow > 0 then return cfg.perRow end
    local isDebuff = kind == "debuff"
    local count = math.max(1, (isDebuff and cfg.maxDebuffs or cfg.maxBuffs) or 1)
    local pos = isDebuff and cfg.debuffPosition or cfg.buffPosition
    local grow = pos == "inside" and "left" or cfg.grow
    if grow == "down" or grow == "up" then return count end
    if pos == "left" or pos == "right" then return math.min(count, 5) end
    local size = isDebuff and cfg.debuffSize or cfg.buffSize
    local gap = ns.Util.ICON_GAP
    if pos == "inside" then size, gap = math.min(size, isDebuff and 16 or 14), 2 end
    local width = ns.db and ns.db.frames and ns.db.frames.width or 180
    return math.min(count, ns.Util.AutoPerRow(width, size, gap))
end

-- Pure: layout numbers for one zone, matching Util.IconOffset (grow, perRow, gaps, timer line).
function Auras.ContainerGeometry(kind, cfg)
    local isDebuff = kind == "debuff"
    local pos = isDebuff and cfg.debuffPosition or cfg.buffPosition
    local inside = pos == "inside"
    local size = isDebuff and cfg.debuffSize or cfg.buffSize
    local grow = cfg.grow or "right"
    local timerH = cfg.timerPos == "inside" and 0 or ns.Util.TIMER_HEIGHT
    local gap = ns.Util.ICON_GAP
    if inside then
        size = math.min(size, isDebuff and 16 or 14)
        grow, timerH, gap = "left", 0, 2
    end
    local perRow = math.max(1, Auras.PerRowFor(kind, cfg))
    local vertical = grow == "down" or grow == "up"
    local g = {
        kind = kind, size = size, timerH = timerH, gap = gap, perRow = perRow, grow = grow, inside = inside,
        vertical = vertical, elementHeight = size + timerH, padding = { 2, 2, 2, 2 },
        anchor = grow == "left" and "TOPRIGHT" or grow == "up" and "BOTTOMLEFT" or "TOPLEFT",
        horizontal = grow == "left" and "Left" or "Right",
        verticalDir = grow == "up" and "Up" or "Down",
        max = isDebuff and cfg.maxDebuffs or cfg.maxBuffs,
        colorBorder = isDebuff and cfg.colorDebuffBorder and true or false,
        mouse = cfg.tooltipIcons and true or false,
        filter = Auras.ContainerFilter(kind, cfg),
    }
    if grow == "up" then g.padding[4] = 2 + timerH end
    local along = vertical and (size + timerH) or size
    g.maxLine = perRow * along + (perRow - 1) * gap + 0.5
    g.key = table.concat({ size, timerH, gap, perRow, grow, tostring(inside), g.max, tostring(g.colorBorder),
        tostring(g.mouse), g.filter, cfg.timerPos or "" }, "|")
    return g
end

-- Compact countdown text ("6m", "55m", "45s"): same intervals as Blizzard's default aura formatter, minus the
-- whitespace between number and unit. nil when the formatter API is unavailable (the default text is used then).
local durationFormatter, formatterTried
local function getDurationFormatter()
    if formatterTried then return durationFormatter end
    formatterTried = true
    pcall(function()
        local f = C_StringUtil.CreateSecondsFormatter()
        local curve = C_CurveUtil.CreateCurve()
        curve:SetType(Enum.LuaCurveType.Step)
        curve:AddPoint(0, Enum.SecondsFormatterInterval.Seconds)
        curve:AddPoint(1 + 1.5 * 60, Enum.SecondsFormatterInterval.Minutes)
        curve:AddPoint(1 + 1.5 * 3600, Enum.SecondsFormatterInterval.Hours)
        curve:AddPoint(1 + 1.5 * 86400, Enum.SecondsFormatterInterval.Days)
        f:SetDefaultAbbreviation(Enum.SecondsFormatterAbbreviation.OneLetter)
        f:SetRounding(Enum.SecondsFormatterRounding.Truncate)
        f:SetCanRoundUpLastUnit(true)
        f:SetMinInterval(Enum.SecondsFormatterInterval.Seconds)
        f:SetMaxIntervalCurve(curve)
        f:SetDesiredUnitCount(1)
        f:SetStripIntervalWhitespace(Enum.SecondsFormatterIntervalWhitespace.StripIgnoreLocale)
        durationFormatter = f
    end)
    return durationFormatter
end

local function frameStep(_, label, fn)
    local ok, err = pcall(fn)
    if not ok then containerError(label, err) end
end

-- Mouse setup of the native aura buttons. The game creates new aura buttons mid-fight (initializeFrame runs then),
-- and the mouse setters are blocked in combat (real log: "ADDON_ACTION_BLOCKED: Button:SetPropagateMouseMotion()",
-- in combat, count 80). In combat the wanted state is only remembered and applied when combat ends. Until then a
-- new button keeps the XML template defaults (clicks off, motion on), so clicks still fall through to the unit button.
local mousePending = setmetatable({}, { __mode = "k" })

local function setMouseNow(frame, mouse, inside)
    -- hover tooltip only; clicks always fall through to the secure unit button underneath
    if frame.SetMouseClickEnabled then frame:SetMouseClickEnabled(false) end
    if frame.SetMouseMotionEnabled then frame:SetMouseMotionEnabled(mouse) end
    if frame.SetPropagateMouseMotion then frame:SetPropagateMouseMotion(inside) end
    frame.hfMouseKey = (mouse and "m" or "-") .. (inside and "i" or "-")
end

local function flushMouse()
    local list = {}
    for frame, want in pairs(mousePending) do list[#list + 1] = { frame, want } end
    for _, item in ipairs(list) do
        local frame, want = item[1], item[2]
        if ns.InCombat() then
            ns:AfterCombat("aura-mouse", flushMouse, true)
            return
        end
        mousePending[frame] = nil
        local ok, err = pcall(setMouseNow, frame, want.mouse, want.inside)
        if not ok then containerError("mouse", err) end
    end
end
Auras.FlushMouse = flushMouse

local function applyMouse(frame, mouse, inside)
    if frame.hfMouseKey == (mouse and "m" or "-") .. (inside and "i" or "-") then
        mousePending[frame] = nil
        return
    end
    if ns.InCombat() then
        mousePending[frame] = { mouse = mouse, inside = inside }
        ns:AfterCombat("aura-mouse", flushMouse, true)
        return
    end
    mousePending[frame] = nil
    setMouseNow(frame, mouse, inside)
end

function Auras.MousePendingCount()
    local n = 0
    for _ in pairs(mousePending) do n = n + 1 end
    return n
end

local function configureFrame(st, frame)
    local g = st.geom
    frameStep(st, "size", function() frame:SetSize(g.size, g.size) end)
    frameStep(st, "timer-font", function()
        local path = frame.Time:GetFont()
        local fontSize = math.max(8, math.min(11, math.floor(g.size * 0.55 + 0.5)))
        frame.Time:SetFont(path, fontSize, "OUTLINE")
        frame.Time:SetWordWrap(false)
        frame.Time:SetJustifyH("CENTER")
    end)
    frameStep(st, "timer-anchor", function()
        frame.Time:ClearAllPoints()
        if g.timerH > 0 then
            frame.Time:SetPoint("TOP", frame, "BOTTOM", 0, -1)
        else
            frame.Time:SetPoint("BOTTOM", frame, "BOTTOM", 0, 1)
        end
    end)
    frameStep(st, "backdrop", function()
        if st.kind == "debuff" then
            frame.Backdrop:SetVertexColor(DEFAULT_DEBUFF_COLOR.r, DEFAULT_DEBUFF_COLOR.g, DEFAULT_DEBUFF_COLOR.b, 1)
        else
            frame.Backdrop:SetVertexColor(0, 0, 0, 1)
        end
    end)
    if g.compact then
        -- raid debuff icons are tiny: no countdown text (the game still draws the cooldown swipe)
        frameStep(st, "compact", function() frame.Time:SetAlpha(0) end)
    end
    -- deferred to the end of combat when needed (see applyMouse)
    frameStep(st, "mouse", function() applyMouse(frame, g.mouse, g.inside) end)
    frameStep(st, "dispel-border", function()
        if st.kind ~= "debuff" then return end
        local want = g.colorBorder
        if want and not frame.hfDispel then
            frame:AddDispelTypeTexture(frame.DispelBorder, {
                style = Enum.CustomAuraButtonDispelTypeTextureStyle.Border, showWhenHarmful = true })
            frame.hfDispel = true
        elseif not want and frame.hfDispel then
            frame:RemoveDispelTypeTexture(frame.DispelBorder)
            frame.hfDispel = false
        end
        if not want then frame.DispelBorder:Hide() end
    end)
end

-- The n-th distinct frame this container initialised (1-based). The game may run initializeFrame again on a frame it
-- reuses from its pool: the frame keeps its first index, so the count never inflates.
local function initIndex(st, frame)
    st.initSeen = st.initSeen or setmetatable({}, { __mode = "k" })
    local index = st.initSeen[frame]
    if not index then
        st.initCount = (st.initCount or 0) + 1
        index = st.initCount
        st.initSeen[frame] = index
    end
    return index
end

local function initializeFrame(st, frame)
    if st.geom.glowOnly then
        -- raid glow carrier: nothing to wire (no icon, timer or count); the hook hands it the glow texture
        local hooks = st.hooks
        if hooks and hooks.onInit then
            local index = initIndex(st, frame)
            frameStep(st, "init-hook", function() hooks.onInit(frame, index, st) end)
        end
        return
    end
    frameStep(st, "icon", function() frame:SetIcon(frame.Icon) end)
    frameStep(st, "cooldown", function() frame:SetDurationCooldown(frame.Cooldown) end)
    frameStep(st, "duration-text", function()
        local f = getDurationFormatter()
        frame:SetDurationText(frame.Time, f and { textFormatter = f } or {})
    end)
    frameStep(st, "count", function() frame:SetApplicationCount(frame.Count, {}) end)
    configureFrame(st, frame)
    local hooks = st.hooks
    if hooks and hooks.onInit then
        local index = initIndex(st, frame)
        frameStep(st, "init-hook", function() hooks.onInit(frame, index, st) end)
    end
end

local function groupOptions(st)
    local g = st.geom
    return {
        elementSpacing = g.gap, lineSpacing = g.gap, elementWidth = g.size, elementHeight = g.elementHeight,
    }
end

local function applyFlow(st)
    local c, g = st.frame, st.geom
    c:SetFlowLayoutAxis(g.vertical and AnchorUtil.FlowLayoutAxis.Vertical or AnchorUtil.FlowLayoutAxis.Horizontal)
    c:SetFlowLayoutAnchorPoint(g.anchor)
    c:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection[g.horizontal], AnchorUtil.FlowDirection[g.verticalDir])
    c:SetFlowLayoutPadding(unpack(g.padding))
    c:SetFlowLayoutMaximumLineSize(g.maxLine)
    c:ClearAllPoints()
    c:SetPoint(g.anchor, st.zone, g.anchor, 0, 0)
end

-- The one raw CreateFrame of the addon (an AuraContainer must not be wrapped by ns.NewFrame). Party zones and the raid
-- debuff zones both come through here.
local function buildContainer(zone, kind, geom, hooks)
    local st = { kind = kind, zone = zone, geom = geom, hooks = hooks }
    local frame = CreateFrame("AuraContainer", nil, zone, "CustomAuraContainerTemplate")
    if type(frame.AddAuraGroup) ~= "function" or type(frame.SetUnit) ~= "function" then
        error("AuraContainer API missing on the created frame")
    end
    st.frame = frame
    frame:SetUnit("none")
    st.unit = "none"
    frame:AddAuraGroup(kind, st.geom.filter, {
        maxFrameCount = st.geom.max,
        templateNames = { st.geom.template or BUTTON_TEMPLATE },
        initializeFrame = function(f) initializeFrame(st, f) end,
        sortMethod = AuraContainerSortMethod.Default,
        sortDirection = AuraContainerSortDirection.Normal,
        layout = groupOptions(st),
    })
    applyFlow(st)
    st.appliedKey = st.geom.key
    containerState[frame] = st
    return st
end

local function createContainer(button, kind)
    return buildContainer(button.zones[kind], kind, Auras.ContainerGeometry(kind, ns.db.auras))
end

local function eachGroupFrame(st, fn)
    local c = st.frame
    local n = c:GetAuraGroupFrameCount(st.kind)
    for i = 1, n do
        local f = c:GetAuraGroupFrame(st.kind, i)
        if f then fn(f) end
    end
end

-- Re-applies a geometry to one container (out of combat: layout time). Callers skip unchanged geometry.
local function reconfigure(st, g)
    st.geom = g
    local c, kind = st.frame, st.kind
    frameStep(st, "filter", function() c:SetAuraGroupFilterString(kind, g.filter) end)
    frameStep(st, "max", function() c:SetAuraGroupMaxFrameCount(kind, g.max) end)
    frameStep(st, "group-layout", function() c:SetAuraGroupLayout(kind, groupOptions(st)) end)
    frameStep(st, "flow", function() applyFlow(st) end)
    if not g.glowOnly then
        frameStep(st, "frames", function() eachGroupFrame(st, function(f) configureFrame(st, f) end) end)
    end
    st.appliedKey = g.key
end

-- Re-applies the aura settings to one party container.
local function configureContainer(button, kind)
    local st = button.auraContainers[kind]
    local g = Auras.ContainerGeometry(kind, ns.db.auras)
    if st.appliedKey == g.key and st.zone == button.zones[kind] then return end
    reconfigure(st, g)
end

local function desiredUnit(button, kind)
    local cfg = ns.db.auras
    local enabled = kind == "buff" and cfg.showBuffs or kind == "debuff" and cfg.showDebuffs
    local unit = button.unit
    if enabled and unit and not button.isPet and ns.Exists(unit) then return unit end
    return "none"
end

local function unitGuid(unit)
    if not UnitGUID then return nil end
    local g = UnitGUID(unit)
    if issecret(g) then return nil end
    return g
end

-- SetUnit runs only when the token changes, a slot is filled or emptied, or another player now sits behind the same
-- token (GUID differs); never on range ticks or plain roster events. It never runs in combat: a pending change is
-- queued and the next update applies it.
local function applyUnits(button)
    for kind, st in pairs(button.auraContainers) do
        local want = desiredUnit(button, kind)
        if ns.InCombat() then
            if st.unit ~= want then
                ns:AfterCombat("aura-unit-" .. tostring(button.unit) .. kind, function()
                    if button.auraContainers then applyUnits(button) end
                end, true)
            end
        else
            local guid = want ~= "none" and unitGuid(want) or nil
            if st.unit ~= want then
                frameStep(st, "setunit", function() st.frame:SetUnit(want) end)
                st.unit, st.guid = want, guid
            elseif want ~= "none" and guid and st.guid and guid ~= st.guid then
                frameStep(st, "setunit", function()
                    st.frame:SetUnit("none")
                    st.frame:SetUnit(want)
                end)
                st.guid = guid
            elseif guid then
                st.guid = guid
            end
        end
    end
end

local function containerUpdate(button, source)
    if source == "event" then return end
    applyUnits(button)
end

-- True while the mouse is over one of this button's native aura buttons (the bar tooltip must stay out of the way).
function Auras.IsHoveringContainerButton(button)
    local cs = button and button.auraContainers
    if not cs then return false end
    for _, st in pairs(cs) do
        local ok, over = pcall(function()
            local c = st.frame
            for i = 1, c:GetAuraGroupFrameCount(st.kind) do
                local f = c:GetAuraGroupFrame(st.kind, i)
                if f and f:IsMouseOver() == true then return true end
            end
            return false
        end)
        if ok and over == true then return true end
    end
    return false
end

local function setupContainers(button)
    if not containerApiPresent() then return false end
    local ok, err = pcall(function()
        local made = {}
        for _, kind in ipairs({ "buff", "debuff" }) do made[kind] = createContainer(button, kind) end
        button.auraContainers = made
    end)
    if not ok then
        containerError("create", err)
        button.auraContainers = nil
        return false
    end
    return true
end

-- Raid debuff containers ---------------------------------------------------------------------------------------
-- The raid bars (Frames/RaidFrames.lua) reuse the native container code above: same template, same initializeFrame /
-- configureFrame / applyMouse (so a button the game creates mid-fight never gets a mouse setter in combat).

-- Pure: geometry of a raid debuff zone. Icons bottom-right growing left, one row, no timer text, the dispel-type
-- border on, no mouse (the bar underneath keeps hover and clicks; the raid template has the mouse off from creation).
function Auras.DebuffContainerGeometry(size, max, filter)
    max = math.max(1, max or 1)
    local gap = 1
    local g = {
        kind = "debuff", size = size, timerH = 0, gap = gap, perRow = max, grow = "left", inside = true,
        vertical = false, elementHeight = size, padding = { 0, 0, 0, 0 }, anchor = "BOTTOMRIGHT",
        horizontal = "Left", verticalDir = "Up", max = max, colorBorder = true, mouse = false, compact = true,
        filter = filter or "HARMFUL|RAID_PLAYER_DISPELLABLE", template = RAID_BUTTON_TEMPLATE,
    }
    g.maxLine = max * size + (max - 1) * gap + 0.5
    g.key = table.concat({ "raid", size, max, g.filter }, "|")
    return g
end

-- Pure: geometry of a raid glow container: one invisible carrier button (max 1) that the game shows while the member
-- has at least one debuff I can dispel. Nothing is wired on it but the glow texture (onInit hook).
function Auras.GlowContainerGeometry(filter)
    local g = {
        kind = "debuff", size = 1, timerH = 0, gap = 0, perRow = 1, grow = "left", inside = true, vertical = false,
        elementHeight = 1, padding = { 0, 0, 0, 0 }, anchor = "BOTTOMRIGHT", horizontal = "Left", verticalDir = "Up",
        max = 1, colorBorder = false, mouse = false, glowOnly = true, maxLine = 1.5,
        filter = filter or "HARMFUL|RAID_PLAYER_DISPELLABLE", template = RAID_GLOW_TEMPLATE,
    }
    g.key = table.concat({ "raid-glow", g.filter }, "|")
    return g
end

-- Creates one debuff container in `zone` (out of combat). hooks.onInit(frame, index, st) runs for every aura button
-- the game initialises (also in combat: only non-protected work there). Returns the container state or nil (API
-- missing or creation failed: logged).
function Auras.CreateDebuffContainer(button, zone, geom, hooks)
    if not containerApiPresent() then return nil end
    local ok, st = pcall(buildContainer, zone, "debuff", geom, hooks)
    if not ok then
        containerError("raid-create", st)
        return nil
    end
    st.owner = button
    return st
end

function Auras.ConfigureContainer(st, geom)
    if not st then return end
    if st.appliedKey == geom.key then return end
    local ok, err = pcall(reconfigure, st, geom)
    if not ok then containerError("raid-configure", err) end
end

function Auras.EachContainerFrame(st, fn)
    if not st then return end
    local ok, err = pcall(eachGroupFrame, st, fn)
    if not ok then containerError("raid-frames", err) end
end

-- Points a container at a unit token or "none". Same rule as the party containers: SetUnit never runs in combat (the
-- change is queued and re-checked after combat); out of combat it runs only when the token changes or another player
-- now sits behind the same token (GUID differs).
function Auras.SetContainerUnit(st, unit)
    if not st then return end
    unit = unit or "none"
    st.wantUnit = unit
    if ns.InCombat() then
        if st.unit ~= unit then
            ns:AfterCombat("aura-unit-raid-" .. tostring(st.frame), function()
                Auras.SetContainerUnit(st, st.wantUnit)
            end, true)
        end
        return
    end
    local guid = unit ~= "none" and unitGuid(unit) or nil
    if st.unit ~= unit then
        frameStep(st, "setunit", function() st.frame:SetUnit(unit) end)
        st.unit, st.guid = unit, guid
    elseif unit ~= "none" and guid and st.guid and guid ~= st.guid then
        frameStep(st, "setunit", function()
            st.frame:SetUnit("none")
            st.frame:SetUnit(unit)
        end)
        st.guid = guid
    elseif guid then
        st.guid = guid
    end
end

-- Fallback path: hand-drawn icons that are never updated in combat (aura data is locked there).
local fallbackNoted = false
local function noteFallback()
    if fallbackNoted then return end
    fallbackNoted = true
    ns:Print("aura icons update after combat on this client")
end

function Auras.Create(button)
    button.auraRow = ns.NewFrame("Frame", nil, button)
    button.auraRow:SetAllPoints(button)
    button.auraRow:SetFrameLevel(button:GetFrameLevel() + 12)
    button.zones = { buff = createZone(button.auraRow, "buff"), debuff = createZone(button.auraRow, "debuff") }
    button.buffIcons = {}
    button.debuffIcons = {}
    if setupContainers(button) then
        Auras.mode = "container"
        return
    end
    noteFallback()
    if not timerFrame then
        timerFrame = ns.NewFrame("Frame")
        timerFrame:SetScript("OnUpdate", onTimer)
    end
end

local function getIcon(zone, list, index, isDebuff)
    local icon = list[index]
    if not icon then
        icon = createIcon(zone)
        icon.isDebuff = isDebuff
        list[index] = icon
    end
    return icon
end

local function stepError(unit, label, err)
    ns.LogError("aura:" .. label, err)
    local d = debugInfo[unit .. ":render"]
    if d then d.errors[#d.errors + 1] = label .. ": " .. tostring(err) end
end

-- Each rendering step runs in its own pcall so one failing step (or one bad aura) never blanks the row.
local function applyAura(icon, unit, aura, size, colorBorder, filter, index)
    local function step(label, fn)
        local ok, err = pcall(fn)
        if not ok then stepError(unit, label, err) end
    end
    step("size", function() icon:SetSize(size, size) end)
    step("texture", function() icon.texture:SetTexture(aura.icon) end)

    local instanceID = safeField(aura, "auraInstanceID")
    icon.unit, icon.auraInstanceID, icon.filter, icon.auraIndex = unit, instanceID, filter, index
    icon.auraName = safeField(aura, "name")
    local setDuration = false
    step("duration", function()
        if C_UnitAuras and C_UnitAuras.GetAuraDuration and icon.cooldown.SetCooldownFromDurationObject and (issecret(instanceID) or instanceID ~= nil) then
            local d = C_UnitAuras.GetAuraDuration(unit, instanceID)
            if d then
                icon.cooldown:SetCooldownFromDurationObject(d)
                setDuration = true
            end
        end
    end)

    local exp, dur = safeField(aura, "expirationTime"), safeField(aura, "duration")
    local accessible = not issecret(exp) and not issecret(dur) and exp ~= nil
    step("timer", function()
        if accessible then
            if not setDuration and exp > 0 and dur and dur > 0 then
                icon.cooldown:SetCooldown(exp - dur, dur)
            elseif exp == 0 then
                icon.cooldown:Clear()
            end
            icon.cooldown:SetHideCountdownNumbers(true)
            icon.expiration = exp > 0 and exp or nil
            if not icon.expiration then icon.time:SetText("") end
        else
            -- secret timer: the Cooldown widget draws Blizzard's countdown numbers
            icon.cooldown:SetHideCountdownNumbers(false)
            icon.expiration = nil
            icon.time:SetText("")
        end
    end)

    step("count", function()
        local applications = safeField(aura, "applications")
        if C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount and (issecret(instanceID) or instanceID ~= nil) then
            icon.count:SetText(C_UnitAuras.GetAuraApplicationDisplayCount(unit, instanceID, 2))
        elseif not issecret(applications) and applications and applications > 1 then
            icon.count:SetText(applications)
        else
            icon.count:SetText("")
        end
    end)

    step("border", function()
        if icon.isDebuff then
            local r, g, b = DEFAULT_DEBUFF_COLOR.r, DEFAULT_DEBUFF_COLOR.g, DEFAULT_DEBUFF_COLOR.b
            if colorBorder then
                local applied = false
                local curve = getDispelCurve()
                if curve and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor and (issecret(instanceID) or instanceID ~= nil) then
                    applied = pcall(function()
                        local color = C_UnitAuras.GetAuraDispelTypeColor(unit, instanceID, curve)
                        icon.border:SetVertexColor(color:GetRGBA())
                    end)
                end
                if not applied then
                    local name = safeField(aura, "dispelName")
                    if not issecret(name) and name and ns.Classes.DISPEL_COLORS[name] then
                        local c = ns.Classes.DISPEL_COLORS[name]
                        r, g, b = c.r, c.g, c.b
                    end
                    icon.border:SetVertexColor(r, g, b, 1)
                end
            else
                icon.border:SetVertexColor(r, g, b, 1)
            end
        else
            icon.border:SetVertexColor(0, 0, 0, 1)
        end
    end)
    liveIcons[icon] = true
    icon:Show()
end

local function hideFrom(list, from)
    for i = from, #list do
        list[i]:Hide()
        liveIcons[list[i]] = nil
    end
end

-- Places icons inside their zone by grow direction, `perRow` icons per row.
local function layoutRow(list, count, size, zone, perRow)
    local grow = zone.grow or "right"
    local timerH = zone.timerH or 0
    for i = 1, count do
        local icon = list[i]
        local corner, x, y = ns.Util.IconOffset(i, size, perRow, grow, timerH, zone.iconGap)
        icon:ClearAllPoints()
        icon:SetPoint(corner, zone, corner, x, y)
        -- timer text: in the reserved line under the icon, or inside the bottom of the icon
        icon.time:ClearAllPoints()
        if timerH > 0 then
            icon.time:SetPoint("TOP", icon, "BOTTOM", 0, -1)
        else
            icon.time:SetPoint("BOTTOM", icon, "BOTTOM", 0, 1)
        end
    end
end

-- Per-unit aura cache (like Blizzard's compact frames): kept up to date from UNIT_AURA updateInfo and replaced by
-- every successful full scan. When every enumeration method fails the row is rendered from the cache instead of
-- keeping stale icons. Instance IDs are only compared when readable; a secret ID invalidates the cache.
local function cacheList(button, kind)
    return button.auraCache and button.auraCache[kind]
end

local function cacheSet(button, kind, auras)
    button.auraCache = button.auraCache or {}
    local copy = {}
    for i = 1, #auras do copy[i] = auras[i] end
    button.auraCache[kind] = copy
end

local function cacheInvalidate(button)
    button.auraCache = nil
end

local function filteredOut(unit, id, filter)
    if not (C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID) then return nil end
    local ok, out = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, id, filter)
    if ok and not issecret(out) then return out end
    return nil
end

-- Applies a UNIT_AURA delta to the cache (added / updated / removed). Anything unreadable drops the cache.
local function cacheApply(button, unit, updateInfo)
    local cache = button.auraCache
    if not cache then return end
    local function idOf(aura)
        local id = safeField(aura, "auraInstanceID")
        if issecret(id) then return nil, true end
        return id, false
    end
    local ok = pcall(function()
        for _, removed in ipairs(updateInfo.removedAuraInstanceIDs or {}) do
            if issecret(removed) then error("secret removed id") end
            for _, list in pairs(cache) do
                for i = #list, 1, -1 do
                    local id, secret = idOf(list[i])
                    if secret then error("secret cached id") end
                    if id == removed then table.remove(list, i) end
                end
            end
        end
        for _, id in ipairs(updateInfo.updatedAuraInstanceIDs or {}) do
            if issecret(id) then error("secret updated id") end
            local fresh = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
                and C_UnitAuras.GetAuraDataByAuraInstanceID(unit, id)
            if fresh then
                for _, list in pairs(cache) do
                    for i = 1, #list do
                        local cid = idOf(list[i])
                        if cid == id then list[i] = fresh end
                    end
                end
            end
        end
        for _, aura in ipairs(updateInfo.addedAuras or {}) do
            local id, secret = idOf(aura)
            if secret or id == nil then error("unreadable added aura") end
            local harmfulOut = filteredOut(unit, id, "HARMFUL")
            if harmfulOut == nil then error("cannot classify added aura") end
            local list = cache[harmfulOut and "buff" or "debuff"]
            if list then
                local present = false
                for i = 1, #list do
                    if idOf(list[i]) == id then present = true end
                end
                if not present and #list < 40 then list[#list + 1] = aura end
            end
        end
    end)
    if not ok then cacheInvalidate(button) end
end

local function cacheSize(button)
    local n = 0
    for _, list in pairs(button.auraCache or {}) do n = n + #list end
    return n
end

-- Renders one row. Returns true when a real enumeration succeeded (false = rendered from the cache or kept as is).
local function renderRow(button, kind, list, unit, filter, max, size, isDebuff, colorBorder, zone, perRow)
    local auras = enumerate(unit, filter, max, renderInfo)
    local d = debugInfo[unit .. ":render"] or { errors = {} }
    debugInfo[unit .. ":render"] = d
    local fromCache = false
    if auras == nil then
        auras = cacheList(button, kind)
        if auras == nil then
            d.errors[#d.errors + 1] = filter .. ": enumeration failed and no cache, keeping last-known icons"
            return false
        end
        fromCache = true
        d.errors[#d.errors + 1] = filter .. ": enumeration failed, rendered from the cache (" .. #auras .. ")"
    else
        cacheSet(button, kind, auras)
    end
    -- cross-check: an enumeration can still list an aura that is already gone (stale list); drop entries whose
    -- instance ID no longer resolves. Unreadable or erroring checks keep the entry.
    if C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
        local live = {}
        for i = 1, #auras do
            local id = safeField(auras[i], "auraInstanceID")
            local gone = false
            if issecret(id) or id ~= nil then
                local ok, isGone = pcall(function()
                    return C_UnitAuras.GetAuraDataByAuraInstanceID(unit, id) == nil
                end)
                gone = ok and isGone == true
            end
            if gone then
                d.errors[#d.errors + 1] = "dropped a listed aura whose instance ID no longer resolves"
            else
                live[#live + 1] = auras[i]
            end
        end
        auras = live
    end
    local count = math.min(#auras, max)
    for i = 1, count do
        local ok, err = pcall(function()
            applyAura(getIcon(zone, list, i, isDebuff), unit, auras[i], size, colorBorder, filter, i)
        end)
        if not ok then stepError(unit, "aura", err) end
    end
    layoutRow(list, count, size, zone, perRow)
    hideFrom(list, count + 1)
    zone:SetAlpha(count > 0 and 1 or 0)
    return not fromCache
end

-- Staleness protection ------------------------------------------------------------------------------------
-- A dispelled aura must never linger on the bar. Updates carry the UNIT_AURA updateInfo: removed instance IDs hide
-- their icons immediately (compared only when both IDs are readable), a full render follows, and when no
-- enumeration method works the last-known icons are kept for at most ~1s while a retry runs; after that icons
-- whose aura no longer exists (checked by instance ID inside a pcall) are hidden. A slow safety tick also
-- re-renders any unit that still shows debuff icons.

local LAST_KNOWN_SECONDS = 1
local RETRY_DELAY = 0.2
local FAST_RETRIES = 25     -- then keep retrying every SLOW_RETRY seconds while renders keep failing
local SLOW_RETRY = 1
local SAFETY_INTERVAL = 0.5

local function rowSetup()
    local cfg = ns.db.auras
    local buffSize = cfg.buffPosition == "inside" and math.min(cfg.buffSize, 14) or cfg.buffSize
    local debuffSize = cfg.debuffPosition == "inside" and math.min(cfg.debuffSize, 16) or cfg.debuffSize
    return cfg, buffSize, debuffSize
end

local function compact(list)
    local n = 0
    for i = 1, #list do
        if list[i]:IsShown() then
            n = n + 1
            if n ~= i then list[n], list[i] = list[i], list[n] end
        end
    end
    return n
end

-- Re-packs the visible icons of both rows after some were hidden.
local function reflow(button)
    local _, buffSize, debuffSize = rowSetup()
    local nb = compact(button.buffIcons)
    layoutRow(button.buffIcons, nb, buffSize, button.zones.buff, Auras.PerRowFor("buff"))
    button.zones.buff:SetAlpha(nb > 0 and 1 or 0)
    local nd = compact(button.debuffIcons)
    layoutRow(button.debuffIcons, nd, debuffSize, button.zones.debuff, Auras.PerRowFor("debuff"))
    button.zones.debuff:SetAlpha(nd > 0 and 1 or 0)
end

-- Hides the icons of removed auras. Returns true if a secret ID prevented a reliable comparison.
local function removeIcons(button, ids)
    local uncertain = false
    for _, list in ipairs({ button.buffIcons, button.debuffIcons }) do
        for i = 1, #list do
            local icon = list[i]
            if icon:IsShown() then
                local stored = icon.auraInstanceID
                for _, removed in ipairs(ids) do
                    if issecret(stored) or issecret(removed) then
                        uncertain = true
                    elseif stored == removed then
                        icon:Hide()
                        liveIcons[icon] = nil
                    end
                end
            end
        end
    end
    reflow(button)
    return uncertain
end

-- Hides icons whose aura instance no longer exists. Every check is in a pcall; unknown means keep.
local function verifyIcons(button)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID) then return end
    for _, list in ipairs({ button.buffIcons, button.debuffIcons }) do
        for i = 1, #list do
            local icon = list[i]
            local id = icon.auraInstanceID
            if icon:IsShown() and (issecret(id) or id ~= nil) then
                local ok, gone = pcall(function()
                    return C_UnitAuras.GetAuraDataByAuraInstanceID(button.unit, icon.auraInstanceID) == nil
                end)
                if ok and gone == true then
                    icon:Hide()
                    liveIcons[icon] = nil
                end
            end
        end
    end
    reflow(button)
end

local function scheduleRetry(button)
    if button.auraRetryPending then return end
    button.auraRetryPending = true
    button.auraRetries = (button.auraRetries or 0) + 1
    local function retry()
        button.auraRetryPending = false
        if button:IsShown() then Auras.Update(button, "retry") end
    end
    -- never give up: fast retries first, then once a second for as long as the last render failed
    local delay = button.auraRetries <= FAST_RETRIES and RETRY_DELAY or SLOW_RETRY
    if C_Timer and C_Timer.After then C_Timer.After(delay, retry) else retry() end
end

function Auras.Update(button, source, updateInfo)
    if button.auraContainers then return containerUpdate(button, source) end
    -- fallback path: aura data is locked in combat, so nothing is read, retried or redrawn until combat ends
    if ns.InCombat() then return end
    local unit = button.unit
    local cfg = ns.db.auras
    if not button.auraRow or button.isPet or not unit or not ns.Exists(unit) then
        if button.buffIcons then hideFrom(button.buffIcons, 1) end
        if button.debuffIcons then hideFrom(button.debuffIcons, 1) end
        return
    end
    debugInfo[unit .. ":render"] = { errors = {} }
    local dbg = { source = source or "update", full = false, removed = 0, lastKnown = false, uncertain = false,
        cacheUsed = false }
    button.auraDebug = dbg

    if updateInfo then
        pcall(function()
            if updateInfo.isFullUpdate then
                dbg.full = true
            else
                cacheApply(button, unit, updateInfo)
                local ids = updateInfo.removedAuraInstanceIDs
                if ids and #ids > 0 then
                    dbg.removed = #ids
                    dbg.uncertain = removeIcons(button, ids)
                end
            end
        end)
    end

    local ok = true
    local buffZone, debuffZone = button.zones.buff, button.zones.debuff
    local _, buffSize, debuffSize = rowSetup()
    if cfg.showBuffs then
        local filter = cfg.onlyMine and "HELPFUL|PLAYER" or "HELPFUL"
        if not renderRow(button, "buff", button.buffIcons, unit, filter, cfg.maxBuffs, buffSize, false, false, buffZone,
            Auras.PerRowFor("buff")) then
            ok = false
        end
    else
        hideFrom(button.buffIcons, 1)
        buffZone:SetAlpha(0)
    end
    if cfg.showDebuffs then
        local filter = cfg.onlyDispellable and "HARMFUL|RAID_PLAYER_DISPELLABLE" or "HARMFUL"
        if not renderRow(button, "debuff", button.debuffIcons, unit, filter, cfg.maxDebuffs, debuffSize, true,
            cfg.colorDebuffBorder, debuffZone, Auras.PerRowFor("debuff")) then
            ok = false
        end
    else
        hideFrom(button.debuffIcons, 1)
        debuffZone:SetAlpha(0)
    end

    dbg.cacheSize = cacheSize(button)
    button.auraFailed = not ok
    if ok then
        button.auraFailSince, button.auraRetries = nil, 0
    else
        -- nothing could be enumerated: render from the cache (done above), retry, then verify by instance ID
        dbg.lastKnown = true
        dbg.cacheUsed = button.auraCache ~= nil
        local now = GetTime()
        button.auraFailSince = button.auraFailSince or now
        if now - button.auraFailSince >= LAST_KNOWN_SECONDS then
            verifyIcons(button)
        end
        scheduleRetry(button)
    end
end

-- Safety tick: re-render any unit that still shows an aura icon (buff or debuff) or whose last render failed or used
-- the cache. Throttled; does nothing for units without icons.
local safetyAcc = 0
local function safetyTick(elapsed)
    if ns.InCombat() then return end
    safetyAcc = safetyAcc + elapsed
    if safetyAcc < SAFETY_INTERVAL then return end
    safetyAcc = 0
    local UF = ns.UnitFrames
    if not (UF and UF.buttons and ns.db) then return end
    for i = 1, #UF.buttons do
        local b = UF.buttons[i]
        if b:IsShown() and b.zones then
            local buff, debuff = b.buffIcons and b.buffIcons[1], b.debuffIcons and b.debuffIcons[1]
            if b.auraFailed or (buff and buff:IsShown()) or (debuff and debuff:IsShown()) then
                Auras.Update(b, "safety")
            end
        end
    end
end
Auras.SafetyTick = safetyTick

-- Re-renders every visible unit (combat ended, roster changed, zone change).
function Auras.UpdateAll(source)
    local UF = ns.UnitFrames
    if not (UF and UF.buttons and ns.db) then return end
    for _, b in ipairs(UF.buttons) do
        if b:IsShown() and b.zones then Auras.Update(b, source) end
    end
end

-- Fallback icons are frozen during combat: dim them; the full refresh on PLAYER_REGEN_ENABLED restores them.
ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
    local UF = ns.UnitFrames
    if not (UF and UF.buttons) then return end
    for _, b in ipairs(UF.buttons) do
        if b.zones and not b.auraContainers then
            b.zones.buff:SetAlpha(b.zones.buff:GetAlpha() > 0 and 0.4 or 0)
            b.zones.debuff:SetAlpha(b.zones.debuff:GetAlpha() > 0 and 0.4 or 0)
        end
    end
end)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() Auras.UpdateAll("combat ended") end)
ns:RegisterEvent("GROUP_ROSTER_UPDATE", function() Auras.UpdateAll("roster") end)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() Auras.UpdateAll("entering world") end)

-- /hf debug auras: lines describing what the API returned for a unit.
function Auras.Debug(unit)
    local lines = {}
    local cbtn = ns.UnitFrames and ns.UnitFrames.byUnit[unit]
    lines[#lines + 1] = "aura path: " .. (Auras.mode == "container" and "native AuraContainer" or "fallback (hand-drawn, updates after combat)")
    if cbtn and cbtn.auraContainers then
        for _, kind in ipairs({ "buff", "debuff" }) do
            local st = cbtn.auraContainers[kind]
            local live = "?"
            pcall(function() live = tostring(st.frame:GetUnit()) end)
            lines[#lines + 1] = string.format("  %s container: unit=%s (requested %s) filter=%s frames=%s", kind, live,
                tostring(st.unit), st.geom.filter, (pcall(st.frame.GetAuraGroupFrameCount, st.frame, kind)) and
                tostring(st.frame:GetAuraGroupFrameCount(kind)) or "?")
        end
        local fallbackShown = 0
        for _, list in ipairs({ cbtn.buffIcons or {}, cbtn.debuffIcons or {} }) do
            for _, icon in ipairs(list) do if icon:IsShown() then fallbackShown = fallbackShown + 1 end end
        end
        lines[#lines + 1] = string.format("  visible fallback icons: %d (must be 0) | bar tooltip suppressed while over an aura button: %s",
            fallbackShown, tostring(cbtn.barTooltipSuppressed == true))
        lines[#lines + 1] = "  limit: units that are far away or not visible may have no aura data; the game then shows nothing (no stale tooltip from this addon). Order: Blizzard default sort (stable)."
        if #Auras.containerErrors > 0 then
            lines[#lines + 1] = "  container errors: " .. table.concat(Auras.containerErrors, " | ")
        end
        return lines
    end
    if ns.InCombat() then
        lines[#lines + 1] = "in combat: the fallback path reads nothing (run again after combat)"
        return lines
    end
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local list = enumerate(unit, filter, 40, debugInfo)
        local d = debugInfo[unit .. ":" .. filter]
        local secretFields = {}
        local n = list and #list or 0
        for i = 1, math.min(n, 5) do
            local a = list[i]
            for _, key in ipairs({ "name", "icon", "expirationTime", "duration", "applications", "dispelName" }) do
                if issecret(safeField(a, key)) then secretFields[key] = true end
            end
        end
        local names = {}
        for key in pairs(secretFields) do names[#names + 1] = key end
        table.sort(names)
        lines[#lines + 1] = string.format("%s %s: method=%s count=%d tableSecret=%s secretFields=%s errors=%s", unit, filter,
            d.method, n, tostring(d.tableSecret), #names > 0 and table.concat(names, ",") or "none",
            #d.errors > 0 and table.concat(d.errors, " | ") or "none")
        -- what the REAL render path saw the last time it ran (combat included)
        local r = renderInfo[unit .. ":" .. filter]
        if r then
            local parts = {}
            for _, m in ipairs({ "slots", "GetUnitAuras", "InstanceIDs", "ByIndex" }) do
                parts[#parts + 1] = m .. "=" .. tostring(r.methods[m] or "-")
            end
            lines[#lines + 1] = "  render-time " .. filter .. ": used=" .. tostring(r.method) .. " | " .. table.concat(parts, " | ")
                .. (#r.errors > 0 and (" | errors: " .. table.concat(r.errors, "; ")) or "")
        end
    end
    local btn = ns.UnitFrames and ns.UnitFrames.byUnit[unit]
    if btn and btn.debuffIcons then
        -- every visible debuff icon, and anything shown in the zone that renderRow does not manage
        local inList = {}
        for _, icon in ipairs(btn.debuffIcons) do inList[icon] = true end
        for i, icon in ipairs(btn.debuffIcons) do
            if icon:IsShown() then
                local id = icon.auraInstanceID
                local idText = issecret(id) and "<secret>" or tostring(id)
                local name = icon.auraName
                local nameText = issecret(name) and "<secret>" or tostring(name)
                local ok, data = pcall(function()
                    return C_UnitAuras.GetAuraDataByAuraInstanceID(unit, id) ~= nil
                end)
                lines[#lines + 1] = string.format("  debuff icon %d: id=%s name=%s auraStillExists=%s zone=%s inDebuffIcons=%s",
                    i, idText, nameText, ok and tostring(data) or "unreadable",
                    tostring(icon:GetParent() == btn.zones.debuff), tostring(inList[icon] == true))
            end
        end
        for _, child in ipairs({ btn.zones.debuff:GetChildren() }) do
            if child:IsShown() and not inList[child] then
                lines[#lines + 1] = "  ORPHAN: a shown frame in the debuff zone is not in debuffIcons"
            end
        end
    end
    local u = btn and btn.auraDebug
    if u then
        lines[#lines + 1] = string.format("%s last update: source=%s full=%s removedIDs=%d uncertain(secret ID)=%s lastKnownIcons=%s cacheUsed=%s cacheSize=%s retries=%d",
            unit, tostring(u.source), tostring(u.full), u.removed, tostring(u.uncertain), tostring(u.lastKnown),
            tostring(u.cacheUsed), tostring(u.cacheSize), btn.auraRetries or 0)
    end
    local r = debugInfo[unit .. ":render"]
    if r and #r.errors > 0 then lines[#lines + 1] = unit .. " render errors: " .. table.concat(r.errors, " | ") end
    return lines
end

-- Creates every icon of a member up front and configures the mouse (out of combat only: layout time), so that
-- nothing is created or reconfigured during combat. Icons inside the bar let clicks and motion pass through
-- to the secure unit button; without that API they take no mouse at all there.
function Auras.Prepare(button)
    if not button.zones then return end
    -- the mouse setters below are blocked in combat: never run them there (callers are layout-time, this is the guard)
    if ns.InCombat() then
        ns:AfterCombat("aura-prepare-" .. tostring(button:GetName() or button.unit), function() Auras.Prepare(button) end, true)
        return
    end
    if button.auraContainers then
        for _, kind in ipairs({ "buff", "debuff" }) do
            local ok, err = pcall(configureContainer, button, kind)
            if not ok then containerError("configure", err) end
        end
        applyUnits(button)
        return
    end
    local cfg = ns.db.auras
    for _, kind in ipairs({ "buff", "debuff" }) do
        local isDebuff = kind == "debuff"
        local list = isDebuff and button.debuffIcons or button.buffIcons
        local count = isDebuff and cfg.maxDebuffs or cfg.maxBuffs
        local pos = isDebuff and cfg.debuffPosition or cfg.buffPosition
        for i = 1, count do
            local icon = getIcon(button.zones[kind], list, i, isDebuff)
            local mouse = cfg.tooltipIcons and true or false
            if pos == "inside" then
                if icon.SetPropagateMouseClicks then
                    icon:SetPropagateMouseClicks(true)
                    if icon.SetPropagateMouseMotion then icon:SetPropagateMouseMotion(true) end
                else
                    mouse = false
                end
            end
            icon:EnableMouse(mouse)
        end
    end
end

-- Plain list of {spellId, name, expirationTime} for buff evaluation (out of combat only).
function Auras.Snapshot(unit)
    local out = {}
    if ns.InCombat() then return out, false end
    local list = enumerate(unit, "HELPFUL", 40, debugInfo)
    if not list then return out, false end
    for _, aura in ipairs(list) do
        local id, name, exp = aura.spellId, aura.name, aura.expirationTime
        if issecret(id) or issecret(name) or issecret(exp) then
            return out, false
        end
        local source = aura.sourceUnit
        local mine = not issecret(source) and source == "player"
        local duration = aura.duration
        if issecret(duration) or type(duration) ~= "number" then duration = nil end
        out[#out + 1] = { spellId = id, name = name, expirationTime = exp or 0, isMine = mine, duration = duration }
    end
    return out, true
end
