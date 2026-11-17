local ADDON_NAME, ns = ...

local UI, Options = ns.UI, ns.Options
local Bindings, Util = ns.Bindings, ns.Util

local ROW_HEIGHT = 30
local SUMMARY_WIDTH = 520

local function cursorSpell()
    if not GetCursorInfo then return nil end
    local kind, slot, bank, spellID = GetCursorInfo()
    if kind ~= "spell" then return nil end
    -- the documented return is the spellID; slot/bank are only used for the spellbook lookup
    if type(spellID) ~= "number" and slot and bank and C_SpellBook and C_SpellBook.GetSpellBookItemInfo then
        local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, slot, bank)
        if ok and info then spellID = info.spellID end
    end
    if type(spellID) == "number" and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name then return info.name end
    end
    return nil
end

ns.CursorSpellName = cursorSpell

local function actionText(action)
    if action.type == "spell" then return action.spell end
    if action.type == "target" then return "Target unit" end
    if action.type == "menu" then return "Unit menu" end
    return "Macro"
end

local function assign(key, action)
    if action and action.type == "menu" and key ~= "|2" then
        ns:Print("Unit menu can only be bound to plain Right-click.")
        return
    end
    if action then ns.db.bindings[key] = action else ns.db.bindings[key] = nil end
    ns:Changed("bindings")
end

local function modifierNames()
    if ns.IsMac() then
        -- plain text only: WoW's default fonts may not contain the key glyphs
        return { shift = "Shift", ctrl = "Ctrl", alt = "Option", meta = "Cmd" }
    end
    return { shift = "Shift", ctrl = "Ctrl", alt = "Alt", meta = "Win key (not recommended)" }
end

Options:RegisterPane("binds", "Click-Casting", 4, function(pane)
    UI.Header(pane, "Click-Casting",
        "Toggle modifiers, then set what each mouse button casts. Drag a spell onto a row, or use the Pick button.")

    local mods = { shift = false, ctrl = false, alt = false, meta = false }
    local names = modifierNames()
    local toggles = {}
    local editing = UI.Label(pane, "", "GameFontNormal")
    editing:SetPoint("TOPLEFT", 0, -96)

    local function currentMod()
        return Util.ModifierKey(mods.shift, mods.ctrl, mods.alt, mods.meta)
    end

    local x = 0
    for _, m in ipairs({ "shift", "ctrl", "alt", "meta" }) do
        local b = ns.NewFrame("Button", nil, pane, "BackdropTemplate")
        local winKey = m == "meta" and not ns.IsMac()
        b.dimmed = winKey
        b:SetSize(winKey and 170 or 100, 24)
        b:SetPoint("TOPLEFT", x, -64)
        b:SetBackdrop(UI.BACKDROP)
        b.text = b:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        b.text:SetPoint("CENTER")
        b.text:SetText(names[m])
        if winKey then
            -- still toggleable, but visually de-emphasised, with an explanation on hover
            b.text:SetTextColor(0.55, 0.55, 0.55)
            b:SetScript("OnEnter", function(btn)
                GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
                GameTooltip:AddLine("The Windows key usually opens the Start menu and leaves the game. Use Shift, Ctrl or Alt instead.", 1, 0.82, 0, true)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        b:SetScript("OnClick", function()
            mods[m] = not mods[m]
            pane:Refresh()
        end)
        toggles[m] = b
        x = x + (winKey and 174 or 104)
    end

    local cmdNote = UI.Label(pane, "On Mac, Cmd+Left-click may act as a right click.", "GameFontDisable")
    cmdNote:SetPoint("TOPLEFT", 0, -108)
    cmdNote:Hide()

    local extra = UI.Checkbox(pane, "Show mouse buttons 6-8 (hover bindings)",
        function() return ns.db.ui.extraButtons end,
        function(v) ns.db.ui.extraButtons = v; pane:Refresh() end)
    extra:SetPoint("TOPLEFT", 280, -92)

    local rows = {}
    local function pick(row)
        local items = { { text = "(none)", value = "clear" } }
        for _, s in ipairs(ns.ClassSpellList()) do
            items[#items + 1] = { text = s.name, icon = ns.SpellTexture(s.id or s.name),
                value = { type = "spell", spell = s.name } }
        end
        items[#items + 1] = { text = "Target unit", value = { type = "target" } }
        if row.key == "|2" then
            items[#items + 1] = { text = "Unit menu", value = { type = "menu" } }
        end
        UI.ShowMenu(row.pick, items, function(item)
            assign(row.key, item.value ~= "clear" and item.value or nil)
        end, 220)
    end

    local function receive(row)
        local name = cursorSpell()
        if name then
            ClearCursor()
            assign(row.key, { type = "spell", spell = name })
        end
    end

    for i = 1, 8 do
        local row = ns.NewFrame("Button", nil, pane, "BackdropTemplate")
        row:SetSize(540, ROW_HEIGHT - 2)
        row:SetPoint("TOPLEFT", 0, -120 - (i - 1) * ROW_HEIGHT)
        row:SetBackdrop(UI.BACKDROP)
        row:SetBackdropColor(0, 0, 0, 0.5)
        row.button = i
        row.label = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        row.label:SetPoint("LEFT", 8, 0)
        row.label:SetWidth(70)
        row.label:SetJustifyH("LEFT")
        row.label:SetText(Bindings.ButtonLabel(i))
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 84, 0)
        row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.text:SetWidth(210)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.pick = UI.Button(row, "Pick", 60, function() pick(row) end)
        row.pick:SetPoint("RIGHT", -34, 0)
        row.pick:SetHeight(20)
        row.clear = UI.Button(row, "X", 24, function() assign(row.key, nil) end)
        row.clear:SetPoint("RIGHT", -6, 0)
        row.clear:SetHeight(20)
        row:SetScript("OnReceiveDrag", receive)
        row:SetScript("OnClick", function(self)
            if GetCursorInfo and GetCursorInfo() then receive(self) end
        end)
        rows[i] = row
    end

    local loadExample = UI.Button(pane, "Load example bindings (Paladin)", 230, function()
        -- only fills EMPTY slots (the default plain Left = target / Right = menu count as empty)
        for key, action in pairs(Bindings.EXAMPLE_PALADIN) do
            local existing = ns.db.bindings[key]
            local empty = existing == nil or (key == "|1" and existing.type == "target")
                or (key == "|2" and existing.type == "menu")
            if empty then ns.db.bindings[key] = Util.DeepCopy(action) end
        end
        ns:Changed("bindings")
    end)
    loadExample:SetPoint("BOTTOMLEFT", 0, 62)

    local summaryTitle = UI.Label(pane, "Combos with bindings (click to edit)", "GameFontNormal")
    summaryTitle:SetPoint("TOPLEFT", 0, -368)
    local chips = {}

    local note = UI.Label(pane, "Cmd bindings are experimental on WoW Mac - test in game (if Cmd is not honoured, the plain binding runs). Buttons 6+ use hover bindings. Unit menu only works on plain Right. Dead members: every click casts your resurrection spell.", "GameFontDisable")
    note:SetPoint("BOTTOMLEFT", 0, 4)
    note:SetWidth(540)
    note:SetWordWrap(true)

    local function selectCombo(modKey)
        for m in pairs(mods) do mods[m] = false end
        for part in modKey:gmatch("[^%-]+") do mods[part] = true end
        pane:Refresh()
    end

    function pane:Refresh()
        extra:Refresh()
        local modKey = currentMod()
        for m, b in pairs(toggles) do
            if b.dimmed then
                if mods[m] then
                    b:SetBackdropColor(0.3, 0.25, 0.1, 0.8)
                    b:SetBackdropBorderColor(0.7, 0.6, 0.3, 1)
                else
                    b:SetBackdropColor(0, 0, 0, 0.4)
                    b:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
                end
            elseif mods[m] then
                b:SetBackdropColor(0.45, 0.35, 0.05, 1)
                b:SetBackdropBorderColor(1, 0.82, 0, 1)
            else
                b:SetBackdropColor(0, 0, 0, 0.7)
                b:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
            end
        end
        editing:SetText("Editing: " .. Bindings.ModifierLabel(modKey, ns.IsMac()))
        cmdNote:SetShown(mods.meta and ns.IsMac() and true or false)

        local effective = ns.ClickCast and ns.ClickCast:EffectiveBindings() or ns.db.bindings
        local count = ns.db.ui.extraButtons and 8 or 5
        for i, row in ipairs(rows) do
            if i > count then
                row:Hide()
            else
                local key = Bindings.MakeKey(modKey, i)
                row.key = key
                local action = effective[key]
                if action then
                    row.text:SetText(actionText(action))
                    row.text:SetTextColor(1, 1, 1)
                    if action.type == "spell" then
                        row.icon:SetTexture(ns.SpellTexture(action.spell))
                        row.icon:Show()
                    else
                        row.icon:Hide()
                    end
                    row.clear:SetEnabled(ns.db.bindings[key] ~= nil)
                else
                    row.text:SetText("-")
                    row.text:SetTextColor(0.4, 0.4, 0.4)
                    row.icon:Hide()
                    row.clear:SetEnabled(false)
                end
                row:Show()
            end
        end

        for _, c in ipairs(chips) do c:Hide() end
        local cx, cy = 0, -388
        for i, combo in ipairs(Bindings.SummarizeCombos(ns.db.bindings)) do
            local chip = chips[i]
            if not chip then
                chip = UI.Button(pane, "", 100, nil)
                chip:SetHeight(20)
                chips[i] = chip
            end
            chip:SetText(Bindings.DisplayLabel(combo.modKey, ns.IsMac()) .. " (" .. combo.count .. ")")
            local w = chip:GetFontString():GetStringWidth() + 20
            chip:SetWidth(w)
            if cx + w > SUMMARY_WIDTH then cx, cy = 0, cy - 24 end
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", cx, cy)
            chip:SetScript("OnClick", function() selectCombo(combo.modKey) end)
            chip:SetEnabled(combo.modKey ~= modKey)
            chip:Show()
            cx = cx + w + 4
        end
    end
end)
