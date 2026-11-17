local ADDON_NAME, ns = ...

local UI, Options = ns.UI, ns.Options

local function spellId(entry)
    if entry.id then return entry.id end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(entry.name)
        return info and info.spellID
    end
end

local function pickup(entry)
    local id = spellId(entry)
    if not id then return end
    if C_Spell and C_Spell.PickupSpell then
        C_Spell.PickupSpell(id)
    elseif PickupSpell then
        PickupSpell(id)
    end
end

-- Flat list built from the player's actual spellbook + talents (see Data/Spells.lua):
-- { group = title, name = , id = , icon = }
function ns.ClassSpellList()
    local lists = ns.Spells.GetList()
    local out = {}
    for _, group in ipairs(ns.Spells.GROUPS) do
        for _, s in ipairs(lists[group.key] or {}) do
            out[#out + 1] = { group = group.title, name = s.name, id = s.spellID, icon = s.icon }
        end
    end
    return out
end

local function openSpellbook()
    if ns.InCombat() then
        ns:Print("Cannot open the spellbook in combat.")
        return
    end
    local ok = false
    if PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then
        ok = pcall(PlayerSpellsUtil.ToggleSpellBookFrame)
    elseif ToggleSpellBook then
        ok = pcall(ToggleSpellBook, "spell")
    elseif SpellBookFrame and ToggleFrame then
        ok = pcall(ToggleFrame, SpellBookFrame)
    end
    if not ok then ns:Print("Spellbook could not be opened.") end
end

Options:RegisterPane("spells", "Class Spells", 3, function(pane)
    local class = ns.PlayerClass()
    UI.Header(pane, "Class Spells - " .. ((class and ns.Classes.NAMES[class]) or "Unknown"),
        "Built from your actual spellbook and talents. Drag a spell onto a click-casting row, or drag from the game spellbook.")
    local book = UI.Button(pane, "Open Spellbook", 130, openSpellbook)
    book:SetPoint("TOPLEFT", 0, -56)

    local filter = ""
    local searchLabel = UI.Label(pane, "Search")
    searchLabel:SetPoint("LEFT", book, "RIGHT", 16, 0)
    local search = ns.NewFrame("EditBox", nil, pane, "InputBoxTemplate")
    search:SetSize(150, 20)
    search:SetAutoFocus(false)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 10, 0)
    search:SetScript("OnTextChanged", function(self)
        filter = self:GetText():lower()
        if pane.Refresh then pane:Refresh() end
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local addLabel = UI.Label(pane, "+ Add spell by name")
    addLabel:SetPoint("TOPLEFT", 0, -90)
    local addBox
    local function addSpell(text)
        text = ns.Util.Trim(text)
        if text == "" then return end
        local ok, name = ns.Spells.AddCustom(text)
        if ok then
            ns:Print("Added spell: " .. (name or text))
            addBox:SetText("")
        else
            ns:Print("Spell not found: " .. text)
        end
    end
    addBox = UI.EditBox(pane, 200, addSpell)
    addBox:SetPoint("LEFT", addLabel, "RIGHT", 12, 0)
    local addBtn = UI.Button(pane, "Add", 50, function() addSpell(addBox:GetText()) end)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 6, 0)

    local scroll = ns.NewFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -118)
    scroll:SetPoint("BOTTOMRIGHT", -26, 4)
    local child = ns.NewFrame("Frame", nil, scroll)
    child:SetSize(500, 100)
    scroll:SetScrollChild(child)

    local buttons, titles = {}, {}
    local empty = UI.Label(child, "No matching spells.", "GameFontDisable")
    empty:SetPoint("TOPLEFT", 0, 0)

    local function getButton(i)
        local btn = buttons[i]
        if btn then return btn end
        btn = ns.NewFrame("Button", nil, child)
        btn:SetSize(300, 24)
        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetSize(22, 22)
        btn.icon:SetPoint("LEFT")
        btn.text = UI.Label(btn, "")
        btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 6, 0)
        btn:RegisterForDrag("LeftButton")
        btn:SetScript("OnDragStart", function(self) pickup(self.entry) end)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\WHITE8X8")
        hl:SetVertexColor(1, 1, 1, 0.08)
        buttons[i] = btn
        return btn
    end

    function pane:Refresh()
        for _, b in ipairs(buttons) do b:Hide() end
        for _, t in pairs(titles) do t:Hide() end
        local y, lastGroup, n = 0, nil, 0
        for _, s in ipairs(ns.ClassSpellList()) do
            if filter == "" or s.name:lower():find(filter, 1, true) then
                n = n + 1
                if s.group ~= lastGroup then
                    lastGroup = s.group
                    local t = titles[s.group]
                    if not t then
                        t = UI.Label(child, s.group, "GameFontNormal")
                        titles[s.group] = t
                    end
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", 0, y)
                    t:Show()
                    y = y - 20
                end
                local btn = getButton(n)
                btn.entry = s
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", 10, y)
                btn.icon:SetTexture(s.icon or ns.SpellTexture(s.id or s.name))
                btn.text:SetText(s.name)
                btn:Show()
                y = y - 26
            end
        end
        empty:SetShown(n == 0)
        child:SetHeight(math.max(30, -y + 8))
    end
end)

ns:On("SPELLS_UPDATED", function() Options:Refresh() end)
