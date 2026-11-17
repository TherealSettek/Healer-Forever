local ADDON_NAME, ns = ...

-- Spell list for the Class Spells pane, the click-cast Pick menu and the buff options.
-- BuildList is pure (no WoW API). Scan() builds the raw entries from the player's actual spellbook
-- and talents at runtime so talent-granted and Forever-specific spells appear automatically.
local Spells = {}
ns.Spells = Spells

local issecret = ns.issecret

Spells.GROUPS = {
    { key = "healing", title = "Healing" },
    { key = "buffs", title = "Blessings / Buffs" },
    { key = "other", title = "Utility / Other" },
}

-- Pure ------------------------------------------------------------------------------------------

local function nameSet(list)
    local set = {}
    if type(list) ~= "table" then return set end
    for k, v in pairs(list) do
        if type(v) == "string" then
            set[v] = true
        elseif type(v) == "table" and type(v.name) == "string" then
            set[v.name] = true
        elseif type(k) == "string" and v then
            set[k] = true
        end
    end
    return set
end

-- rawEntries: array of { spellID, name, isPassive, isKnown, icon }
-- curated: { healing = {...}, buffs = {...}, utility = {...} } (strings, {name=} tables or name sets)
-- returns { healing = {...}, buffs = {...}, other = {...} }, each sorted by name, deduped by name
function Spells.BuildList(rawEntries, curated)
    curated = curated or {}
    local healing, buffs = nameSet(curated.healing), nameSet(curated.buffs)
    local best = {}
    for _, e in ipairs(rawEntries or {}) do
        if type(e) == "table" and type(e.name) == "string" and e.name ~= "" and not e.isPassive
            and e.isKnown ~= false then
            local current = best[e.name]
            if not current or (tonumber(e.spellID) or 0) > (tonumber(current.spellID) or 0) then
                best[e.name] = e
            end
        end
    end
    local out = { healing = {}, buffs = {}, other = {} }
    for name, e in pairs(best) do
        local group = healing[name] and "healing" or (buffs[name] and "buffs" or "other")
        local list = out[group]
        list[#list + 1] = { spellID = e.spellID, name = name, icon = e.icon }
    end
    for _, list in pairs(out) do
        table.sort(list, function(a, b)
            local la, lb = a.name:lower(), b.name:lower()
            if la ~= lb then return la < lb end
            return a.name < b.name
        end)
    end
    return out
end

-- Runtime -----------------------------------------------------------------------------------------

local function spellInfo(spell)
    if C_Spell and C_Spell.GetSpellInfo and spell then
        local ok, info = pcall(C_Spell.GetSpellInfo, spell)
        if ok and type(info) == "table" and info.name and not issecret(info.name) then return info end
    end
end

local function isPassive(id)
    if C_Spell and C_Spell.IsSpellPassive then
        local ok, v = pcall(C_Spell.IsSpellPassive, id)
        if ok and not issecret(v) then return v and true or false end
    elseif IsPassiveSpell then
        local ok, v = pcall(IsPassiveSpell, id)
        if ok and not issecret(v) then return v and true or false end
    end
    return false
end

local function addRaw(raw, id, knownOverride)
    if not id or issecret(id) then return end
    local overrideID = id
    if C_Spell and C_Spell.GetOverrideSpell then
        local ok, o = pcall(C_Spell.GetOverrideSpell, id)
        if ok and type(o) == "number" and not issecret(o) and o ~= id then overrideID = o end
    end
    local info = spellInfo(overrideID) or spellInfo(id)
    if not info then return end
    raw[#raw + 1] = {
        spellID = info.spellID or overrideID, name = info.name,
        isPassive = isPassive(info.spellID or overrideID), isKnown = knownOverride ~= false,
        icon = info.iconID or info.originalIconID,
    }
end

local function scanSkillLines(raw)
    local book = C_SpellBook
    if not (book and book.GetNumSpellBookSkillLines and book.GetSpellBookSkillLineInfo and book.GetSpellBookItemInfo
        and Enum and Enum.SpellBookSpellBank) then
        return false
    end
    local lines = book.GetNumSpellBookSkillLines()
    for i = 1, lines do
        local info = book.GetSpellBookSkillLineInfo(i)
        -- the first line is the General tab (professions, mounts): skip it when class lines exist
        if info and not (i == 1 and lines > 1) then
            local offset, count = info.itemIndexOffset or 0, info.numSpellBookItems or 0
            for j = offset + 1, offset + count do
                local item = book.GetSpellBookItemInfo(j, Enum.SpellBookSpellBank.Player)
                if item and item.spellID and not item.isOffSpec and not item.isPassive then
                    local t = item.itemType
                    local isSpell = (Enum.SpellBookItemType == nil) or t == Enum.SpellBookItemType.Spell
                    if isSpell then addRaw(raw, item.spellID) end
                end
            end
        end
    end
    return true
end

local function scanLegacy(raw)
    if not (GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemName) then return false end
    for tab = 2, GetNumSpellTabs() do
        local _, _, offset, count = GetSpellTabInfo(tab)
        for j = (offset or 0) + 1, (offset or 0) + (count or 0) do
            local name = GetSpellBookItemName(j, "spell")
            local info = spellInfo(name)
            if info and not (IsPassiveSpell and IsPassiveSpell(j, "spell")) then
                raw[#raw + 1] = { spellID = info.spellID, name = info.name, isPassive = false, isKnown = true,
                    icon = info.iconID }
            end
        end
    end
    return true
end

-- Purchased talent nodes granting active spells (guarded; the structure may differ on Forever).
local function scanTalents(raw)
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits) then return end
    pcall(function()
        local configID = C_ClassTalents.GetActiveConfigID()
        if not configID then return end
        local config = C_Traits.GetConfigInfo(configID)
        for _, treeID in ipairs(config and config.treeIDs or {}) do
            for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
                local node = C_Traits.GetNodeInfo(configID, nodeID)
                local entryID = node and (node.currentRank or 0) > 0 and node.activeEntry and node.activeEntry.entryID
                if entryID then
                    local entry = C_Traits.GetEntryInfo(configID, entryID)
                    local def = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
                    if def and def.spellID and not isPassive(def.spellID) then addRaw(raw, def.spellID) end
                end
            end
        end
    end)
end

function Spells.Curated(classToken)
    local data = ns.Classes.DATA[classToken]
    local hints = { healing = {}, buffs = {}, utility = {} }
    if not data then return hints end
    for _, s in ipairs(data.heals or {}) do hints.healing[#hints.healing + 1] = s.name end
    for _, key in ipairs(ns.Classes.CatalogBuffs(classToken)) do
        local def = ns.Classes.BUFFS[key]
        hints.buffs[#hints.buffs + 1] = def.name
        if def.groupSpell then hints.buffs[#hints.buffs + 1] = def.groupSpell end
    end
    for _, s in ipairs(data.buffSpells or {}) do hints.buffs[#hints.buffs + 1] = s.name end
    for _, s in ipairs(data.utility or {}) do hints.utility[#hints.utility + 1] = s.name end
    if data.res then hints.utility[#hints.utility + 1] = data.res end
    if data.resOutOfCombat then hints.utility[#hints.utility + 1] = data.resOutOfCombat end
    return hints
end

function Spells.Scan()
    local raw = {}
    local ok = pcall(function()
        if not scanSkillLines(raw) then scanLegacy(raw) end
    end)
    if not ok then raw = {} end
    scanTalents(raw)

    local class = ns.PlayerClass()
    local hints = class and Spells.Curated(class) or { healing = {}, buffs = {}, utility = {} }
    -- curated spells the scans missed but the player knows (talents, overrides)
    local seen = {}
    for _, e in ipairs(raw) do seen[e.name] = true end
    for _, list in pairs(hints) do
        for _, name in ipairs(list) do
            if not seen[name] and ns.SpellKnown(name) then
                addRaw(raw, (spellInfo(name) or {}).spellID)
                seen[name] = true
            end
        end
    end
    -- user-added spells
    for _, c in ipairs(ns.db and ns.db.customSpells or {}) do
        if type(c) == "table" and type(c.name) == "string" and not seen[c.name] then
            local info = spellInfo(c.name) or spellInfo(c.id)
            raw[#raw + 1] = { spellID = info and info.spellID or c.id, name = c.name, isPassive = false,
                isKnown = true, icon = info and info.iconID }
            seen[c.name] = true
        end
    end

    if #raw == 0 and class then
        -- no spellbook API: fall back to the curated tables filtered by what the player knows
        for _, list in pairs(hints) do
            for _, name in ipairs(list) do
                if ns.SpellKnown(name) then
                    raw[#raw + 1] = { spellID = (spellInfo(name) or {}).spellID, name = name, isPassive = false,
                        isKnown = true }
                end
            end
        end
    end
    local names = {}
    for _, e in ipairs(raw) do
        if e.isKnown ~= false and not e.isPassive then names[e.name] = true end
    end
    Spells.knownNames = names
    return Spells.BuildList(raw, hints)
end

-- Uses the last scan only (never triggers one), so ns.SpellKnown can call it from inside Scan.
function Spells.IsKnownByName(name)
    return Spells.knownNames ~= nil and Spells.knownNames[name] == true
end

local cache, dirty = nil, true

function Spells.GetList()
    if dirty or not cache then
        cache = Spells.Scan()
        dirty = false
    end
    return cache
end

function Spells.Invalidate()
    dirty = true
    if Spells.pending then return end
    Spells.pending = true
    local function fire()
        Spells.pending = false
        ns:Fire("SPELLS_UPDATED")
    end
    if C_Timer and C_Timer.After then C_Timer.After(0.5, fire) else fire() end
end

function Spells.AddCustom(name)
    local info = spellInfo(name)
    if not info then return false end
    for _, c in ipairs(ns.db.customSpells) do
        if c.name == info.name then return true end
    end
    ns.db.customSpells[#ns.db.customSpells + 1] = { name = info.name, id = info.spellID }
    Spells.Invalidate()
    return true, info.name
end

for _, event in ipairs({ "SPELLS_CHANGED", "PLAYER_TALENT_UPDATE", "TRAIT_CONFIG_UPDATED",
    "ACTIVE_TALENT_GROUP_CHANGED" }) do
    ns:RegisterEvent(event, function() Spells.Invalidate() end)
end
