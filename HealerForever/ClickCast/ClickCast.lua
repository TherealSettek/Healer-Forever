local ADDON_NAME, ns = ...

-- Secure application of click-casting bindings to the unit buttons.
--
-- Routes (see Bindings.lua for the Blizzard prefix verification):
--   * buttons 1-5 without Cmd: plain secure attributes on the button;
--   * buttons 6+ and Cmd combos: hover override bindings set from a secure snippet
--     (SecureHandlerEnterLeaveTemplate, Clique style) that click the button as "HFB<n>";
--   * dead members: the alive -> dead switch must work in combat without addon-side SetAttribute.
--       - spell bindings are generated as secure macros:
--           /cast [@party1,dead] Redemption; [@party1] Flash of Light
--         the game itself evaluates [@unit,dead] on every click;
--       - target / menu bindings use a secure state driver ("[@unit,dead] dead; alive") whose
--         restricted snippet swaps the button's own attributes to a resurrection macro and back;
--     the unit token comes from the button's fixed "unit" attribute (buttons are never reassigned).
local CC = {}
ns.ClickCast = CC

local Bindings = ns.Bindings

local ENTER_SNIPPET = [[
local n = self:GetAttribute("hf-nbinds") or 0
for i = 1, n do
    local key = self:GetAttribute("hf-bkey" .. i)
    if key then
        self:SetBindingClick(true, key, self, "HFB" .. i)
    end
end
]]

local LEAVE_SNIPPET = [[
self:ClearBindings()
]]

-- Cmd (meta): the secure click prefix only knows alt/ctrl/shift (verified in SecureTemplates.lua), and a
-- META-BUTTONn override binding is never reached for the plain mouse buttons because the frame consumes the
-- click first. So while Cmd is held (state driver "[mod:meta]") this snippet writes the Cmd bindings into the
-- plain attribute slots of the same button (and restores the originals when Cmd is released). The conditional
-- name is unverified on Mac: /hf debug click watch reports what the client says.
local META_SNIPPET = [[
local n = self:GetAttribute("hf-mn") or 0
for i = 1, n do
    local typeName = self:GetAttribute("hf-mtype" .. i)
    local macroName = self:GetAttribute("hf-mmac" .. i)
    if newstate == "meta" then
        self:SetAttribute(macroName, self:GetAttribute("hf-mtext" .. i))
        self:SetAttribute(typeName, "macro")
    else
        local origType = self:GetAttribute("hf-motype" .. i)
        local origMacro = self:GetAttribute("hf-momac" .. i)
        if origType == "" then origType = nil end
        if origMacro == "" then origMacro = nil end
        self:SetAttribute(macroName, origMacro)
        self:SetAttribute(typeName, origType)
    end
end
]]

local STATE_SNIPPET = [[
local n = self:GetAttribute("hf-dn") or 0
for i = 1, n do
    local typeName = self:GetAttribute("hf-dtype" .. i)
    local macroName = self:GetAttribute("hf-dmac" .. i)
    if newstate == "dead" then
        self:SetAttribute(macroName, self:GetAttribute("hf-dtext" .. i))
        self:SetAttribute(typeName, "macro")
    else
        self:SetAttribute(typeName, self:GetAttribute("hf-dorig" .. i))
    end
end
]]

-- Returns the player's usable resurrection spell (and an optional out-of-combat variant), or nil.
function ns.PlayerRes()
    local class = ns.PlayerClass()
    if not class then return nil end
    local res = ns.Classes.GetResSpell(class)
    local ooc = ns.Classes.GetResSpellOutOfCombat(class)
    local resKnown = res and ns.SpellKnown(res)
    local oocKnown = ooc and ns.SpellKnown(ooc)
    if resKnown then
        return res, oocKnown and ooc or nil
    elseif oocKnown then
        return ooc, nil
    end
    return nil
end

-- db.bindings plus the implicit defaults (empty plain Left = target, empty plain Right = menu).
function CC:EffectiveBindings()
    local out = {}
    for k, v in pairs(ns.db.bindings) do out[k] = v end
    if not out["|1"] then out["|1"] = { type = "target" } end
    if not out["|2"] then out["|2"] = { type = "menu" } end
    return out
end

local function clearButton(button)
    if button.hfAttrs then
        for name in pairs(button.hfAttrs) do button:SetAttribute(name, nil) end
    end
    button.hfAttrs = {}
end

local function setAttr(button, name, value)
    button:SetAttribute(name, value)
    button.hfAttrs[name] = true
end

local function applyToButton(button, bindings, res, resOOC)
    clearButton(button)
    if ClearOverrideBindings then ClearOverrideBindings(button) end
    local unit = button.unit
    if button.isPet then res, resOOC = nil, nil end

    local overrides, dead = 0, 0
    local metaEntries = {}
    for key, action in pairs(bindings) do
        local mod, buttonNumber = Bindings.ParseKey(key)
        -- "menu" only works on plain Right (Mainline gates it on C_ClickBindings)
        if mod and buttonNumber and (action.type ~= "menu" or key == "|2") then
            local effective = action
            if action.type == "spell" and action.spell then
                -- always a strict macro (never type=spell): it can never fall back to casting on yourself
                effective = { type = "macro", macrotext = Bindings.BuildMacroText(unit, action.spell, res, resOOC) }
            elseif action.type == "target" then
                effective = { type = "macro", macrotext = Bindings.BuildTargetMacro(unit, res, resOOC) }
            end

            -- plain attributes (buttons 1-31, no meta)
            local attrs, typeName, macroName = Bindings.ToPhysicalAttributes(key, effective)
            if attrs then
                for name, value in pairs(attrs) do setAttr(button, name, value) end
                if res and action.type == "menu" then
                    dead = dead + 1
                    setAttr(button, "hf-dtype" .. dead, typeName)
                    setAttr(button, "hf-dmac" .. dead, macroName)
                    setAttr(button, "hf-dorig" .. dead, attrs[typeName])
                    setAttr(button, "hf-dtext" .. dead, Bindings.BuildResOnlyMacro(unit, res, resOOC))
                end
            end

            -- Cmd swap entry: the same slot without "meta", written while Cmd is held
            local parts = {}
            local hasMeta = false
            for part in mod:gmatch("[^%-]+") do
                if part == "meta" then hasMeta = true else parts[#parts + 1] = part end
            end
            if hasMeta and effective.type == "macro" then
                local typeName2, macroName2 = Bindings.AttributeNames(table.concat(parts, "-"), buttonNumber)
                if typeName2 then
                    metaEntries[#metaEntries + 1] = { typeName2, macroName2, effective.macrotext }
                end
            end

            -- override-binding slot (buttons 6+ and Cmd combos)
            if Bindings.NeedsOverride(mod, buttonNumber) then
                local slot = "HFB" .. (overrides + 1)
                local slotAttrs = Bindings.ToOverrideAttributes(slot, effective)
                if slotAttrs then
                    overrides = overrides + 1
                    for name, value in pairs(slotAttrs) do setAttr(button, name, value) end
                    setAttr(button, "hf-bkey" .. overrides, Bindings.OverrideBindingKey(mod, buttonNumber))
                    if res and action.type == "menu" then
                        local slotType, slotMacro = Bindings.AttributeNames(nil, nil, slot)
                        dead = dead + 1
                        setAttr(button, "hf-dtype" .. dead, slotType)
                        setAttr(button, "hf-dmac" .. dead, slotMacro)
                        setAttr(button, "hf-dorig" .. dead, slotAttrs[slotType])
                        setAttr(button, "hf-dtext" .. dead, Bindings.BuildResOnlyMacro(unit, res, resOOC))
                    end
                end
            end
        end
    end
    setAttr(button, "hf-nbinds", overrides)
    setAttr(button, "hf-dn", dead)
    for i, entry in ipairs(metaEntries) do
        setAttr(button, "hf-mtype" .. i, entry[1])
        setAttr(button, "hf-mmac" .. i, entry[2])
        setAttr(button, "hf-mtext" .. i, entry[3])
        setAttr(button, "hf-motype" .. i, button:GetAttribute(entry[1]) or "")
        setAttr(button, "hf-momac" .. i, button:GetAttribute(entry[2]) or "")
        -- the swapped slots must be cleared on the next apply
        button.hfAttrs[entry[1]] = true
        button.hfAttrs[entry[2]] = true
    end
    setAttr(button, "hf-mn", #metaEntries)

    button:SetAttribute("_onenter", ENTER_SNIPPET)
    button:SetAttribute("_onleave", LEAVE_SNIPPET)
    button:SetAttribute("_onstate-hfdead", STATE_SNIPPET)
    button:SetAttribute("_onstate-hfmeta", META_SNIPPET)
    if not button.hfHideWrapped and SecureHandlerWrapScript then
        -- clear hover bindings when the button hides while the mouse is over it
        SecureHandlerWrapScript(button, "OnHide", button, LEAVE_SNIPPET)
        button.hfHideWrapped = true
    end

    UnregisterStateDriver(button, "hfmeta")
    button:SetAttribute("state-hfmeta", nil)
    if #metaEntries > 0 then
        RegisterStateDriver(button, "hfmeta", "[mod:meta] meta; none")
    end

    UnregisterStateDriver(button, "hfdead")
    button:SetAttribute("state-hfdead", nil)
    if dead > 0 then
        RegisterStateDriver(button, "hfdead", "[@" .. unit .. ",dead] dead; alive")
    end
end

-- Raid buttons while the party layout is active: no click attributes, no hover bindings, no state drivers (idle).
-- Buttons that were never armed are left untouched.
local function disarmButton(button)
    if not button.hfArmed then return end
    clearButton(button)
    if ClearOverrideBindings then ClearOverrideBindings(button) end
    UnregisterStateDriver(button, "hfmeta")
    button:SetAttribute("state-hfmeta", nil)
    UnregisterStateDriver(button, "hfdead")
    button:SetAttribute("state-hfdead", nil)
    button.hfArmed = nil
end

local function resolveRes()
    local res, resOOC
    if ns.db.resurrectOnClick then res, resOOC = ns.PlayerRes() end
    return res, resOOC
end

-- Applies the bindings to a list of unit buttons (out of combat only: the caller queues it otherwise).
function CC:ApplyToButtons(list)
    local res, resOOC = resolveRes()
    local bindings = CC:EffectiveBindings()
    for _, button in ipairs(list or {}) do
        applyToButton(button, bindings, res, resOOC)
        button.hfArmed = true
    end
end

-- Raid buttons: armed (strict @raidN macros) while the raid layout is active, disarmed otherwise.
function CC:ApplyRaidNow()
    local RF = ns.RaidFrames
    if not (RF and RF.anchor) then return end
    if RF:IsActive() then
        CC:ApplyToButtons(RF:ActiveButtons())
    else
        for _, button in ipairs(RF.buttons) do disarmButton(button) end
    end
end

function CC:ApplyRaid(silent)
    ns:AfterCombat("clickcast-raid", function() CC:ApplyRaidNow() end, silent)
end

function CC:ApplyNow()
    local UF = ns.UnitFrames
    if not UF.anchor then return end
    local res, resOOC = resolveRes()
    CC.signature = tostring(res) .. "|" .. tostring(resOOC) .. "|" .. tostring(ns.db.resurrectOnClick)
    local bindings = CC:EffectiveBindings()
    for _, button in ipairs(UF.buttons) do
        applyToButton(button, bindings, res, resOOC)
    end
    CC:ApplyRaidNow()
    ns:Fire("CLICKCAST_APPLIED")
end

function CC:Apply(silent)
    ns:AfterCombat("clickcast", function() CC:ApplyNow() end, silent)
end

-- Spell availability changes: only rebuild when the resolved res spells actually changed.
function CC:ApplyIfSpellsChanged()
    if not ns.UnitFrames.anchor then return end
    local res, resOOC
    if ns.db.resurrectOnClick then res, resOOC = ns.PlayerRes() end
    local sig = tostring(res) .. "|" .. tostring(resOOC) .. "|" .. tostring(ns.db.resurrectOnClick)
    if sig ~= CC.signature then CC:Apply(true) end
end

ns:On("FRAMES_CREATED", function() CC:Apply(true) end)
ns:On("RAID_FRAMES_CREATED", function() CC:ApplyRaid(true) end)
ns:On("RAID_LAYOUT_CHANGED", function() CC:ApplyRaid(true) end)
ns:On("CONFIG_CHANGED", function(group)
    if group == "bindings" or group == "all" or group == "general" then CC:Apply() end
end)
ns:RegisterEvent("SPELLS_CHANGED", function() CC:ApplyIfSpellsChanged() end)
ns:RegisterEvent("PLAYER_TALENT_UPDATE", function() CC:ApplyIfSpellsChanged() end)
