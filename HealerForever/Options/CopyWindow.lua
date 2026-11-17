local ADDON_NAME, ns = ...

-- A small movable window with a multi-line, scrollable EditBox holding the last debug output and the error log, with
-- the text pre-selected so Cmd+A / Cmd+C works (WoW chat text cannot be copied). Non-secure, closed with X or ESC.
local CW = {}
ns.CopyWindow = CW

local function create()
    local f = ns.NewFrame("Frame", "HealerForeverCopyFrame", UIParent, "BackdropTemplate")
    f:SetSize(640, 440)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame) frame:StopMovingOrSizing() end)
    f:SetBackdrop(ns.UI.BACKDROP)
    f:SetBackdropColor(0, 0, 0, 0.95)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 14, -12)
    f.title:SetText("Healer Forever - select all (Cmd/Ctrl+A) and copy (Cmd/Ctrl+C)")

    f.close = ns.NewFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -2, -2)

    f.scroll = ns.NewFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", 14, -36)
    f.scroll:SetPoint("BOTTOMRIGHT", -34, 14)

    f.edit = ns.NewFrame("EditBox", nil, f.scroll)
    f.edit:SetMultiLine(true)
    f.edit:SetAutoFocus(false)
    f.edit:SetFontObject(ChatFontNormal or GameFontHighlight)
    f.edit:SetWidth(580)
    f.edit:SetHeight(400)
    f.edit:SetScript("OnEscapePressed", function() f:Hide() end)
    -- the text is for copying: typed changes are reverted
    f.edit:SetScript("OnTextChanged", function(edit, userInput)
        if userInput and f.text then
            edit:SetText(f.text)
            edit:HighlightText()
        end
    end)
    f.scroll:SetScrollChild(f.edit)

    f:SetScript("OnShow", function()
        local function select()
            f.edit:SetFocus()
            f.edit:HighlightText()
        end
        if C_Timer and C_Timer.After then C_Timer.After(0, select) else select() end
    end)
    if UISpecialFrames then table.insert(UISpecialFrames, "HealerForeverCopyFrame") end
    f:Hide()
    return f
end

local DEFAULT_TITLE = "Healer Forever - select all (Cmd/Ctrl+A) and copy (Cmd/Ctrl+C)"

function CW:SetText(text)
    CW.frame = CW.frame or create()
    CW.frame.text = text
    CW.frame.edit:SetText(text)
    CW.frame.edit:HighlightText()
end

function CW:ShowText(text, title)
    CW.frame = CW.frame or create()
    CW.frame.title:SetText(title or DEFAULT_TITLE)
    CW:SetText(text)
    CW.frame:Show()
end

function CW:Show()
    CW.frame = CW.frame or create()
    CW.frame.title:SetText(DEFAULT_TITLE)
    CW:SetText(ns.CopyText())
    CW.frame:Show()
end
