local ADDON_NAME, ns = ...

local UI, Options = ns.UI, ns.Options

Options:RegisterPane("help", "Help & Contact", 8, function(outer)
    local scroll = ns.NewFrame("ScrollFrame", nil, outer, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)
    local pane = ns.NewFrame("Frame", nil, scroll)
    pane:SetSize(560, 1100)
    scroll:SetScrollChild(pane)
    UI.Header(pane, "Help & Contact")
    local lead = UI.Label(pane, "Problems or ideas? Write to:")
    lead:SetPoint("TOPLEFT", 0, -40)

    local email = ns.Report.EMAIL
    local box = ns.NewFrame("EditBox", nil, pane, "InputBoxTemplate")
    box:SetSize(300, 22)
    box:SetPoint("TOPLEFT", 6, -62)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal or GameFontHighlight)
    box:SetText(email)
    box:SetCursorPosition(0)
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self:GetText() ~= email then
            self:SetText(email)
            self:HighlightText()
        end
    end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnMouseUp", function(self) self:SetFocus(); self:HighlightText() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local copy = UI.Button(pane, "Copy", 70, function()
        box:SetFocus()
        box:HighlightText()
    end)
    copy:SetPoint("LEFT", box, "RIGHT", 10, 0)
    local hint = UI.Label(pane, "then press Cmd/Ctrl+C", "GameFontDisableSmall")
    hint:SetPoint("LEFT", copy, "RIGHT", 10, 0)

    local report = UI.Button(pane, "Report a problem", 150, function() ns.Report.Show() end)
    report:SetPoint("TOPLEFT", 0, -102)
    local reportHint = UI.Label(pane, "Opens a copy window with your version, class, client info, recent errors and debug output.", "GameFontDisableSmall")
    reportHint:SetPoint("TOPLEFT", report, "BOTTOMLEFT", 0, -4)
    reportHint:SetWidth(540)
    reportHint:SetWordWrap(true)

    local head = UI.Label(pane, "How to report", "GameFontNormal")
    head:SetPoint("TOPLEFT", 0, -170)
    local steps = UI.Label(pane,
        "- What you did right before it happened\n" ..
        "- When it happened (in combat, on login, on reload)\n" ..
        "- A screenshot if it is visual\n" ..
        "- The report text (Report a problem), pasted into the email\n" ..
        "Tip: /hf mark [note] saves a snapshot of the moment; it is included in the report.", "GameFontHighlight")
    steps:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -6)
    steps:SetWidth(540)
    steps:SetWordWrap(true)

    local license = UI.Label(pane, "Copyright (c) 2026 trtg. All rights reserved. See LICENSE.txt", "GameFontDisableSmall")
    license:SetPoint("TOPLEFT", steps, "BOTTOMLEFT", 0, -14)

    local function block(title, body, anchor)
        local h = UI.Label(pane, title, "GameFontNormal")
        h:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -18)
        local t = UI.Label(pane, body, "GameFontHighlight")
        t:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -6)
        t:SetWidth(540)
        t:SetWordWrap(true)
        return t
    end
    local lines = {}
    for _, c in ipairs(ns.SLASH_COMMANDS) do lines[#lines + 1] = c.cmd .. "  -  " .. c.desc end
    local commands = block("Commands & Tips: commands", table.concat(lines, "\n"), license)
    local keys = block("Keybindings", "Esc > Options > Keybindings > Healer Forever: Smart buff, Tank buff", commands)
    local quick = block("Quick start", table.concat({
        "1. Click-Casting: bind a spell to each mouse button and modifier (Shift, Ctrl, Alt, Cmd).",
        "2. Buff Presets: pick the buffs per target class and role; \"Load example\" adds a ready-made preset.",
        "3. Role buffs: assign a buff to a role only, for example a tank-only buff.",
    }, "\n"), keys)
    block("Good to know", table.concat({
        "- In combat the game draws the buff and debuff icons itself, so they update live.",
        "- Addons can't detect line of sight; range shows distance only.",
        "- Settings are saved on /reload or logout.",
        "- Casts never fall back to you: a click on a member only ever targets that member.",
    }, "\n"), quick)
end)
