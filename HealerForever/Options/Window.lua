local ADDON_NAME, ns = ...

local Options = { panes = {} }
ns.Options = Options

local UI = ns.UI
local WIDTH, HEIGHT = 880, 620
local NAV_WIDTH = 150

-- Vertical placement helper: returns add(widget, indent, height).
function Options.Stack(parent, startY, gap)
    local y = startY or 0
    gap = gap or 6
    return function(widget, indent, height)
        widget:ClearAllPoints()
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", indent or 0, y)
        y = y - (height or widget:GetHeight() or 24) - gap
        return widget
    end, function() return y end
end

function Options:RegisterPane(key, label, order, build)
    self.panes[#self.panes + 1] = { key = key, label = label, order = order, build = build }
    table.sort(self.panes, function(a, b) return a.order < b.order end)
end

function Options:SelectPane(key)
    if not self.frame then return end
    for _, pane in ipairs(self.panes) do
        local active = pane.key == key
        if active and not pane.frame then
            pane.frame = ns.NewFrame("Frame", nil, self.content)
            pane.frame:SetAllPoints()
            pane.build(pane.frame)
        end
        if pane.frame then pane.frame:SetShown(active) end
        if pane.navButton then
            pane.navButton.selected:SetShown(active)
        end
        if active and pane.frame.Refresh then pane.frame:Refresh() end
    end
    self.current = key
end

function Options:Refresh()
    if not self.frame or not self.frame:IsShown() then return end
    for _, pane in ipairs(self.panes) do
        if pane.frame and pane.frame:IsShown() and pane.frame.Refresh then pane.frame:Refresh() end
    end
end

function Options:Create()
    if self.frame then return end
    local f = ns.NewFrame("Frame", "HealerForeverOptions", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetTitle then
        f:SetTitle("Healer Forever " .. (ns.AddonVersion() == "dev" and "(dev)" or "v" .. ns.AddonVersion()))
    else
        local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("TOP", 0, -6)
        t:SetText("Healer Forever " .. (ns.AddonVersion() == "dev" and "(dev)" or "v" .. ns.AddonVersion()))
    end
    local class = ns.PlayerClass()
    if class then
        local c = ns.Classes.GetColor(class)
        local tag = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tag:SetPoint("TOPLEFT", 10, -6)
        tag:SetTextColor(c.r, c.g, c.b)
        tag:SetText((ns.Classes.NAMES[class] or class) .. " detected")
    end
    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 12, 6)
    footer:SetText("Settings are saved on /reload or logout")
    local contact = ns.NewFrame("Button", nil, f)
    contact.text = contact:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    contact.text:SetPoint("RIGHT")
    contact.text:SetText("\194\183 Contact")
    contact:SetSize(math.max(50, (contact.text:GetStringWidth() or 0) + 4), 14)
    contact:SetPoint("BOTTOMRIGHT", -12, 6)
    contact:SetScript("OnClick", function() Options:Show("help") end)
    contact:SetScript("OnEnter", function(btn) btn.text:SetTextColor(1, 1, 1) end)
    contact:SetScript("OnLeave", function(btn) btn.text:SetTextColor(1, 0.82, 0) end)
    local versionLine = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    versionLine:SetPoint("BOTTOMRIGHT", contact, "BOTTOMLEFT", -4, 0)
    versionLine:SetText("Healer Forever " .. (ns.AddonVersion() == "dev" and "dev" or "v" .. ns.AddonVersion())
        .. " \194\183 settings v" .. ns.SchemaVersion() .. " \194\183 by trtg")
    if UISpecialFrames then table.insert(UISpecialFrames, "HealerForeverOptions") end
    -- The template's X button routes through HideUIPanel/onCloseCallback, which does nothing for a window that isn't
    -- a registered UI panel. Close it ourselves and keep the button above the window's children.
    f.onCloseCallback = function() f:Hide() end
    local closeButton = f.CloseButton or (f.GetName and f:GetName() and _G[f:GetName() .. "CloseButton"])
    if closeButton then
        closeButton:SetScript("OnClick", function() f:Hide() end)
        if closeButton.SetFrameLevel and f.GetFrameLevel then closeButton:SetFrameLevel(f:GetFrameLevel() + 20) end
    end
    f:Hide()

    local nav = ns.NewFrame("Frame", nil, f)
    nav:SetPoint("TOPLEFT", 10, -30)
    nav:SetPoint("BOTTOMLEFT", 10, 10)
    nav:SetWidth(NAV_WIDTH)
    for i, pane in ipairs(self.panes) do
        local b = ns.NewFrame("Button", nil, nav)
        b:SetSize(NAV_WIDTH, 26)
        b:SetPoint("TOPLEFT", 0, -(i - 1) * 28)
        b.text = b:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        b.text:SetPoint("LEFT", 8, 0)
        b.text:SetText(pane.label)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\WHITE8X8")
        hl:SetVertexColor(1, 1, 1, 0.08)
        b.selected = b:CreateTexture(nil, "BACKGROUND")
        b.selected:SetAllPoints()
        b.selected:SetTexture("Interface\\Buttons\\WHITE8X8")
        b.selected:SetVertexColor(1, 0.82, 0, 0.18)
        b.selected:Hide()
        b:SetScript("OnClick", function() Options:SelectPane(pane.key) end)
        pane.navButton = b
    end

    local content = ns.NewFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", NAV_WIDTH + 30, -42)
    content:SetPoint("BOTTOMRIGHT", -22, 18)
    self.content = content
    self.frame = f
    f:SetScript("OnShow", function() Options:Refresh() end)
    self:SelectPane(self.current or self.panes[1].key)
end

function Options:Show(paneKey)
    self:Create()
    self.frame:Show()
    if paneKey then self:SelectPane(paneKey) end
end

function Options:Toggle()
    self:Create()
    if self.frame:IsShown() then self.frame:Hide() else self.frame:Show() end
end

local function registerSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    local panel = ns.NewFrame("Frame")
    panel.name = "Healer Forever"
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Healer Forever")
    local btn = UI.Button(panel, "Open Healer Forever options", 220, function()
        Options:Show()
    end)
    btn:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
    local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, panel.name)
    if ok and category then
        pcall(Settings.RegisterAddOnCategory, category)
    end
end

ns:RegisterEvent("PLAYER_LOGIN", registerSettingsPanel)
ns:On("CONFIG_CHANGED", function() Options:Refresh() end)
