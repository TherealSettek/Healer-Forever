local ADDON_NAME, ns = ...

-- "Preview full raid" (Options > Raid Layout, /hf raid preview): a FAKE raid of 10 / 20 / 25 / 40 players drawn at the
-- real raid position (ns.db.raid.point) with the real raid look, so every raid option can be tried outside a raid.
--   * plain non-secure frames (ns.NewFrame("Frame")), built and painted by RaidStyle (RS.Build / RS.Apply / RS.Render)
--     exactly like the real bars; placed with RaidLayout.AssignCells / GridCells; never a unit token, never a unit API
--   * made-up names (no real players), a class mix, every state (hurt, dead, offline, out of range, not visible, aggro,
--     target, you), MY buffs from the player's class catalog, debuffs only of the types the player's class can dispel
--   * not clickable: the mouse only shows a fake tooltip; clicks do nothing
--   * refused in combat and in a real raid; turns itself off when combat starts or you join a raid (one chat line)
--   * runtime only: never saved, always off after /reload
--   * drag the gold tag (frames unlocked) to move the raid position; the real raid anchor follows out of combat
local RP = { on = false, size = 40, frames = {}, data = {}, meta = {} }
ns.RaidPreview = RP

RP.SIZES = { 10, 20, 25, 40 }
RP.TAG_TEXT = "PREVIEW \226\128\148 not real players"
RP.MSG_COMBAT = "Can't preview in combat."
RP.MSG_RAID = "Can't preview while you are in a real raid: your real raid frames are already showing."
RP.MSG_OFF_COMBAT = "Preview turned off: combat started."
RP.MSG_OFF_RAID = "Preview turned off: you joined a real raid. Your real raid frames show now."

local WHITE = "Interface\\Buttons\\WHITE8X8"
local GOLD = { 1, 0.82, 0 }
local BUFF_DURATION = 600

local function RS() return ns.RaidStyle end
local function RL() return ns.RaidLayout end
local function cfg() return ns.db and ns.db.raid end

-- Fake roster -------------------------------------------------------------------------------------------------------
-- Made-up names only (privacy): never a real player, never UnitName.
RP.NAMES = {
    "You", "Aldric", "Brenna", "Corvin", "Dagna", "Elwyn", "Fennick", "Galen", "Hilda", "Ivor",
    "Jorund", "Kaela", "Lorcan", "Maren", "Nyssa", "Osric", "Perrin", "Quilla", "Rowan", "Sable",
    "Tamsin", "Ulric", "Vesna", "Wendel", "Ysolde", "Zarek", "Anwen", "Bartholomew", "Cerys", "Dorian",
    "Edda", "Fiora", "Bram", "Halvar", "Isolde", "Joren", "Kestrel", "Liora", "Magnus", "Nerys",
}

local CLASS_CYCLE = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local HEALERS = { PRIEST = true, PALADIN = true, DRUID = true, SHAMAN = true }

-- The first ten show every case (a 10-player preview already has them all); 23 and 37 are more "worst case" players.
-- buffs: ok | miss | end | multi (miss + ending + miss); deb = how many dispellable debuffs; hp = fraction.
local SPECIAL = {
    [1] = { me = true, role = "HEALER", hp = 1, buffs = "ok" },
    [2] = { class = "WARRIOR", role = "TANK", hp = 0.55, aggro = true, deb = 1, buffs = "end" },
    [3] = { class = "PRIEST", role = "HEALER", hp = 0.8, incoming = 0.12, buffs = "miss" },
    [4] = { class = "ROGUE", state = "dead", buffs = "miss" },
    [5] = { class = "MAGE", hp = 0.7, range = "out", buffs = "ok" },
    [6] = { class = "HUNTER", hp = 1, target = true, buffs = "miss" },
    [7] = { class = "WARLOCK", state = "offline", buffs = "ok" },
    [8] = { class = "DRUID", role = "HEALER", range = "hidden", buffs = "ok" },
    [9] = { class = "SHAMAN", hp = 0.25, aggro = true, incoming = 0.2, deb = 3, buffs = "multi" },
    [10] = { class = "PALADIN", role = "TANK", hp = 0.92, buffs = "end" },
    [18] = { range = "out", hp = 0.6 },
    [23] = { class = "WARRIOR", role = "TANK", hp = 0.2, aggro = true, deb = 3, buffs = "multi" },
    [27] = { state = "offline" },
    [31] = { state = "dead" },
    [34] = { state = "ghost" },
    [37] = { class = "PRIEST", role = "HEALER", hp = 0.35, deb = 2, buffs = "multi", incoming = 0.3 },
}

local function playerClass()
    local class = ns.PlayerClass and ns.PlayerClass()
    if ns.issecret(class) or type(class) ~= "string" then return "PALADIN" end
    return class
end

-- Spec of member i (plain values only).
function RP.MemberSpec(i)
    local s = {}
    for k, v in pairs(SPECIAL[i] or {}) do s[k] = v end
    if not s.class then s.class = s.me and playerClass() or CLASS_CYCLE[(i * 4) % #CLASS_CYCLE + 1] end
    if not s.role then
        if s.class == "WARRIOR" and i % 10 == 2 then s.role = "TANK"
        elseif HEALERS[s.class] and i % 3 == 0 then s.role = "HEALER"
        else s.role = "DAMAGER" end
    end
    if not s.hp then
        if i % 7 == 0 then s.hp = 0.35 elseif i % 4 == 0 then s.hp = 0.62 elseif i % 5 == 0 then s.hp = 0.88 else s.hp = 1 end
    end
    if not s.buffs then
        if i % 6 == 0 then s.buffs = "miss" elseif i % 11 == 0 then s.buffs = "end" else s.buffs = "ok" end
    end
    if not s.deb and i % 9 == 0 then s.deb = 1 end
    s.group = math.ceil(i / 5)
    s.name = RP.NAMES[i] or ("Raider" .. i)
    s.maxHp = (s.role == "TANK" and 9000 or 4000) + (i * 137) % 1500
    return s
end

-- My buffs of the fake member as a BuffReport (the same shape BuffButtons.EvaluateUnit returns).
local function buffReport(pattern, catalog, percent)
    local report = {}
    if #catalog == 0 then return report end
    local function item(key, kind)
        local def = ns.Classes.BUFFS[key]
        local name = def and def.name or key
        if kind == "miss" then return { key = key, missing = true } end
        if kind == "end" then
            local pct = math.max(0.5, percent * 0.6)
            return { key = key, missing = true, auraName = name, remaining = BUFF_DURATION * pct / 100, pct = pct,
                duration = BUFF_DURATION }
        end
        return { key = key, missing = false, auraName = name, remaining = BUFF_DURATION * 0.6, pct = 60,
            duration = BUFF_DURATION }
    end
    if pattern == "multi" then
        local kinds = { "miss", "end", "miss" }
        for k = 1, math.min(3, #catalog) do report[#report + 1] = item(catalog[k], kinds[k]) end
    else
        report[1] = item(catalog[1], pattern)
    end
    return report
end

-- RaidLayout markers -> RaidStyle marker data (icon, colour state, count, sweep window), like RaidFrames does.
local function markerData(report, b, now)
    local BB = ns.BuffButtons
    local out = {}
    for i, m in ipairs(RL().BuffMarkers(report, b.multi, b.showEnding)) do
        local def = ns.Classes.BUFFS[m.key]
        local icon = (BB and BB.IconFor and BB.IconFor(def and def.name, def)) or (def and def.icon) or nil
        local d = { kind = m.kind, key = m.key, count = m.count, icon = icon }
        if m.kind == "end" then
            local dur = RL().ItemDuration(m.item)
            if dur and b.rebuffPercent > 0 then
                d.window = dur * b.rebuffPercent / 100
                d.start = now + m.item.remaining - d.window
            end
        end
        out[i] = d
    end
    return out
end

-- Plain RS.Render data for member i plus its tooltip meta. Exposed for the options legend sample and the tests.
function RP.FakeData(i, c)
    c = c or cfg()
    local s = RP.MemberSpec(i)
    local class = playerClass()
    local catalog = ns.Classes.CatalogBuffs(class)
    local dispels = (ns.Classes.DATA[class] or {}).dispels or {}
    local report = buffReport(s.buffs, catalog, c.buffs.rebuffPercent)
    local now = GetTime and GetTime() or 0
    local debuffs = {}
    for k = 1, math.min(s.deb or 0, #dispels) do debuffs[k] = dispels[k] end
    local hp = math.floor(s.maxHp * s.hp + 0.5)
    local data = {
        name = s.name, class = s.class, me = s.me, hp = hp, maxHp = s.maxHp,
        incoming = s.incoming and math.floor(s.maxHp * s.incoming + 0.5) or 0,
        state = s.state or "alive", range = s.range or "in", target = s.target, aggro = s.aggro, combat = false,
        buffs = markerData(report, c.buffs, now), debuffs = debuffs,
    }
    return data, { spec = s, report = report }
end

-- Frames --------------------------------------------------------------------------------------------------------------

local function showTooltip(frame)
    if not GameTooltip then return end
    local data, meta = RP.data[frame.previewIndex], RP.meta[frame.previewIndex]
    if not data or not meta then return end
    local s = meta.spec
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    local col = ns.Classes.GetColor(s.class)
    GameTooltip:AddLine(data.name .. (data.me and " (you)" or ""), col.r, col.g, col.b)
    local roleLabel = ns.Classes.ROLE_LABELS[s.role] or s.role
    GameTooltip:AddLine((ns.Classes.NAMES[s.class] or s.class) .. " \194\183 " .. roleLabel .. " \194\183 Group " .. s.group,
        0.8, 0.8, 0.8)
    if data.state == "alive" then
        GameTooltip:AddLine(data.hp .. " / " .. data.maxHp, 1, 1, 1)
    else
        GameTooltip:AddLine(RS().STATE_TEXT[data.state] or data.state, 0.88, 0.25, 0.25)
    end
    if data.range == "out" then GameTooltip:AddLine("Out of range", 0.6, 0.6, 0.6) end
    if data.range == "hidden" then GameTooltip:AddLine("Not visible", 0.54, 0.65, 0.78) end
    if data.aggro then GameTooltip:AddLine("Has aggro", 1, 0.31, 0.31) end
    if data.target then GameTooltip:AddLine("Your target", 1, 1, 1) end
    for _, item in ipairs(meta.report) do
        local def = ns.Classes.BUFFS[item.key]
        local name = def and def.name or item.key
        local state = RL().BuffItemState(item)
        if state == "miss" then
            GameTooltip:AddLine(name .. ": missing", 1, 0.82, 0)
        elseif state == "end" then
            GameTooltip:AddLine(name .. ": ending", 1, 0.54, 0.1)
        end
    end
    for _, t in ipairs(data.debuffs or {}) do
        local dc = ns.Classes.DISPEL_COLORS[t]
        GameTooltip:AddLine(t .. " debuff (you can dispel)", dc and dc.r or 1, dc and dc.g or 1, dc and dc.b or 1)
    end
    GameTooltip:AddLine("Preview: fake player, clicks do nothing", 1, 0.69, 0.44)
    GameTooltip:Show()
end

local function createFrame(i)
    local f = ns.NewFrame("Frame", nil, RP.anchor)
    f.previewIndex = i
    f.isPreview = true
    -- the mouse is only for the fake tooltip; a plain Frame has no click action
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self) RP.hovered = self; showTooltip(self) end)
    f:SetScript("OnLeave", function(self)
        if RP.hovered == self then RP.hovered = nil end
        if GameTooltip then GameTooltip:Hide() end
    end)
    RS().Build(f)
    f:Hide()
    RP.frames[i] = f
    return f
end

local function lockedText()
    local locked = ns.db and ns.db.frames and ns.db.frames.locked
    return locked and RP.TAG_TEXT or (RP.TAG_TEXT .. " \194\183 drag to move")
end

local function savePoint()
    local anchor = RP.anchor
    local point, _, relativePoint, x, y = anchor:GetPoint()
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then return end
    local p = cfg().point
    p.point, p.relativePoint, p.x, p.y = point, relativePoint or point, x, y
    -- the real raid anchor (parent of secure buttons) follows out of combat
    ns:AfterCombat("rf-point", function()
        if ns.RaidFrames and ns.RaidFrames.ApplyPoint then ns.RaidFrames:ApplyPoint() end
    end, true)
end

local function createAnchor()
    local anchor = ns.NewFrame("Frame", "HealerForeverRaidPreview", UIParent)
    anchor:SetSize(200, 50)
    anchor:SetFrameStrata("MEDIUM")
    -- above the real raid anchor ("Always raid" outside a raid shows real bars at the same position)
    local base = (ns.RaidFrames and ns.RaidFrames.anchor and ns.RaidFrames.anchor:GetFrameLevel()) or 1
    anchor:SetFrameLevel(base + 30)
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    anchor:Hide()
    RP.anchor = anchor

    -- solid gold tag above the raid; with unlocked frames it is the drag handle
    local tag = ns.NewFrame("Button", nil, anchor)
    tag:SetHeight(16)
    tag:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
    tag.bg = tag:CreateTexture(nil, "BACKGROUND")
    tag.bg:SetAllPoints()
    tag.bg:SetTexture(WHITE)
    tag.bg:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
    tag.text = tag:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tag.text:SetPoint("LEFT", 6, 0)
    tag.text:SetTextColor(0, 0, 0, 1)
    tag.text:SetWordWrap(false)
    tag:RegisterForDrag("LeftButton")
    tag:SetScript("OnDragStart", function()
        if ns.InCombat() or (ns.db and ns.db.frames.locked) then return end
        RP.dragging = true
        anchor:StartMoving()
    end)
    tag:SetScript("OnDragStop", function()
        if not RP.dragging then return end
        RP.dragging = nil
        anchor:StopMovingOrSizing()
        savePoint()
    end)
    RP.tag = tag

    RP.labels = {}
    for g = 1, RL().NUM_GROUPS do
        local fs = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetText("G" .. g)
        fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        fs:Hide()
        RP.labels[g] = fs
    end
end

function RP:Ensure()
    if RP.anchor then return end
    createAnchor()
    for i = 1, RL().NUM_BUTTONS do createFrame(i) end
end

function RP:UpdateTag()
    if not RP.tag then return end
    local tag = RP.tag
    tag.text:SetText(lockedText())
    local textW = tag.text:GetStringWidth()
    if type(textW) ~= "number" then textW = 200 end
    local w = RP.anchor:GetWidth()
    if type(w) ~= "number" then w = 0 end
    tag:SetWidth(math.max(w, textW + 12))
end

local function placeLabels(plan, c)
    for g = 1, RL().NUM_GROUPS do
        local fs = RP.labels[g]
        local spot = plan.grid.labels[g]
        fs:ClearAllPoints()
        if c.groupLabels and spot and spot.shown then
            if c.groupArrange == "rows" then
                fs:SetPoint("LEFT", RP.anchor, "TOPLEFT", spot.x, -(spot.y + c.height / 2))
            else
                fs:SetPoint("TOPLEFT", RP.anchor, "TOPLEFT", spot.x, -spot.y)
            end
            fs:Show()
        else
            fs:Hide()
        end
    end
end

-- Lays out and paints the fake raid with the current settings (live on CONFIG_CHANGED "raid").
function RP:Refresh()
    if not RP.on or not RP.anchor then return end
    local c = cfg()
    if not c then return end
    local n = RP.size
    local roster = {}
    RP.data, RP.meta = {}, {}
    for i = 1, n do
        local data, meta = RP.FakeData(i, c)
        RP.data[i], RP.meta[i] = data, meta
        roster[#roster + 1] = { index = i, group = meta.spec.group, role = meta.spec.role, class = meta.spec.class }
    end
    local plan = RL().AssignCells(roster, c)
    RP.plan = plan
    local p = c.point
    local anchor = RP.anchor
    if not RP.dragging then
        anchor:ClearAllPoints()
        anchor:SetPoint(p.point, UIParent, p.relativePoint, p.x, p.y)
    end
    anchor:SetScale(c.scale / 100)
    anchor:SetSize(math.max(1, plan.grid.width), math.max(1, plan.grid.height))
    for i, f in ipairs(RP.frames) do
        local cell = plan.byButton[i]
        if i <= n and cell then
            RS().Apply(f, c)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", anchor, "TOPLEFT", cell.x, -cell.y)
            f.raidGroup = cell.group
            RS().Render(f, RP.data[i], c)
            f:Show()
        else
            f:Hide()
        end
    end
    placeLabels(plan, c)
    RP:UpdateTag()
    if RP.hovered and RP.hovered:IsShown() then showTooltip(RP.hovered) end
end

local function validSize(size)
    size = tonumber(size)
    for _, s in ipairs(RP.SIZES) do
        if s == size then return s end
    end
    return nil
end
RP.ValidSize = validSize

local function changed()
    ns:Fire("RAID_PREVIEW_CHANGED", RP.on)
end

-- Turns the preview on / off. size = 10 | 20 | 25 | 40 (optional). Returns ok, message.
function RP:SetOn(on, size)
    local s = validSize(size)
    if s then RP.size = s end
    if not on then
        local was = RP.on
        RP.on = false
        RP.message = nil
        if RP.anchor then RP.anchor:Hide() end
        if RP.hovered and GameTooltip then GameTooltip:Hide() end
        RP.hovered, RP.dragging = nil, nil
        if was then changed() end
        return true
    end
    if ns.InCombat() then
        RP.message = RP.MSG_COMBAT
        changed()
        return false, RP.message
    end
    if ns.InRaid() then
        RP.message = RP.MSG_RAID
        changed()
        return false, RP.message
    end
    if not ns.db then return false, "not loaded yet" end
    RP:Ensure()
    RP.on = true
    RP.message = nil
    RP:Refresh()
    RP.anchor:Show()
    changed()
    return true
end

function RP:Toggle(size)
    if RP.on and not validSize(size) then return RP:SetOn(false) end
    return RP:SetOn(true, size)
end

-- Preview size (also while off: it is used the next time the preview turns on).
function RP:SetSize(size)
    local s = validSize(size)
    if not s then return false end
    RP.size = s
    if RP.on then RP:Refresh() end
    changed()
    return true
end

function RP:IsOn() return RP.on end

-- Automatic off with a reason (combat started, joined a raid): one chat line, the reason stays in the options pane.
function RP:AutoOff(reason)
    if not RP.on then return end
    RP:SetOn(false)
    RP.message = reason
    ns:Print(reason)
    changed()
end

ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
    RP:AutoOff(RP.MSG_OFF_COMBAT)
end)
ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
    if RP.on and ns.InRaid() then RP:AutoOff(RP.MSG_OFF_RAID) end
end)
ns:On("CONFIG_CHANGED", function(group)
    if not RP.on then return end
    if group == "raid" or group == "all" or group == "presets" then
        RP:Refresh()
    elseif group == "frames" then
        RP:UpdateTag()
    end
end)
ns:On("LOCK_CHANGED", function() RP:UpdateTag() end)
