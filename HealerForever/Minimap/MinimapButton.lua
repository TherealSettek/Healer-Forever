local ADDON_NAME, ns = ...

-- Minimap button, design B "Status badges": round gold-ringed button with a heal icon, a green/red status dot
-- (any buff missing), a lock badge and the active preset's initial. Entirely non-secure.
local MB = {}
ns.MinimapButton = MB

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local rad, deg, cos, sin = math.rad, math.deg, math.cos, math.sin

local WHITE = "Interface\\Buttons\\WHITE8X8"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local DEFAULT_ICON = "Interface\\Icons\\Spell_Holy_FlashHeal"
local UPDATE_INTERVAL = 1

function MB:UpdatePosition()
    local b = MB.button
    if not b then return end
    local angle = rad(ns.db.minimap.angle or 220)
    local radius = (Minimap:GetWidth() / 2) + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", cos(angle) * radius, sin(angle) * radius)
end

function MB:UpdateVisibility()
    if not MB.button then return end
    MB.button:SetShown(not ns.db.minimap.hide)
end

local function onDragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local angle = deg(atan2(cy / scale - my, cx / scale - mx))
    if angle < 0 then angle = angle + 360 end
    ns.db.minimap.angle = angle
    MB:UpdatePosition()
end

-- First UTF-8 character of the active preset's name, upper-cased.
local function presetInitial()
    local preset = ns.db.presets[ns.db.activePreset]
    local name = preset and preset.name or "?"
    local first = name:match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
    return first:upper()
end

local function missingCount()
    local BB = ns.BuffButtons
    return BB and BB.MissingCount and BB:MissingCount() or 0
end

local function mainHealIcon()
    local UF = ns.UnitFrames
    local spell = UF and UF.RangeSpell and UF.RangeSpell()
    if spell then
        local tex = ns.SpellTexture(spell)
        if tex then return tex end
    end
    return DEFAULT_ICON
end

local function showTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    local version = ns.AddonVersion()
    GameTooltip:AddLine("Healer Forever " .. (version == "dev" and "(dev)" or "v" .. version), 1, 0.82, 0)
    local preset = ns.db.presets[ns.db.activePreset]
    GameTooltip:AddLine("Active preset: " .. (preset and preset.name or "?"), 1, 1, 1)
    GameTooltip:AddLine(ns.db.frames.locked and "Bars: Locked" or "Bars: Unlocked", 1, 1, 1)
    local missing = missingCount()
    if missing > 0 then
        GameTooltip:AddLine("Missing buffs: " .. missing, 1, 0.3, 0.3)
    else
        GameTooltip:AddLine("Missing buffs: none", 0.3, 0.9, 0.4)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: Options", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click: Lock / unlock bars", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Shift-click: Next preset", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Drag: Move", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

function MB:UpdateBadges()
    local b = MB.button
    if not b then return end
    local badges = ns.db.minimap.badges ~= false
    b.icon:SetTexture(mainHealIcon())
    b.dot:SetShown(badges)
    b.letterPill:SetShown(badges)
    b.lock:SetShown(badges and ns.db.frames.locked and true or false)
    if badges then
        if missingCount() > 0 then
            b.dot:SetVertexColor(1, 0.15, 0.1, 1)
        else
            b.dot:SetVertexColor(0.2, 0.9, 0.3, 1)
        end
        b.letter:SetText(presetInitial())
        b.letterPill:SetWidth(math.max(12, b.letter:GetStringWidth() + 6))
    end
end

function MB:UpdateLock()
    MB:UpdateBadges()
end

local pending = false
function MB:RequestUpdate()
    if pending then return end
    pending = true
    local function run()
        pending = false
        MB:UpdateBadges()
    end
    if C_Timer and C_Timer.After then C_Timer.After(0.2, run) else run() end
end

function MB:Create()
    if MB.button then return end
    local b = ns.NewFrame("Button", "HealerForeverMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")

    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetSize(20, 20)
    b.bg:SetPoint("CENTER", 0, 0)
    b.bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("CENTER", 0, 0)
    b.icon:SetTexture(DEFAULT_ICON)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if b.CreateMaskTexture then
        local mask = b:CreateMaskTexture()
        mask:SetAllPoints(b.icon)
        mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        b.icon:AddMaskTexture(mask)
    end

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    hl:SetBlendMode("ADD")

    -- status dot (plain round texture: red = a buff is missing, green = all good)
    b.dot = b:CreateTexture(nil, "OVERLAY", nil, 6)
    b.dot:SetSize(8, 8)
    b.dot:SetPoint("TOPLEFT", 2, -2)
    b.dot:SetTexture(WHITE)
    if b.CreateMaskTexture then
        local mask = b:CreateMaskTexture()
        mask:SetAllPoints(b.dot)
        mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        b.dot:AddMaskTexture(mask)
    end

    b.lock = b:CreateTexture(nil, "OVERLAY", nil, 7)
    b.lock:SetSize(12, 12)
    b.lock:SetPoint("BOTTOMRIGHT", -1, 3)
    b.lock:SetTexture("Interface\\PetBattles\\PetBattle-LockIcon")

    b.letterPill = ns.NewFrame("Frame", nil, b, "BackdropTemplate")
    b.letterPill:SetHeight(12)
    b.letterPill:SetPoint("BOTTOMLEFT", 2, 4)
    b.letterPill:SetFrameLevel(b:GetFrameLevel() + 6)
    b.letterPill:SetBackdrop({ bgFile = WHITE })
    b.letterPill:SetBackdropColor(0, 0, 0, 0.8)
    b.letterPill:EnableMouse(false)
    b.letter = b.letterPill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.letter:SetPoint("CENTER")
    b.letter:SetTextColor(1, 0.82, 0)

    -- pressed state: the icon shifts one pixel and darkens
    b:SetScript("OnMouseDown", function(btn)
        btn.icon:ClearAllPoints()
        btn.icon:SetPoint("CENTER", 1, -1)
        btn.icon:SetVertexColor(0.6, 0.6, 0.6)
    end)
    b:SetScript("OnMouseUp", function(btn)
        btn.icon:ClearAllPoints()
        btn.icon:SetPoint("CENTER", 0, 0)
        btn.icon:SetVertexColor(1, 1, 1)
    end)

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ns.UnitFrames:SetLocked(not ns.db.frames.locked)
            ns:Print(ns.db.frames.locked and "Bars locked." or "Bars unlocked.")
        elseif IsShiftKeyDown() then
            ns:CyclePreset()
        elseif ns.Options then
            ns.Options:Toggle()
        end
    end)
    b:SetScript("OnDragStart", function(btn)
        if ns.db.minimap.lockPos then return end
        btn:SetScript("OnUpdate", onDragUpdate)
    end)
    b:SetScript("OnDragStop", function(btn) btn:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", showTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    MB.button = b
    MB:UpdatePosition()
    MB:UpdateVisibility()
    MB:UpdateBadges()
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(UPDATE_INTERVAL, function() MB:UpdateBadges() end)
    end
end

ns:RegisterEvent("PLAYER_LOGIN", function() MB:Create() end)
ns:RegisterEvent("UNIT_AURA", function(_, unit)
    if unit and ns.UnitFrames.byUnit[unit] then MB:RequestUpdate() end
end)
ns:RegisterEvent("GROUP_ROSTER_UPDATE", function() MB:RequestUpdate() end)
ns:On("CONFIG_CHANGED", function() MB:UpdateVisibility(); MB:UpdateBadges() end)
ns:On("LOCK_CHANGED", function() MB:UpdateBadges() end)
