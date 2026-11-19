local ADDON_NAME, ns = ...

local UI, Options = ns.UI, ns.Options
local Presets, Classes = ns.Presets, ns.Classes

local ROW_HEIGHT = 22
local LABEL_W = 150
local ROLE_ICONS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }
local ROLE_COORDS = {
    TANK = { 0, 19 / 64, 22 / 64, 41 / 64 },
    HEALER = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
    DAMAGER = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
}
local ROLE_CHOICES = {
    { text = "Auto", value = "AUTO" }, { text = "Tank", value = "TANK" },
    { text = "Healer", value = "HEALER" }, { text = "DPS", value = "DAMAGER" },
}
local GROUP_UNITS = { "player", "party1", "party2", "party3", "party4" }

local function setRoleIcon(tex, role)
    local atlas = ROLE_ICONS[role]
    if atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        tex:SetAtlas(atlas)
    elseif ROLE_COORDS[role] then
        tex:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
        tex:SetTexCoord(unpack(ROLE_COORDS[role]))
    end
end

local ICON_SIZE = 16
local MAX_CELL_ICONS = 6

-- A preset cell: shows small icons of the chosen buffs, or a dash when empty.
local function createCell(parent, width)
    local cell = ns.NewFrame("Button", nil, parent, "BackdropTemplate")
    cell:SetSize(width, 20)
    cell:SetBackdrop(UI.BACKDROP)
    cell:SetBackdropColor(0, 0, 0, 0.6)
    cell.icons = {}
    for i = 1, MAX_CELL_ICONS do
        local t = cell:CreateTexture(nil, "ARTWORK")
        t:SetSize(ICON_SIZE, ICON_SIZE)
        t:SetPoint("LEFT", 6 + (i - 1) * (ICON_SIZE + 2), 0)
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t:Hide()
        cell.icons[i] = t
    end
    cell.dash = cell:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    cell.dash:SetPoint("LEFT", 8, 0)
    return cell
end

local function setCellKeys(cell, keys, emptyText)
    for i, tex in ipairs(cell.icons) do
        local key = keys and keys[i]
        local def = key and Classes.BUFFS[key]
        if def then
            tex:SetTexture(ns.BuffButtons.IconFor(def.name, def))
            tex:Show()
        else
            tex:Hide()
        end
    end
    local any = keys and keys[1] ~= nil
    cell.dash:SetText(any and "" or (emptyText or "\226\128\148"))
end

-- Popup with one section per catalog group: a checkbox for a single-buff group, radio buttons plus "None" for a
-- multi-buff group. Built from our own widgets (never UIDropDownMenu).
local popup

local function ensurePopup()
    if popup then return popup end
    popup = ns.NewFrame("Frame", "HealerForeverBuffPopup", UIParent, "BackdropTemplate")
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetBackdrop(UI.BACKDROP)
    popup:SetBackdropColor(0, 0, 0, 0.95)
    popup:SetClampedToScreen(true)
    popup:EnableMouse(true)
    popup:Hide()
    popup.rows, popup.headers = {}, {}
    popup.note = popup:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    popup.note:SetWidth(230)
    popup.note:SetJustifyH("LEFT")
    popup.note:SetWordWrap(true)

    local catcher = ns.NewFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", function() popup:Hide() end)
    catcher:Hide()
    popup:SetScript("OnShow", function() catcher:Show() end)
    popup:SetScript("OnHide", function() catcher:Hide() end)
    if UISpecialFrames then table.insert(UISpecialFrames, "HealerForeverBuffPopup") end
    return popup
end

local function popupRow(i)
    local row = popup.rows[i]
    if row then return row end
    row = ns.NewFrame("Button", nil, popup)
    row:SetHeight(20)
    row.box = row:CreateTexture(nil, "ARTWORK")
    row.box:SetSize(14, 14)
    row.box:SetPoint("LEFT", 4, 0)
    row.box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
    row.check = row:CreateTexture(nil, "OVERLAY")
    row.check:SetSize(14, 14)
    row.check:SetPoint("LEFT", 4, 0)
    row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 24, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetJustifyH("LEFT")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Buttons\\WHITE8X8")
    hl:SetVertexColor(1, 0.82, 0, 0.15)
    popup.rows[i] = row
    return row
end

local function popupHeader(i)
    local h = popup.headers[i]
    if not h then
        h = popup:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        popup.headers[i] = h
    end
    return h
end

-- ctx = { class = caster class token, get = fn -> array of keys, toggle = fn(key, on), clear = fn(groupId),
--         noneLabel = text for a multi group's "None" row, inherit = fn -> true while a role row follows the class row,
--         reset = fn() that makes a role row follow the class row again }
-- Role rows: the "None" slot of each multi group reads "Use class row" (checked while inheriting, and the group's
-- buffs then show unchecked). A catalog without a multi group gets one "Use class row" row on top instead.
local function renderPopup(ctx)
    local set = {}
    for _, key in ipairs(ctx.get()) do set[key] = true end
    local nRows, nHeaders, y = 0, 0, -8
    popup.note:ClearAllPoints()
    if ctx.note then
        popup.note:SetPoint("TOPLEFT", 8, y)
        popup.note:SetText(ctx.note)
        popup.note:Show()
        y = y - popup.note:GetStringHeight() - 6
    else
        popup.note:Hide()
    end
    local inheriting = ctx.inherit and ctx.inherit() and true or false
    local catalog = Classes.BuffCatalog(ctx.class)
    local hasMulti = false
    for _, group in ipairs(catalog) do
        if group.multi then hasMulti = true end
    end
    if ctx.reset and not hasMulti then
        nRows = nRows + 1
        local row = popupRow(nRows)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 6, y)
        row:SetPoint("TOPRIGHT", -6, y)
        row.icon:Hide()
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row.box, "RIGHT", 8, 0)
        row.text:SetText(ctx.noneLabel or "Use class row")
        row.text:SetTextColor(1, 1, 1)
        row.check:SetShown(inheriting)
        row:SetScript("OnClick", function()
            ctx.reset()
            renderPopup(ctx)
        end)
        row:Show()
        y = y - 24
    end
    for _, group in ipairs(catalog) do
        nHeaders = nHeaders + 1
        local h = popupHeader(nHeaders)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", 8, y)
        h:SetText(group.name .. (group.multi and " (one at a time)" or ""))
        h:Show()
        y = y - 16
        local function addRow(label, key, selected, onClick)
            nRows = nRows + 1
            local row = popupRow(nRows)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 6, y)
            row:SetPoint("TOPRIGHT", -6, y)
            local def = key and Classes.BUFFS[key]
            local known = not def or ns.SpellKnown(def.name) or (def.groupSpell and ns.SpellKnown(def.groupSpell))
            if def then
                row.icon:SetTexture(ns.BuffButtons.IconFor(def.name, def))
                row.icon:Show()
                row.icon:SetDesaturated(not known)
            else
                row.icon:Hide()
            end
            row.text:ClearAllPoints()
            row.text:SetPoint("LEFT", def and row.icon or row.box, "RIGHT", def and 6 or 8, 0)
            row.text:SetText(label .. ((def and not known) and "  |cff888888Not in your spellbook|r" or ""))
            row.text:SetTextColor(known and 1 or 0.55, known and 1 or 0.55, known and 1 or 0.55)
            row.check:SetShown(selected and true or false)
            row:SetScript("OnClick", function()
                onClick()
                renderPopup(ctx)
            end)
            row:Show()
            y = y - 20
        end
        if group.multi then
            local any = false
            for _, key in ipairs(group.buffs) do
                if set[key] then any = true end
            end
            if ctx.reset then
                -- role row: the first option follows the class row (checked while inheriting)
                addRow(ctx.noneLabel or "Use class row", nil, inheriting, function() ctx.reset() end)
                for _, key in ipairs(group.buffs) do
                    addRow(Classes.BUFFS[key].name, key, not inheriting and set[key],
                        function() ctx.toggle(key, true) end)
                end
            else
                addRow(ctx.noneLabel or "None", nil, not any, function() ctx.clear(group.id) end)
                for _, key in ipairs(group.buffs) do
                    addRow(Classes.BUFFS[key].name, key, set[key], function() ctx.toggle(key, true) end)
                end
            end
        else
            for _, key in ipairs(group.buffs) do
                addRow(Classes.BUFFS[key].name, key, set[key], function() ctx.toggle(key, not set[key]) end)
            end
        end
        y = y - 4
    end
    for i = nRows + 1, #popup.rows do popup.rows[i]:Hide() end
    for i = nHeaders + 1, #popup.headers do popup.headers[i]:Hide() end
    popup:SetSize(250, -y + 6)
end

local function showPopup(anchor, ctx)
    if #Classes.BuffCatalog(ctx.class) == 0 then return end
    ensurePopup()
    popup:ClearAllPoints()
    popup:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    renderPopup(ctx)
    popup:Show()
end

Options:RegisterPane("buffs", "Buff Presets", 2, function(pane)
    local edit = 1
    local pageScroll = ns.NewFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    pageScroll:SetPoint("TOPLEFT", 0, 0)
    pageScroll:SetPoint("BOTTOMRIGHT", -24, 0)
    local root = ns.NewFrame("Frame", nil, pageScroll)
    root:SetSize(540, 1100)
    pageScroll:SetScrollChild(root)
    UI.Header(root, "Buff Presets",
        "Pick which of YOUR buffs each class and role gets. One per group; groups stack. Role rows follow the class row unless you pick buffs; 'Use class row' resets them.")
    local classLabel = UI.Label(root, "", "GameFontNormal")
    classLabel:SetPoint("TOPLEFT", 330, -56)

    local function presetItems()
        local items = {}
        for i, p in ipairs(ns.db.presets) do
            local text = i .. ". " .. p.name
            if i == ns.db.activePreset then text = text .. " |cff33ff33(active)|r" end
            items[#items + 1] = { text = text, value = i }
        end
        return items
    end

    local presetLabel = UI.Label(root, "Preset:", "GameFontNormal")
    presetLabel:SetPoint("TOPLEFT", 0, -56)
    local presetDD = UI.Dropdown(root, 260, presetItems,
        function() return edit end,
        function(v) edit = v; pane:Refresh() end, true)
    presetDD:SetPoint("TOPLEFT", 60, -52)

    -- inline name entry for New / Duplicate / Rename
    local pending
    local nameLabel = UI.Label(root, "Name:")
    nameLabel:SetPoint("TOPLEFT", 0, -112)
    local nameBox, okBtn, cancelBtn
    local function closeNameRow()
        pending = nil
        nameLabel:Hide(); nameBox:Hide(); okBtn:Hide(); cancelBtn:Hide()
    end
    local function commitName(text)
        local list = ns.db.presets
        if pending == "new" then
            edit = Presets.Add(list, text, nil)
        elseif pending == "dup" then
            if ns.Util.Trim(text) == "" then text = "Copy of " .. list[edit].name end
            edit = Presets.Add(list, text, edit)
        elseif pending == "rename" then
            Presets.Rename(list, edit, text)
        end
        closeNameRow()
        ns:Changed("presets")
    end
    nameBox = UI.EditBox(root, 200, commitName)
    nameBox:SetPoint("TOPLEFT", 50, -108)
    okBtn = UI.Button(root, "OK", 50, function() commitName(nameBox:GetText()) end)
    okBtn:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
    cancelBtn = UI.Button(root, "Cancel", 60, closeNameRow)
    cancelBtn:SetPoint("LEFT", okBtn, "RIGHT", 4, 0)
    closeNameRow()

    local function openNameRow(mode, initial)
        pending = mode
        nameBox:SetText(initial or "")
        nameLabel:Show(); nameBox:Show(); okBtn:Show(); cancelBtn:Show()
        nameBox:SetFocus()
    end

    local deleteBtn
    local confirming = false
    local function resetDelete()
        confirming = false
        if deleteBtn then deleteBtn:SetText("Delete") end
    end

    local actions = {
        { "New", 60, function() openNameRow("new", "") end },
        { "Duplicate", 80, function() openNameRow("dup", "Copy of " .. ns.db.presets[edit].name) end },
        { "Rename", 70, function() openNameRow("rename", ns.db.presets[edit].name) end },
        { "Delete", 70, function()
            if #ns.db.presets <= 1 then
                ns:Print("Cannot delete the last preset.")
                return
            end
            if not confirming then
                confirming = true
                deleteBtn:SetText("Confirm?")
                if C_Timer and C_Timer.After then C_Timer.After(4, resetDelete) end
                return
            end
            resetDelete()
            local removed = edit
            if Presets.Remove(ns.db.presets, edit) then
                if edit > #ns.db.presets then edit = #ns.db.presets end
                if ns.db.activePreset > removed then
                    ns.db.activePreset = ns.db.activePreset - 1
                elseif ns.db.activePreset > #ns.db.presets then
                    ns.db.activePreset = #ns.db.presets
                end
                ns:Changed("presets")
            end
        end },
        { "Make active", 90, function() ns:SetActivePreset(edit) end },
        { "Load example...", 110, function(self)
            -- adds a NEW preset; never overwrites anything
            local items = {}
            local names = { PALADIN = "Paladin", PRIEST = "Priest", MAGE = "Mage", DRUID = "Druid" }
            for _, class in ipairs(Presets.EXAMPLE_CLASSES) do
                items[#items + 1] = { text = "Load example: " .. names[class], value = class }
            end
            UI.ShowMenu(self, items, function(item)
                local example = Presets.ExampleFor(item.value)
                if example then
                    edit = #ns.db.presets + 1
                    ns.db.presets[edit] = example
                    ns:Changed("presets")
                end
            end, 220)
        end },
    }
    local ax = 0
    for _, a in ipairs(actions) do
        local b = UI.Button(root, a[1], a[2], a[3])
        b:SetPoint("TOPLEFT", ax, -80)
        ax = ax + a[2] + 4
        if a[1] == "Delete" then deleteBtn = b end
    end

    -- Self row
    local selfLabel = UI.Label(root, "Self (you)", "GameFontNormal")
    selfLabel:SetPoint("TOPLEFT", 0, -152)
    local selfCell = createCell(root, 200)
    selfCell:SetPoint("TOPLEFT", 90, -149)
    local selfRules = UI.Button(root, "Use class/role rules", 150, function()
        Presets.SetSelf(ns.db.presets[edit], nil)
        ns:Changed("presets")
    end)
    selfRules:SetPoint("LEFT", selfCell, "RIGHT", 8, 0)
    selfRules:SetHeight(20)
    selfCell:SetScript("OnClick", function(self)
        local preset = ns.db.presets[edit]
        showPopup(self, {
            class = ns.PlayerClass(),
            note = "Anything chosen here replaces the class/role rules for you. Use the \"Use class/role rules\" button to go back.",
            noneLabel = "None (no buffs for you)",
            get = function() return preset.self or {} end,
            toggle = function(key, on) Presets.SetSelfBuff(preset, key, on); ns:Changed("presets") end,
            clear = function(groupId) Presets.ClearSelfGroup(preset, groupId); ns:Changed("presets") end,
        })
    end)

    local emptyHint = UI.Label(root, "Your class has no party buffs to assign. Use Role buffs below for anything special.",
        "GameFontDisable")
    emptyHint:SetPoint("TOPLEFT", 0, -178)
    emptyHint:SetWidth(520)
    emptyHint:SetWordWrap(true)

    -- Rule grid (scrollable)
    local scroll = ns.NewFrame("ScrollFrame", nil, root, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -178)
    scroll:SetSize(530, 200)
    local child = ns.NewFrame("Frame", nil, scroll)
    child:SetSize(500, 100)
    scroll:SetScrollChild(child)

    local rows = {}
    local y = 0
    local CELL_X = LABEL_W
    for _, class in ipairs(Classes.ORDER) do
        local c = Classes.GetColor(class)
        local roleList = { "DEFAULT" }
        for _, r in ipairs(Classes.ROLES[class]) do roleList[#roleList + 1] = r end
        for _, role in ipairs(roleList) do
            local row = { class = class, role = role }
            row.label = UI.Label(child, "")
            row.label:SetPoint("TOPLEFT", role == "DEFAULT" and 0 or 14, y - 3)
            if role == "DEFAULT" then
                row.label:SetText(Classes.NAMES[class])
                row.label:SetTextColor(c.r, c.g, c.b)
            else
                row.icon = child:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(14, 14)
                row.icon:SetPoint("TOPLEFT", 14, y - 3)
                setRoleIcon(row.icon, role)
                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", row.icon, "RIGHT", 3, 0)
                row.label:SetText(Classes.ROLE_LABELS[role])
                row.label:SetTextColor(0.8, 0.8, 0.8)
                row.note = UI.Label(child, "= default", "GameFontDisable")
                row.note:SetPoint("TOPLEFT", CELL_X + 184, y - 4)
            end
            row.cell = createCell(child, 176)
            row.cell:SetPoint("TOPLEFT", CELL_X, y)
            row.cell:SetScript("OnClick", function(self)
                local preset = ns.db.presets[edit]
                local isRole = role ~= "DEFAULT"
                showPopup(self, {
                    class = ns.PlayerClass(),
                    noneLabel = isRole and "Use class row" or nil,
                    inherit = isRole and function() return Presets.RoleInherits(preset, class, role) end or nil,
                    reset = isRole and function() Presets.ResetRole(preset, class, role); ns:Changed("presets") end or nil,
                    get = function() return Presets.CellBuffs(preset, class, role, false) end,
                    toggle = function(key, on) Presets.SetCellBuff(preset, class, role, key, on); ns:Changed("presets") end,
                    clear = function(groupId) Presets.ClearGroup(preset, class, role, groupId); ns:Changed("presets") end,
                })
            end)
            rows[#rows + 1] = row
            y = y - ROW_HEIGHT
        end
    end
    child:SetHeight(-y + 8)

    -- Group roles
    local rolesTitle = UI.Label(root, "Group roles", "GameFontNormal")
    rolesTitle:SetPoint("TOPLEFT", 0, -388)
    local groupRows = {}
    for i, unit in ipairs(GROUP_UNITS) do
        local r = {}
        r.name = UI.Label(root, "")
        r.name:SetPoint("TOPLEFT", 0, -408 - (i - 1) * 24)
        r.name:SetWidth(170)
        r.detected = UI.Label(root, "", "GameFontDisable")
        r.detected:SetPoint("TOPLEFT", 180, -408 - (i - 1) * 24)
        r.dd = UI.Dropdown(root, 110, function() return ROLE_CHOICES end,
            function() return ns.Roles.GetOverride(unit) or "AUTO" end,
            function(v) ns.Roles.SetOverride(unit, v ~= "AUTO" and v or nil) end)
        r.dd:SetPoint("TOPLEFT", 290, -404 - (i - 1) * 24)
        r.unit = unit
        groupRows[i] = r
    end

    -- Role buffs -------------------------------------------------------------------------------------
    local MAX_EXTRAS = 8
    local EXTRA_Y = -548
    local extraTitle = UI.Label(root, "Role buffs", "GameFontNormal")
    extraTitle:SetPoint("TOPLEFT", 0, EXTRA_Y)
    local extraHint = UI.Label(root, "", "GameFontDisable")
    extraHint:SetPoint("TOPLEFT", 0, EXTRA_Y - 18)
    extraHint:SetWidth(520)
    extraHint:SetWordWrap(true)
    local keyHint = UI.Label(root, "Bind a key in Esc > Options > Keybindings > AddOns > Healer Forever, or use the macro /click HealerForeverSmartBuff", "GameFontDisable")
    keyHint:SetPoint("TOPLEFT", 0, EXTRA_Y - 52)
    keyHint:SetWidth(520)
    keyHint:SetWordWrap(true)

    local function addExtra(spell)
        if not spell then return end
        Presets.AddExtra(ns.db.presets[edit], spell, { TANK = true }, false)
        ns:Changed("presets")
    end
    local addExtraBtn = UI.Button(root, "+ Add role buff", 130, function(self)
        local items = {}
        for _, sp in ipairs(ns.ClassSpellList()) do
            items[#items + 1] = { text = sp.name, icon = ns.SpellTexture(sp.id or sp.name), value = sp.name }
        end
        UI.ShowMenu(self, items, function(item) addExtra(item.value) end, 240)
    end)
    addExtraBtn:SetPoint("TOPLEFT", 0, EXTRA_Y - 84)
    local function dropSpell()
        local name = ns.CursorSpellName and ns.CursorSpellName()
        if name then
            ClearCursor()
            addExtra(name)
        end
    end
    addExtraBtn:SetScript("OnReceiveDrag", dropSpell)
    local dragNote = UI.Label(root, "or drag a spell onto the button", "GameFontDisable")
    dragNote:SetPoint("LEFT", addExtraBtn, "RIGHT", 10, 0)

    local extraRows = {}
    for i = 1, MAX_EXTRAS do
        local top = EXTRA_Y - 116 - (i - 1) * 56
        local row = { index = i }
        row.icon = root:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("TOPLEFT", 0, top)
        row.name = UI.Label(root, "")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetWidth(300)
        row.remove = UI.Button(root, "X", 24, function()
            if Presets.RemoveExtra(ns.db.presets[edit], row.index) then ns:Changed("presets") end
        end)
        row.remove:SetPoint("TOPLEFT", 440, top + 2)
        row.remove:SetHeight(20)
        row.checks = {}
        local function roleCheck(label, role, x)
            local cb = UI.Checkbox(root, label,
                function()
                    local e = ns.db.presets[edit].extras[row.index]
                    return e and e.roles[role]
                end,
                function(v)
                    local e = ns.db.presets[edit].extras[row.index]
                    if e then e.roles[role] = v or nil; ns:Changed("presets") end
                end)
            cb:SetPoint("TOPLEFT", x, top - 22)
            row.checks[#row.checks + 1] = cb
        end
        roleCheck("Tank", "TANK", 0)
        roleCheck("Healer", "HEALER", 64)
        roleCheck("DPS", "DAMAGER", 140)
        roleCheck("Self", "SELF", 196)
        local single = UI.Checkbox(root, "One target at a time",
            function()
                local e = ns.db.presets[edit].extras[row.index]
                return e and e.single
            end,
            function(v)
                local e = ns.db.presets[edit].extras[row.index]
                if e then e.single = v and true or false; ns:Changed("presets") end
            end)
        single:SetPoint("TOPLEFT", 260, top - 22)
        row.checks[#row.checks + 1] = single
        extraRows[i] = row
    end

    function pane:Refresh()
        local list = ns.db.presets
        if edit > #list then edit = #list end
        local preset = list[edit]
        presetDD:Refresh()
        local extras = preset.extras or {}
        for i, row in ipairs(extraRows) do
            local e = extras[i]
            if e then
                row.icon:SetTexture(ns.SpellTexture(e.spell))
                row.icon:Show()
                row.name:SetText(e.spell)
                row.name:Show()
                row.remove:Show()
                for _, cb in ipairs(row.checks) do cb:Refresh(); cb:Show() end
            else
                row.icon:Hide(); row.name:Hide(); row.remove:Hide()
                for _, cb in ipairs(row.checks) do cb:Hide() end
            end
        end
        addExtraBtn:SetEnabled(#extras < MAX_EXTRAS)
        local hint = "Extra targeted buffs on top of the blessing, by role (e.g. a tank-only oath)."
        if ns.PlayerClass() == "PALADIN" then
            local oath
            for _, sp in ipairs(ns.ClassSpellList()) do
                if sp.name:find("Oath", 1, true) then oath = sp.name end
            end
            hint = hint .. " Tip: add your tank oath here" .. (oath and (" (found: " .. oath .. ")") or "") .. "."
        end
        extraHint:SetText(hint)
        local playerClass = ns.PlayerClass()
        local pc = playerClass and Classes.GetColor(playerClass)
        classLabel:SetText("You are playing: " .. ((playerClass and Classes.NAMES[playerClass]) or "?"))
        if pc then classLabel:SetTextColor(pc.r, pc.g, pc.b) end
        local hasCatalog = #Classes.BuffCatalog(playerClass) > 0
        emptyHint:SetShown(not hasCatalog)
        scroll:SetShown(hasCatalog)
        selfLabel:SetShown(hasCatalog)
        selfCell:SetShown(hasCatalog)
        selfRules:SetShown(hasCatalog)
        if hasCatalog then
            if preset.self == nil then
                setCellKeys(selfCell, nil, "class/role rules")
            else
                setCellKeys(selfCell, preset.self, "none")
            end
            for _, row in ipairs(rows) do
                setCellKeys(row.cell, Presets.CellBuffs(preset, row.class, row.role, false))
                if row.note then row.note:SetShown(Presets.RoleInherits(preset, row.class, row.role)) end
            end
        end
        for _, r in ipairs(groupRows) do
            local unit = r.unit
            if ns.Exists(unit) then
                local _, token = UnitClass(unit)
                local c = (not ns.issecret(token) and token) and Classes.GetColor(token) or { r = 1, g = 1, b = 1 }
                r.name:SetText(UnitName(unit))
                r.name:SetTextColor(c.r, c.g, c.b)
                local detected = ns.Roles.GetDetected(unit)
                r.detected:SetText("detected: " .. (detected and Classes.ROLE_LABELS[detected] or "none"))
                r.dd:Refresh()
                r.name:Show(); r.detected:Show(); r.dd:Show()
            else
                r.name:Hide(); r.detected:Hide(); r.dd:Hide()
            end
        end
    end
end)

ns:RegisterEvent("GROUP_ROSTER_UPDATE", function() Options:Refresh() end)
