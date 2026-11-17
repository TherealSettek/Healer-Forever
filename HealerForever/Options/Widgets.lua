local ADDON_NAME, ns = ...

-- Small widget toolkit with no dependency on Blizzard dropdown/slider templates.
local UI = {}
ns.UI = UI

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
UI.BACKDROP = BACKDROP

local WHITE = "Interface\\Buttons\\WHITE8X8"
local POPUP_ROWS = 14
local POPUP_ROW_HEIGHT = 20

function UI.Label(parent, text, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

function UI.Header(parent, title, hint, y)
    local h = UI.Label(parent, title, "GameFontNormalLarge")
    h:SetPoint("TOPLEFT", 0, y or 0)
    local last = h
    if hint then
        local fs = UI.Label(parent, hint, "GameFontDisable")
        fs:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
        fs:SetWidth(540)
        fs:SetWordWrap(true)
        last = fs
    end
    return h, last
end

function UI.Button(parent, text, width, onClick)
    local b = ns.NewFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 120, 22)
    b:SetText(text)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

function UI.Checkbox(parent, label, get, set)
    local cb = ns.NewFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local fs = cb.Text or cb.text
    if not fs then
        fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    end
    fs:SetText(label)
    cb.label = fs
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
    end)
    function cb:Refresh() self:SetChecked(get() and true or false) end
    cb:Refresh()
    return cb
end

function UI.Slider(parent, label, minV, maxV, step, get, set, width)
    local f = ns.NewFrame("Frame", nil, parent)
    f:SetSize((width or 200) + 130, 24)
    f.label = UI.Label(f, label)
    f.label:SetPoint("LEFT", 0, 0)
    f.label:SetWidth(130)
    local s = ns.NewFrame("Slider", nil, f, "BackdropTemplate")
    s:SetOrientation("HORIZONTAL")
    s:SetSize(width or 200, 12)
    s:SetPoint("LEFT", 134, 0)
    s:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Buttons\\UI-SliderBar-Border", edgeSize = 6,
        insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    s:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    f.value = UI.Label(f, "", "GameFontNormal")
    f.value:SetPoint("LEFT", s, "RIGHT", 8, 0)
    local updating = false
    s:SetScript("OnValueChanged", function(_, v)
        f.value:SetText(tostring(v))
        if not updating then set(v) end
    end)
    function f:Refresh()
        updating = true
        s:SetValue(get())
        f.value:SetText(tostring(get()))
        updating = false
    end
    f.slider = s
    f:Refresh()
    return f
end

function UI.EditBox(parent, width, onEnter)
    local e = ns.NewFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width or 160, 20)
    e:SetAutoFocus(false)
    e:SetScript("OnEnterPressed", function(self) onEnter(self:GetText()); self:ClearFocus() end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

-- Popup list (shared) --------------------------------------------------------------

local popup

local function ensurePopup()
    if popup then return popup end
    popup = ns.NewFrame("Frame", "HealerForeverPopupList", UIParent, "BackdropTemplate")
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetBackdrop(BACKDROP)
    popup:SetBackdropColor(0, 0, 0, 0.95)
    popup:SetClampedToScreen(true)
    popup:EnableMouseWheel(true)
    popup:Hide()
    popup.rows = {}
    popup.offset = 0

    local catcher = ns.NewFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", function() popup:Hide() end)
    catcher:Hide()
    popup.catcher = catcher
    popup:SetScript("OnShow", function() catcher:Show() end)
    popup:SetScript("OnHide", function() catcher:Hide() end)

    for i = 1, POPUP_ROWS do
        local row = ns.NewFrame("Button", nil, popup)
        row:SetHeight(POPUP_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * POPUP_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -6, -6 - (i - 1) * POPUP_ROW_HEIGHT)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 2, 0)
        row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.text:SetJustifyH("LEFT")
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(WHITE)
        hl:SetVertexColor(1, 0.82, 0, 0.2)
        row:SetScript("OnClick", function(self)
            local item, cb = self.item, popup.callback
            popup:Hide()
            if item and cb then cb(item) end
        end)
        popup.rows[i] = row
    end

    local function render()
        local items = popup.items
        for i = 1, POPUP_ROWS do
            local item = items[i + popup.offset]
            local row = popup.rows[i]
            if item then
                row.item = item
                row.text:SetText(item.text)
                if item.icon then
                    row.icon:SetTexture(item.icon)
                    row.icon:Show()
                    row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
                else
                    row.icon:Hide()
                    row.text:SetPoint("LEFT", 4, 0)
                end
                row:Show()
            else
                row.item = nil
                row:Hide()
            end
        end
    end
    popup.render = render
    popup:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #popup.items - POPUP_ROWS)
        popup.offset = math.max(0, math.min(maxOffset, popup.offset - delta * 3))
        render()
    end)
    return popup
end

-- items: array of { text=, value=, icon= }; callback(item)
function UI.ShowPopup(anchor, items, callback, width)
    local p = ensurePopup()
    p.items = items
    p.callback = callback
    p.offset = 0
    p:SetWidth(width or 220)
    p:SetHeight(12 + math.min(#items, POPUP_ROWS) * POPUP_ROW_HEIGHT)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    p.render()
    p:Show()
end

-- Context menu using the modern MenuUtil when available, else the custom popup list.
-- items: array of { text=, value=, icon= }; callback(item)
function UI.ShowMenu(anchor, items, callback, width)
    if MenuUtil and MenuUtil.CreateContextMenu then
        local ok = pcall(MenuUtil.CreateContextMenu, anchor, function(_, root)
            if #items > 14 and root.SetScrollMode then pcall(root.SetScrollMode, root, 14 * 20) end
            for _, item in ipairs(items) do
                root:CreateButton(item.text, function() callback(item) end)
            end
        end)
        if ok then return end
    end
    UI.ShowPopup(anchor, items, callback, width)
end

function UI.Dropdown(parent, width, getItems, get, set, useMenu)
    local b = ns.NewFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width or 180, 22)
    b:SetBackdrop(BACKDROP)
    b:SetBackdropColor(0, 0, 0, 0.8)
    b.text = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 8, 0)
    b.text:SetPoint("RIGHT", -18, 0)
    b.text:SetJustifyH("LEFT")
    local arrow = b:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(16, 16)
    arrow:SetPoint("RIGHT", -2, 0)
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    function b:Refresh()
        local current = get()
        local label = tostring(current)
        for _, item in ipairs(getItems()) do
            if item.value == current then label = item.text end
        end
        self.text:SetText(label)
    end
    b:SetScript("OnClick", function(self)
        local show = useMenu and UI.ShowMenu or UI.ShowPopup
        show(self, getItems(), function(item)
            set(item.value)
            self:Refresh()
        end, width)
    end)
    b:Refresh()
    return b
end

function UI.ColorSwatch(parent, get, set)
    local b = ns.NewFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(22, 22)
    b:SetBackdrop(BACKDROP)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetPoint("TOPLEFT", 4, -4)
    b.tex:SetPoint("BOTTOMRIGHT", -4, 4)
    b.tex:SetTexture(WHITE)
    function b:Refresh()
        local c = get()
        self.tex:SetVertexColor(c.r, c.g, c.b)
    end
    b:SetScript("OnClick", function()
        local c = get()
        local function apply()
            local r, g, bl = ColorPickerFrame:GetColorRGB()
            set({ r = r, g = g, b = bl })
            b:Refresh()
        end
        -- only the modern API: the old fallback wrote fields on Blizzard's frame (taint)
        if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = c.r, g = c.g, b = c.b, hasOpacity = false,
                swatchFunc = apply, cancelFunc = function() set(c); b:Refresh() end,
            })
        end
    end)
    b:Refresh()
    return b
end
