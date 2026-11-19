local ADDON_NAME, ns = ...

-- Class-coloured party pins on the minimap: glossy class orbs with a role glyph, an edge pointer when out of range,
-- a red-X corpse marker where a member died, pets as smaller orbs.
--
-- Route used: custom pins parented to Minimap, positioned from C_Map.GetPlayerMapPosition +
-- C_Map.GetMapWorldSize. The native party blips are NOT retextured: no per-unit tint API for them
-- is known to exist (Minimap:SetPartyBlipTexture is not relied upon), so when positions are
-- unavailable we simply hide our pins and the native blips remain visible.
local MP = {}
ns.MinimapPins = MP

local issecret = ns.issecret
local sqrt, sin, cos = math.sqrt, math.sin, math.cos

-- Approximate minimap radius in yards per zoom level (0 = most zoomed out). Values are
-- community-known approximations for outdoor/indoor; they may drift on Forever.
local OUTDOOR_RADIUS = { [0] = 233.33, 200, 166.67, 133.33, 100, 66.67 }
local INDOOR_RADIUS = { [0] = 150, 120, 90, 60, 40, 25 }

local UPDATE_INTERVAL = 0.15
local UNITS = { "party1", "party2", "party3", "party4" }
local DEFAULT_SIZE = 16
local PET_SCALE = 0.72
local LOW_HP = 0.3

-- Pure helper (no WoW API). dx/dy are yards east/north of the player. Returns x, y (pixels from
-- the minimap center, +x right, +y up), and onEdge (true when clamped to the minimap radius).
function MP.ToMinimapOffset(dxYards, dyYards, radiusYards, minimapRadiusPx, facing, rotate)
    local dx, dy = dxYards or 0, dyYards or 0
    if rotate and facing then
        local s, c = sin(facing), cos(facing)
        dx, dy = dx * c + dy * s, -dx * s + dy * c
    end
    if not radiusYards or radiusYards <= 0 then
        return 0, 0, true
    end
    local scale = minimapRadiusPx / radiusYards
    local x, y = dx * scale, dy * scale
    local dist = sqrt(x * x + y * y)
    if dist > minimapRadiusPx then
        local k = minimapRadiusPx / dist
        return x * k, y * k, true
    end
    return x, y, false
end


local WHITE = "Interface\\Buttons\\WHITE8X8"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
-- Texture paths are from memory and unverified on 12.x; every use has a plain fallback.
local EDGE_ARROW = "Interface\\Minimap\\ROTATING-MINIMAPGUIDEARROW"
local COMBAT_TEXTURE = "Interface\\CharacterFrame\\UI-StateIcon"
local ROLE_ATLAS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }
local ROLE_COORDS = {
    TANK = { 0, 19 / 64, 22 / 64, 41 / 64 },
    HEALER = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
    DAMAGER = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
}

local PET_UNITS = { "pet", "partypet1", "partypet2", "partypet3", "partypet4" }

local pins = {}
local corpses = {}
local lastPos = {}
local lastMapID
local hinted = false
local ROLE_LABELS = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }

local function roundTexture(owner, tex)
    if owner.CreateMaskTexture then
        local mask = owner:CreateMaskTexture()
        mask:SetAllPoints(tex)
        mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        tex:AddMaskTexture(mask)
    end
end

local function setRoleGlyph(tex, role)
    local atlas = ROLE_ATLAS[role]
    if atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        tex:SetTexCoord(0, 1, 0, 1)
        tex:SetAtlas(atlas)
        return true
    elseif ROLE_COORDS[role] then
        tex:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
        tex:SetTexCoord(unpack(ROLE_COORDS[role]))
        return true
    end
    return false
end

local function outlined(fs, size)
    local font = fs:GetFont()
    if font then fs:SetFont(font, size, "OUTLINE") end
end

local function createPin(key)
    local pin = ns.NewFrame("Button", nil, Minimap)
    pin:SetSize(DEFAULT_SIZE, DEFAULT_SIZE)
    pin:SetFrameStrata("MEDIUM")
    pin:SetFrameLevel(Minimap:GetFrameLevel() + 6)
    pin.key = key

    pin.pulse = pin:CreateTexture(nil, "BACKGROUND", nil, -2)
    pin.pulse:SetPoint("CENTER")
    pin.pulse:SetTexture(WHITE)
    pin.pulse:SetVertexColor(1, 0.1, 0.1, 0.8)
    pin.pulse:SetBlendMode("ADD")
    roundTexture(pin, pin.pulse)
    local group = pin.pulse:CreateAnimationGroup()
    group:SetLooping("BOUNCE")
    local alpha = group:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.15)
    alpha:SetToAlpha(0.9)
    alpha:SetDuration(0.6)
    group:Play()
    pin.pulse:Hide()

    -- dashed ring (out of range): 12 small WHITE8X8 dots around the orb
    pin.ring = {}
    for i = 1, 12 do
        local dot = pin:CreateTexture(nil, "OVERLAY", nil, 0)
        dot:SetTexture(WHITE)
        dot:SetSize(2, 2)
        dot:SetVertexColor(0.75, 0.75, 0.75, 1)
        dot:Hide()
        pin.ring[i] = dot
    end

    pin.rim = pin:CreateTexture(nil, "BACKGROUND", nil, -1)
    pin.rim:SetPoint("CENTER")
    pin.rim:SetTexture(WHITE)
    pin.rim:SetVertexColor(0.05, 0.05, 0.07, 1)
    roundTexture(pin, pin.rim)

    pin.dot = pin:CreateTexture(nil, "ARTWORK")
    pin.dot:SetAllPoints()
    pin.dot:SetTexture(WHITE)
    roundTexture(pin, pin.dot)

    pin.gloss = pin:CreateTexture(nil, "OVERLAY", nil, 1)
    pin.gloss:SetPoint("TOPLEFT", pin, "TOPLEFT", 0, 0)
    pin.gloss:SetPoint("BOTTOMRIGHT", pin, "RIGHT", 0, 0)
    pin.gloss:SetTexture(WHITE)
    pin.gloss:SetVertexColor(1, 1, 1, 0.35)
    roundTexture(pin, pin.gloss)

    pin.roleGlyph = pin:CreateTexture(nil, "OVERLAY", nil, 2)
    pin.roleGlyph:SetPoint("CENTER")

    -- corpse X: a red outlined FontString, never a texture, so it can never be invisible
    pin.cross = pin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pin.cross:SetPoint("CENTER")
    pin.cross:SetText("X")
    pin.cross:SetTextColor(1, 0.1, 0.1)
    pin.cross:Hide()

    pin.combat = pin:CreateTexture(nil, "OVERLAY", nil, 4)
    pin.combat:SetTexture(COMBAT_TEXTURE)
    pin.combat:SetTexCoord(0.5, 1, 0, 0.49)
    pin.combat:Hide()

    pin.edge = pin:CreateTexture(nil, "OVERLAY", nil, 1)
    pin.edge:SetPoint("CENTER")
    pin.edge:SetTexture(EDGE_ARROW)
    pin.edge:Hide()
    -- fallback pointer, shown whenever the arrow texture is not usable: a chevron made of two thin WHITE8X8
    -- bars (no font glyph, so it can never render as nothing)
    pin.chevron = {}
    for i = 1, 2 do
        local bar = pin:CreateTexture(nil, "OVERLAY", nil, 1)
        bar:SetTexture(WHITE)
        bar:Hide()
        pin.chevron[i] = bar
    end
    pin.edgeCross = pin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pin.edgeCross:SetPoint("CENTER")
    pin.edgeCross:SetText("X")
    pin.edgeCross:SetTextColor(1, 0.1, 0.1)
    pin.edgeCross:Hide()

    pin:EnableMouse(true)     -- matches the default (names on hover); changed later only when the option changes
    pin.mouseOn = true
    pin:SetScript("OnEnter", function(self) MP.ShowTooltip(self) end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:Hide()
    return pin
end

local function getPin(key)
    local pin = pins[key]
    if not pin then
        pin = createPin(key)
        pins[key] = pin
    end
    return pin
end

local function hideAll()
    for _, pin in pairs(pins) do pin:Hide() end
end

local function noteUnavailable()
    hideAll()
    if not hinted then
        hinted = true
        ns:Print("Minimap pins unavailable here.")
    end
end

local function position(unit, mapID)
    local pos = C_Map.GetPlayerMapPosition(mapID, unit)
    if not pos then return nil end
    local x, y = pos:GetXY()
    if issecret(x) or issecret(y) or x == nil or y == nil then return nil end
    return x, y
end

-- Readable booleans only: a secret or missing value counts as false / unknown.
local function flag(value)
    if issecret(value) then return nil end
    return value and true or false
end

function MP.ShowTooltip(pin)
    local info = pin.info
    if not info or not GameTooltip then return end
    GameTooltip:SetOwner(pin, "ANCHOR_CURSOR")
    if info.corpse then
        GameTooltip:AddLine((info.name or "Someone") .. "'s body", info.r, info.g, info.b)
    else
        GameTooltip:AddLine(info.name or "?", info.r, info.g, info.b)
        if info.className then GameTooltip:AddLine(info.className, 0.8, 0.8, 0.8) end
        if info.role and ROLE_LABELS[info.role] then GameTooltip:AddLine(ROLE_LABELS[info.role], 0.8, 0.8, 0.8) end
        local unit = info.unit
        if unit and ns.Exists(unit) then
            local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
            if not issecret(hp) and not issecret(mx) and mx and mx > 0 then
                GameTooltip:AddLine(string.format("%d%% health", math.floor(hp / mx * 100 + 0.5)), 0.6, 1, 0.6)
            end
        end
        if info.dead then GameTooltip:AddLine(info.ghost and "Ghost" or "Dead", 1, 0.3, 0.3) end
    end
    if info.distance then GameTooltip:AddLine(string.format("%d yards", info.distance), 0.7, 0.7, 0.7) end
    GameTooltip:Show()
end

-- Sizes and shows one pin. info: { unit, name, className, r, g, b, role, dead, ghost, corpse, combat, low, pet,
-- dx, dy } with dx/dy in yards from the player.
local function placePin(pin, info, cfg, radiusYards, minimapRadius, facing, rotate)
    local size = (cfg.size or DEFAULT_SIZE) * (info.pet and PET_SCALE or 1)
    local x, y, onEdge = MP.ToMinimapOffset(info.dx, info.dy, radiusYards, minimapRadius - size / 2, facing, rotate)
    if onEdge and not cfg.showEdge then pin:Hide() return end
    info.distance = math.sqrt(info.dx * info.dx + info.dy * info.dy)
    pin.info = info
    pin:SetSize(size, size)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", Minimap, "CENTER", x, y)
    local mouse = cfg.showNames and true or false
    if pin.mouseOn ~= mouse then
        pin.mouseOn = mouse
        pin:EnableMouse(mouse)
    end

    local grey = info.dead and not info.corpse
    local r, g, b = info.r, info.g, info.b
    if grey then r, g, b = 0.55, 0.55, 0.55 end
    -- out of range / not visible: a faded grey orb with a dashed ring; healable (in range) orbs stay bright
    local faded = not info.corpse and (info.rangeState == "out" or info.rangeState == "hidden")
    if faded then r, g, b = (r + 0.55) / 2, (g + 0.55) / 2, (b + 0.55) / 2 end

    pin.edge:Hide(); pin.edgeCross:Hide()
    for _, bar in ipairs(pin.chevron) do bar:Hide() end
    if onEdge then
        -- out of range: an arrow clamped to the rim, pointing toward the member (or the body)
        pin.dot:Hide(); pin.rim:Hide(); pin.gloss:Hide(); pin.roleGlyph:Hide(); pin.cross:Hide()
        pin.combat:Hide(); pin.pulse:Hide()
        for _, dot in ipairs(pin.ring) do dot:Hide() end
        local angle = math.atan2 and math.atan2(x, y) or math.atan(x, y)
        pin.edge:SetSize(size * 1.2, size * 1.2)
        pin.edge:SetVertexColor(r, g, b, 1)
        if pin.edge.SetRotation then pin.edge:SetRotation(-angle) end
        local tex = pin.edge:GetTexture()
        if tex ~= nil and tex ~= "" then
            pin.edge:Show()
        else
            -- chevron tip toward the member (angle clockwise from up); arms trail back at +-45 degrees
            local len = size * 0.8
            local tx, ty = math.sin(angle) * size * 0.4, math.cos(angle) * size * 0.4
            for i, bar in ipairs(pin.chevron) do
                local arm = angle + math.pi + (i == 1 and 1 or -1) * math.pi / 4
                local ax, ay = math.sin(arm), math.cos(arm)
                bar:SetSize(len, 3)
                bar:ClearAllPoints()
                bar:SetPoint("CENTER", pin, "CENTER", tx + ax * len / 2, ty + ay * len / 2)
                if bar.SetRotation then bar:SetRotation(math.atan2 and math.atan2(ay, ax) or math.atan(ay, ax)) end
                bar:SetVertexColor(r, g, b, 1)
                bar:Show()
            end
        end
        if info.corpse then
            outlined(pin.edgeCross, math.max(8, size * 0.8))
            pin.edgeCross:Show()
        end
        pin:SetAlpha(0.85)
        pin:Show()
        return
    end

    pin.rim:SetSize(size + 3, size + 3)
    pin.rim:Show()
    pin.dot:SetVertexColor(r, g, b, 1)
    pin.dot:Show()
    pin.gloss:SetShown(not grey and not faded)
    for i, dot in ipairs(pin.ring) do
        if faded then
            local a = (i - 1) / 12 * 2 * math.pi
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", pin, "CENTER", math.sin(a) * (size / 2 + 3), math.cos(a) * (size / 2 + 3))
            dot:Show()
        else
            dot:Hide()
        end
    end
    local glyph = false
    if cfg.showRole and info.role and not info.pet and not info.corpse and not grey then
        pin.roleGlyph:SetSize(size * 0.6, size * 0.6)
        glyph = setRoleGlyph(pin.roleGlyph, info.role)
    end
    pin.roleGlyph:SetShown(glyph)
    outlined(pin.cross, math.max(8, size * (info.corpse and 1.0 or 0.8)))
    pin.cross:SetShown(info.corpse and true or false)
    pin.pulse:SetSize(size * 1.7, size * 1.7)
    pin.pulse:SetShown(cfg.pulse and info.low and true or false)
    pin.combat:SetSize(size * 0.6, size * 0.6)
    pin.combat:ClearAllPoints()
    pin.combat:SetPoint("TOPRIGHT", pin, "TOPRIGHT", size * 0.25, size * 0.25)
    pin.combat:SetShown(info.combat and not info.dead and true or false)
    pin:SetAlpha(faded and 0.55 or 1)
    pin:Show()
end

local function unitInfo(unit, isPet)
    local _, token = UnitClass(unit)
    if issecret(token) then token = nil end
    local color = token and ns.Classes.GetColor(token) or { r = 1, g = 1, b = 1 }
    local name = UnitName(unit)
    if issecret(name) then name = nil end
    local className = UnitClass(unit)
    if issecret(className) then className = nil end
    local dead = flag(UnitIsDeadOrGhost(unit))
    local ghost = dead and flag(UnitIsGhost(unit)) or false
    local rangeState
    if ns.UnitFrames and ns.UnitFrames.RangeState then rangeState = ns.UnitFrames.RangeState(unit) end
    local info = {
        rangeState = rangeState, unit = unit, name = name, className = className, r = color.r, g = color.g, b = color.b,
        role = not isPet and ns.Roles and ns.Roles.Get(unit) or nil, dead = dead, ghost = ghost, pet = isPet,
        combat = flag(UnitAffectingCombat and UnitAffectingCombat(unit)),
    }
    local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
    if not dead and not issecret(hp) and not issecret(mx) and mx and mx > 0 then
        info.low = hp / mx < LOW_HP
    end
    return info
end

function MP:Update()
    local cfg = ns.db and ns.db.pins
    if not cfg or not cfg.enabled or not ns.InGroup() then
        hideAll()
        corpses, lastPos = {}, {}
        return
    end
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetMapWorldSize) then
        noteUnavailable()
        return
    end
    local mapID = C_Map.GetBestMapForUnit("player")
    if issecret(mapID) or not mapID then noteUnavailable() return end
    local px, py = position("player", mapID)
    if not px then noteUnavailable() return end
    local mapW, mapH = C_Map.GetMapWorldSize(mapID)
    if issecret(mapW) or issecret(mapH) or not mapW or not mapH or mapW <= 0 then noteUnavailable() return end
    MP.mapID = mapID
    if mapID ~= lastMapID then
        -- a corpse only means something on the map where the member died
        corpses, lastPos, lastMapID = {}, {}, mapID
    end

    local zoom = Minimap:GetZoom() or 0
    local indoors = IsIndoors and IsIndoors()
    local radiusYards = (indoors and INDOOR_RADIUS or OUTDOOR_RADIUS)[zoom] or OUTDOOR_RADIUS[0]
    local rotate = GetCVar and GetCVar("rotateMinimap") == "1"
    local facing
    if rotate and GetPlayerFacing then
        facing = GetPlayerFacing()
        if issecret(facing) then facing = nil end
    end
    local minimapRadius = Minimap:GetWidth() / 2

    local function handle(unit, isPet)
        local key = unit
        if not ns.Exists(unit) then
            if pins[key] then pins[key]:Hide() end
            local corpseKey = "corpse:" .. unit
            if pins[corpseKey] then pins[corpseKey]:Hide() end
            corpses[unit], lastPos[unit] = nil, nil
            return
        end
        local info = unitInfo(unit, isPet)
        local x, y = position(unit, mapID)
        if x then lastPos[unit] = { x = x, y = y } end

        -- corpse tracking: remember where the member died, until revived / left / map change
        if cfg.markCorpse and not isPet then
            if info.dead and not info.ghost and not corpses[unit] then
                local at = x and { x = x, y = y } or lastPos[unit]
                if at then corpses[unit] = { x = at.x, y = at.y, name = info.name, r = info.r, g = info.g, b = info.b,
                    className = info.className, unit = unit } end
            elseif info.dead == false then
                corpses[unit] = nil
            end
        else
            corpses[unit] = nil
        end

        local memberPin = getPin(key)
        if info.dead and not info.ghost and not isPet then
            memberPin:Hide()          -- the body marker stands in for the member
        elseif x then
            info.dx, info.dy = (x - px) * mapW, (py - y) * mapH
            placePin(memberPin, info, cfg, radiusYards, minimapRadius, facing, rotate)
        else
            memberPin:Hide()
        end

        local corpse = corpses[unit]
        local corpsePin = getPin("corpse:" .. unit)
        if corpse then
            local cinfo = { unit = unit, name = corpse.name, className = corpse.className, r = corpse.r, g = corpse.g,
                b = corpse.b, corpse = true, dead = true,
                dx = (corpse.x - px) * mapW, dy = (py - corpse.y) * mapH }
            placePin(corpsePin, cinfo, cfg, radiusYards, minimapRadius, facing, rotate)
        else
            corpsePin:Hide()
        end
    end

    for _, unit in ipairs(UNITS) do handle(unit, false) end
    for _, unit in ipairs(PET_UNITS) do
        if cfg.showPets then
            handle(unit, true)
        elseif pins[unit] then
            pins[unit]:Hide()
        end
    end
end

ns:RegisterEvent("PLAYER_LOGIN", function()
    local driver = ns.NewFrame("Frame")
    local acc = 0
    driver:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < UPDATE_INTERVAL then return end
        acc = 0
        local t0 = ns.perfOn and debugprofilestop()
        MP:Update()
        if t0 then ns.Perf.Add("mp", t0) end
    end)
    MP.driver = driver
end)
ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() hinted = false end)
