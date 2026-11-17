local ADDON_NAME, ns = ...

-- Pure binding helpers (no WoW API).
--
-- Key format: "<modifierKey>|<button>", modifierKey from ns.Util.ModifierKey (alt, ctrl, meta, shift order).
--
-- Verified against Blizzard live FrameXML (Blizzard_FrameXML/SecureTemplates.lua,
-- SecureButton_GetModifierPrefix): the secure click prefix is exactly "alt-" .. "ctrl-" .. "shift-"
-- (concatenated in that order). There is NO "meta-" support in secure clicks. Therefore:
--   * buttons 1-5 without meta are applied as plain secure attributes ("alt-ctrl-shift-type1" ...);
--   * buttons 6+ are ALSO applied as plain attributes (type6 ...) via ToPhysicalAttributes, so a physical
--     Button6 click on the frame works;
--   * buttons 6+ and every combination containing meta are additionally applied through hover override
--     bindings (SecureHandlerEnterLeaveTemplate) that click the unit button with a private button name
--     ("HFB<n>"). The unit button then looks up the wildcard attribute "*type-HFB<n>".
--   * Cmd has no secure prefix: a Cmd+click that the override binding does not win falls through to the
--     plain (no modifier) binding of the same button. A meta binding therefore never runs a different
--     spell on its own; at worst the plain binding runs. Cmd support is experimental.
--   * Mainline gates "target"/"menu" on C_ClickBindings (only plain Left/Right interaction bindings exist),
--     so ClickCast emits "target" as a macro; "menu" is only valid on plain Right (|2).
ns.Bindings = ns.Bindings or {}
local Bindings = ns.Bindings

local MODIFIER_ORDER = { "shift", "ctrl", "alt", "meta" }
local VALID_MODIFIERS = { shift = true, ctrl = true, alt = true, meta = true }

-- Opt-in example bindings (the old shipped Paladin set); loaders only fill EMPTY slots.
Bindings.EXAMPLE_PALADIN = {
    ["|1"] = { type = "spell", spell = "Flash of Light" },
    ["|2"] = { type = "spell", spell = "Holy Light" },
    ["|3"] = { type = "target" },
    ["|4"] = { type = "spell", spell = "Blessing of Wisdom" },
    ["|5"] = { type = "spell", spell = "Blessing of Might" },
    ["shift|1"] = { type = "spell", spell = "Cleanse" },
    ["shift|2"] = { type = "spell", spell = "Blessing of Freedom" },
    ["ctrl|1"] = { type = "spell", spell = "Holy Shock" },
    ["ctrl|2"] = { type = "spell", spell = "Blessing of Protection" },
    ["alt|1"] = { type = "spell", spell = "Divine Favor" },
    ["meta|2"] = { type = "spell", spell = "Lay on Hands" },
}

function Bindings.MakeKey(modKey, button)
    return (modKey or "") .. "|" .. tostring(button)
end

function Bindings.ParseKey(key)
    if type(key) ~= "string" then return nil end
    local mod, btn = key:match("^([%a%-]*)|(%d+)$")
    if not mod then return nil end
    btn = tonumber(btn)
    if btn < 1 or btn > 31 then return nil end
    if mod ~= "" then
        for part in mod:gmatch("[^%-]+") do
            if not VALID_MODIFIERS[part] then return nil end
        end
        if mod:find("^%-") or mod:find("%-$") or mod:find("%-%-") then return nil end
    end
    return mod, btn
end

local function modSet(modKey)
    local set = {}
    for part in (modKey or ""):gmatch("[^%-]+") do set[part] = true end
    return set
end

-- Blizzard secure prefix for a modifier key; nil if it contains meta.
function Bindings.SecurePrefix(modKey)
    local set = modSet(modKey)
    if set.meta then return nil end
    local prefix = ""
    if set.alt then prefix = prefix .. "alt-" end
    if set.ctrl then prefix = prefix .. "ctrl-" end
    if set.shift then prefix = prefix .. "shift-" end
    return prefix
end

-- True when the combination must go through the override-binding route.
function Bindings.NeedsOverride(modKey, button)
    return button > 5 or modSet(modKey).meta == true
end

-- Binding key string for SetBindingClick, e.g. "ALT-CTRL-META-SHIFT-BUTTON6".
-- NOTE: the META position/spelling is unverified on the Forever Mac client.
function Bindings.OverrideBindingKey(modKey, button)
    local set = modSet(modKey)
    local s = ""
    if set.alt then s = s .. "ALT-" end
    if set.ctrl then s = s .. "CTRL-" end
    if set.shift then s = s .. "SHIFT-" end
    if set.meta then s = s .. "META-" end
    return s .. "BUTTON" .. tostring(button)
end

local function actionFields(action)
    local t = action and action.type
    if t == "spell" then
        return "spell", { spell = action.spell }
    elseif t == "target" then
        return "target", {}
    elseif t == "menu" then
        return "togglemenu", {}
    elseif t == "macro" then
        return "macro", { macrotext = action.macrotext }
    end
    return nil
end

-- Attribute names for a binding: returns typeName, macrotextName, spellName
function Bindings.AttributeNames(modKey, button, slotName)
    if slotName then
        return "*type-" .. slotName, "*macrotext-" .. slotName, "*spell-" .. slotName
    end
    local prefix = Bindings.SecurePrefix(modKey)
    if not prefix then return nil end
    return prefix .. "type" .. button, prefix .. "macrotext" .. button, prefix .. "spell" .. button
end

local function buildAttributes(typeName, macroName, spellName, action)
    local secureType, fields = actionFields(action)
    if not secureType then return nil end
    local attrs = { [typeName] = secureType }
    if fields.spell then attrs[spellName] = fields.spell end
    if fields.macrotext then attrs[macroName] = fields.macrotext end
    return attrs
end

function Bindings.ToAttributes(key, action)
    local mod, button = Bindings.ParseKey(key)
    if not mod or button > 5 then return nil end
    local typeName, macroName, spellName = Bindings.AttributeNames(mod, button)
    if not typeName then return nil end
    return buildAttributes(typeName, macroName, spellName, action)
end

-- Plain attributes for any button 1..31 (nil for meta combos).
function Bindings.ToPhysicalAttributes(key, action)
    local mod, button = Bindings.ParseKey(key)
    if not mod then return nil end
    local typeName, macroName, spellName = Bindings.AttributeNames(mod, button)
    if not typeName then return nil end
    return buildAttributes(typeName, macroName, spellName, action), typeName, macroName
end

-- Attributes for the override-binding route (button 6+ / meta); slotName like "HFB1".
function Bindings.ToOverrideAttributes(slotName, action)
    local typeName, macroName, spellName = Bindings.AttributeNames(nil, nil, slotName)
    return buildAttributes(typeName, macroName, spellName, action)
end

function Bindings.FilterForModifier(bindings, modKey)
    local out = {}
    for key, action in pairs(bindings or {}) do
        local mod, button = Bindings.ParseKey(key)
        if mod and mod == (modKey or "") then
            out[#out + 1] = { button = button, action = action }
        end
    end
    table.sort(out, function(a, b) return a.button < b.button end)
    return out
end

-- Combos that have bindings: array of { modKey=, count= }, "" first, then by modifier count, then name.
function Bindings.SummarizeCombos(bindings)
    local counts = {}
    for key in pairs(bindings or {}) do
        local mod = Bindings.ParseKey(key)
        if mod then counts[mod] = (counts[mod] or 0) + 1 end
    end
    local out = {}
    for mod, n in pairs(counts) do out[#out + 1] = { modKey = mod, count = n } end
    local function size(m)
        if m == "" then return 0 end
        return select(2, m:gsub("%-", "")) + 1
    end
    table.sort(out, function(a, b)
        if a.modKey == "" or b.modKey == "" then return a.modKey == "" and b.modKey ~= "" end
        local sa, sb = size(a.modKey), size(b.modKey)
        if sa ~= sb then return sa < sb end
        return a.modKey < b.modKey
    end)
    return out
end

function Bindings.ButtonLabel(n)
    if n == 1 then return "Left" end
    if n == 2 then return "Right" end
    if n == 3 then return "Middle" end
    return "Mouse " .. tostring(n)
end

function Bindings.HasMeta(modKey)
    return modSet(modKey).meta == true
end

-- ModifierLabel plus a "(Win key)" warning on non-Mac clients for combos that include meta.
function Bindings.DisplayLabel(modKey, isMac)
    local label = Bindings.ModifierLabel(modKey, isMac)
    if not isMac and Bindings.HasMeta(modKey) then label = label .. " (Win key)" end
    return label
end

function Bindings.ModifierLabel(modKey, isMac)
    local set = modSet(modKey)
    local names = {
        shift = "Shift", ctrl = "Ctrl",
        alt = isMac and "Option" or "Alt",
        meta = isMac and "Cmd" or "Win",
    }
    local parts = {}
    for _, m in ipairs(MODIFIER_ORDER) do
        if set[m] then parts[#parts + 1] = names[m] end
    end
    if #parts == 0 then return "No modifier" end
    return table.concat(parts, " + ")
end

-- Macro used for spell bindings so that the alive -> dead switch works in combat with no
-- addon-side SetAttribute: the secure macro conditional [@unit,dead] is evaluated by the game.
-- Every clause names the exact unit and there is NO trailing bare clause: if the unit is missing, not
-- visible or unreachable the game refuses the cast ("Out of range", "Target not in line of sight") instead of
-- falling back to yourself or your current target (which type=spell + autoSelfCast would do).
function Bindings.BuildMacroText(unit, spellName, resSpellName, resOutOfCombatName)
    if not unit or not spellName then return nil end
    local text = "/cast "
    if resSpellName then
        if resOutOfCombatName then
            text = text .. "[@" .. unit .. ",dead,nocombat] " .. resOutOfCombatName .. "; "
        end
        text = text .. "[@" .. unit .. ",dead] " .. resSpellName .. "; "
    end
    return text .. "[@" .. unit .. ",help,nodead] " .. spellName
end

function Bindings.BuildTargetMacro(unit, resSpellName, resOutOfCombatName)
    if not unit then return nil end
    if not resSpellName then
        return "/target [@" .. unit .. "]"
    end
    return Bindings.BuildResOnlyMacro(unit, resSpellName, resOutOfCombatName) .. "\n/target [@" .. unit .. ",nodead]"
end

function Bindings.BuildResOnlyMacro(unit, resSpellName, resOutOfCombatName)
    if not unit or not resSpellName then return nil end
    local text = "/cast "
    if resOutOfCombatName then
        text = text .. "[@" .. unit .. ",dead,nocombat] " .. resOutOfCombatName .. "; "
    end
    return text .. "[@" .. unit .. ",dead] " .. resSpellName
end
