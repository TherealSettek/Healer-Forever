local ADDON_NAME, ns = ...

ns.Presets = ns.Presets or {}
local Presets = ns.Presets

-- Preset model (schema 4):
--   { name = "...", self = nil | { buffKey, ... },
--     map = { PALADIN = { DEFAULT = { "wisdom" }, TANK = { "might" }, ... }, PRIEST = { DEFAULT = { "fortitude", "spirit" } } },
--     extras = { ... } }
-- A cell is a SET of buff keys, at most one per catalog group (see Classes.BUFF_CATALOG). An empty set means "no
-- buff"; a missing role entry falls back to DEFAULT. Older saves held a single key string (or "none") per cell.

local FALLBACK_ROLES = {
    WARRIOR = { "TANK", "DAMAGER" }, PALADIN = { "TANK", "HEALER", "DAMAGER" }, HUNTER = { "DAMAGER" },
    ROGUE = { "DAMAGER" }, PRIEST = { "HEALER", "DAMAGER" }, SHAMAN = { "HEALER", "DAMAGER" },
    MAGE = { "DAMAGER" }, WARLOCK = { "DAMAGER" }, DRUID = { "TANK", "HEALER", "DAMAGER" },
}

local function rolesTable()
    return (ns.Classes and ns.Classes.ROLES) or FALLBACK_ROLES
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepCopy(x) end
    return out
end

-- Any stored cell value (legacy string / "none" / array) -> a fresh array of buff keys, or nil if not a cell value.
local function toSet(value)
    if type(value) == "string" then
        if value == "" or value == "none" then return {} end
        return { value }
    elseif type(value) == "table" then
        local out, seen = {}, {}
        for _, key in ipairs(value) do
            if type(key) == "string" and key ~= "none" and key ~= "" and not seen[key] then
                seen[key] = true
                out[#out + 1] = key
            end
        end
        return out
    end
    return nil
end

local function buffOrder(key)
    return ns.Classes and ns.Classes.BuffOrder and ns.Classes.BuffOrder(key) or 999
end

local function buffGroup(key)
    return ns.Classes and ns.Classes.BuffGroup and ns.Classes.BuffGroup(key) or nil
end

local function ordered(list)
    table.sort(list, function(x, y)
        local ox, oy = buffOrder(x), buffOrder(y)
        if ox ~= oy then return ox < oy end
        return x < y
    end)
    return list
end

local function isValidRole(classToken, role)
    if role == "DEFAULT" then return rolesTable()[classToken] ~= nil end
    for _, r in ipairs(rolesTable()[classToken] or {}) do
        if r == role then return true end
    end
    return false
end

-- Default presets ------------------------------------------------------------------------------

local CLASS_LIST = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local function build(name, rules, default)
    local map = {}
    for _, class in ipairs(CLASS_LIST) do
        map[class] = { DEFAULT = { default } }
    end
    for class, entry in pairs(rules or {}) do
        for role, key in pairs(entry) do map[class][role] = { key } end
    end
    return { name = name, map = map, extras = {} }
end

-- Old shipped presets: private templates, used only to migrate saved presets and for the Paladin example.
local LEGACY = {
    build("5-man Dungeon", {
        WARRIOR = { DEFAULT = "might", TANK = "kings", DAMAGER = "might" },
        PALADIN = { DEFAULT = "wisdom", TANK = "might", HEALER = "wisdom", DAMAGER = "might" },
        HUNTER = { DEFAULT = "might", DAMAGER = "might" },
        ROGUE = { DEFAULT = "might", DAMAGER = "might" },
        PRIEST = { DEFAULT = "wisdom", HEALER = "wisdom", DAMAGER = "wisdom" },
        SHAMAN = { DEFAULT = "wisdom", HEALER = "wisdom", DAMAGER = "wisdom" },
        MAGE = { DEFAULT = "wisdom", DAMAGER = "wisdom" },
        WARLOCK = { DEFAULT = "wisdom", DAMAGER = "wisdom" },
        DRUID = { DEFAULT = "wisdom", TANK = "kings", HEALER = "wisdom", DAMAGER = "wisdom" },
    }, "wisdom"),
    build("Raid - Group 1", nil, "kings"),
    build("Raid - Group 2", nil, "light"),
    build("Salv Duty", {
        WARRIOR = { TANK = "kings" },
        PALADIN = { TANK = "kings" },
        DRUID = { TANK = "kings" },
    }, "salvation"),
}

-- Shipped default: ONE empty preset (no buff rules, so no buff buttons until the user adds some).
Presets.DEFAULTS = {
    { name = "Default", map = {}, extras = {} },
}

-- Pure rules -------------------------------------------------------------------------------------

-- Ordered array of the buff keys assigned to a cell (never nil). isSelf + preset.self wins over the class rules.
function Presets.CellBuffs(preset, classToken, role, isSelf)
    if type(preset) ~= "table" then return {} end
    if isSelf and preset.self ~= nil then
        return ordered(toSet(preset.self) or {})
    end
    local entry = type(preset.map) == "table" and preset.map[classToken]
    if type(entry) == "string" then return ordered(toSet(entry) or {}) end
    if type(entry) ~= "table" then return {} end
    if role and role ~= "DEFAULT" and isValidRole(classToken, role) and entry[role] ~= nil then
        return ordered(toSet(entry[role]) or {})
    end
    return ordered(toSet(entry.DEFAULT) or {})
end

-- First buff of the cell, or nil (kept for callers that handle a single buff).
function Presets.ResolveBuff(preset, classToken, role, isSelf)
    return Presets.CellBuffs(preset, classToken, role, isSelf)[1]
end

local function auraMatches(def)
    local ids, names = {}, {}
    for _, id in ipairs(def.spellIds or {}) do ids[id] = true end
    for _, n in ipairs(def.names or {}) do names[n] = true end
    return function(aura)
        return (aura.spellId and ids[aura.spellId]) or (aura.name and names[aura.name])
    end
end

-- Per assigned buff: { key, missing, auraName, remaining, pct, rule }. A buff counts as missing when no matching aura
-- exists, or (permanent auras never expire) the best matching aura is running out:
--   rebuffPercent given (a number): remaining < rebuffPercent% of the aura's duration (0 = only when gone),
--   otherwise: remaining < threshold seconds (the older rule, kept for role buffs and existing callers).
function Presets.BuffReport(classToken, auras, preset, now, buffDefs, threshold, role, isSelf, rebuffPercent)
    local out = {}
    threshold = threshold or 60
    now = now or 0
    local usePercent = type(rebuffPercent) == "number"
    for _, key in ipairs(Presets.CellBuffs(preset, classToken, role, isSelf)) do
        local def = buffDefs and buffDefs[key]
        local item = { key = key, missing = true,
            rule = usePercent and (rebuffPercent .. "% of its duration") or (threshold .. "s") }
        if def then
            local matches = auraMatches(def)
            for _, aura in ipairs(auras or {}) do
                if matches(aura) then
                    local exp = aura.expirationTime or 0
                    local remaining = exp > 0 and (exp - now) or nil
                    local duration = type(aura.duration) == "number" and aura.duration > 0 and aura.duration or nil
                    local expiring
                    if exp == 0 then
                        expiring = false
                    elseif usePercent then
                        if remaining <= 0 then
                            expiring = true
                        elseif rebuffPercent > 0 and duration then
                            expiring = remaining < duration * rebuffPercent / 100
                        else
                            expiring = false
                        end
                    else
                        expiring = remaining < threshold
                    end
                    if not item.auraName or not expiring then
                        item.auraName = aura.name
                        item.remaining = remaining
                        item.pct = (remaining and duration) and (remaining / duration * 100) or nil
                    end
                    if not expiring then
                        item.missing = false
                        break
                    end
                end
            end
        end
        out[#out + 1] = item
    end
    return out
end

-- Ordered list (catalog order) of the cell's buffs that are missing, or running out (see BuffReport).
function Presets.GetMissingBuffs(classToken, auras, preset, now, buffDefs, threshold, role, isSelf, rebuffPercent)
    local out = {}
    for _, item in ipairs(Presets.BuffReport(classToken, auras, preset, now, buffDefs, threshold, role, isSelf,
        rebuffPercent)) do
        if item.missing then out[#out + 1] = item.key end
    end
    return out
end

function Presets.GetMissingBuff(classToken, auras, preset, now, buffDefs, threshold, role, isSelf, rebuffPercent)
    return Presets.GetMissingBuffs(classToken, auras, preset, now, buffDefs, threshold, role, isSelf, rebuffPercent)[1]
end

local function convertPreset(p)
    for class, entry in pairs(p.map) do
        if type(entry) == "string" then
            p.map[class] = { DEFAULT = toSet(entry) }
        elseif type(entry) == "table" then
            for role, value in pairs(entry) do
                local set = toSet(value)
                if set then entry[role] = ordered(set) else entry[role] = nil end
            end
        end
    end
    if p.self ~= nil then
        local set = toSet(p.self)
        p.self = set and ordered(set) or nil
    end
end

function Presets.MigratePreset(p)
    if type(p) ~= "table" then return p end
    if type(p.map) ~= "table" then p.map = {} end
    if type(p.extras) ~= "table" then p.extras = {} end
    convertPreset(p)
    -- classes missing from an OLD saved preset take the matching legacy template's rule; a brand-new empty
    -- preset stays empty (independent of the shipped defaults)
    local source
    for _, d in ipairs(LEGACY) do
        if d.name == p.name then source = d end
    end
    if not source and next(p.map) ~= nil then source = LEGACY[1] end
    source = source or { map = {} }
    for class in pairs(rolesTable()) do
        local entry = p.map[class]
        if type(entry) ~= "table" then
            -- class missing entirely: take the legacy rule (or no buff)
            local legacy = source.map[class] and source.map[class].DEFAULT
            p.map[class] = { DEFAULT = legacy and deepCopy(legacy) or {} }
        elseif entry.DEFAULT == nil then
            -- an existing entry without DEFAULT means "no buff" by default
            entry.DEFAULT = {}
        end
    end
    return p
end

local function ensureEntry(preset, classToken)
    if type(preset.map) ~= "table" then preset.map = {} end
    local entry = preset.map[classToken]
    if type(entry) == "string" then entry = { DEFAULT = toSet(entry) } end
    if type(entry) ~= "table" then entry = { DEFAULT = {} } end
    preset.map[classToken] = entry
    return entry
end

-- The cell's current set to edit: an inheriting role cell starts from a copy of the DEFAULT set.
local function editableSet(entry, role)
    local current = entry[role]
    if current == nil then
        current = role == "DEFAULT" and {} or (toSet(entry.DEFAULT) or {})
    end
    return toSet(current) or {}
end

-- Turns one buff on or off in a cell. Turning a buff on replaces any other buff of the same catalog group.
function Presets.SetCellBuff(preset, classToken, role, key, on)
    if type(preset) ~= "table" or type(key) ~= "string" or not isValidRole(classToken, role) then return false end
    local entry = ensureEntry(preset, classToken)
    local group = buffGroup(key)
    local out = {}
    for _, k in ipairs(editableSet(entry, role)) do
        if k ~= key and not (on and group and buffGroup(k) == group) then out[#out + 1] = k end
    end
    if on then out[#out + 1] = key end
    entry[role] = ordered(out)
    return true
end

-- "None" for a group: removes every buff of that group from the cell.
function Presets.ClearGroup(preset, classToken, role, groupId)
    if type(preset) ~= "table" or not isValidRole(classToken, role) then return false end
    local entry = ensureEntry(preset, classToken)
    local out = {}
    for _, k in ipairs(editableSet(entry, role)) do
        if buffGroup(k) ~= groupId then out[#out + 1] = k end
    end
    entry[role] = ordered(out)
    return true
end

-- Same operations for the "Self (you)" set (preset.self; nil = use the class/role rules).
function Presets.SetSelfBuff(preset, key, on)
    if type(preset) ~= "table" or type(key) ~= "string" then return false end
    local group = buffGroup(key)
    local out = {}
    for _, k in ipairs(toSet(preset.self) or {}) do
        if k ~= key and not (on and group and buffGroup(k) == group) then out[#out + 1] = k end
    end
    if on then out[#out + 1] = key end
    preset.self = ordered(out)
    return true
end

function Presets.ClearSelfGroup(preset, groupId)
    if type(preset) ~= "table" then return false end
    local out = {}
    for _, k in ipairs(toSet(preset.self) or {}) do
        if buffGroup(k) ~= groupId then out[#out + 1] = k end
    end
    preset.self = ordered(out)
    return true
end

function Presets.SetRule(preset, classToken, role, buffKey)
    if type(preset) ~= "table" or not isValidRole(classToken, role) then return false end
    local entry = ensureEntry(preset, classToken)
    if buffKey == nil or buffKey == "none" then
        if role == "DEFAULT" then entry.DEFAULT = {} else entry[role] = nil end
    else
        entry[role] = { buffKey }
    end
    return true
end

-- nil = use the class/role rules; "none" = no buff; a key or array = exactly that set
function Presets.SetSelf(preset, value)
    if type(preset) ~= "table" then return false end
    if value == nil then
        preset.self = nil
    else
        preset.self = ordered(toSet(value) or {})
    end
    return true
end

-- Role buffs (extra targeted buffs) ---------------------------------------------------------------------
-- preset.extras = { { spell = "Name", roles = { TANK = true, SELF = true }, single = true }, ... }

function Presets.ResolveExtras(preset, role, isSelf)
    local out = {}
    if type(preset) ~= "table" or type(preset.extras) ~= "table" then return out end
    for _, entry in ipairs(preset.extras) do
        local roles = type(entry) == "table" and entry.roles
        if type(roles) == "table" then
            local match
            if isSelf then
                match = roles.SELF
            else
                match = role and role ~= "NONE" and roles[role]
            end
            if match then out[#out + 1] = entry end
        end
    end
    return out
end

function Presets.GetMissingExtra(entry, auras, now, threshold, castByMeElsewhere)
    if type(entry) ~= "table" then return false end
    if entry.single and castByMeElsewhere then return false end
    threshold = threshold or 60
    now = now or 0
    for _, aura in ipairs(auras or {}) do
        if (entry.spellId and aura.spellId == entry.spellId) or (entry.spell and aura.name == entry.spell) then
            local exp = aura.expirationTime or 0
            if exp == 0 or exp - now >= threshold then
                return false
            end
        end
    end
    return true
end

function Presets.AddExtra(preset, spell, roles, single)
    if type(preset) ~= "table" or type(spell) ~= "string" or trim(spell) == "" then return nil end
    if type(preset.extras) ~= "table" then preset.extras = {} end
    local copy = {}
    for k, v in pairs(roles or {}) do
        if v then copy[k] = true end
    end
    preset.extras[#preset.extras + 1] = { spell = trim(spell), roles = copy, single = single and true or false }
    return #preset.extras
end

function Presets.RemoveExtra(preset, index)
    if type(preset) ~= "table" or type(preset.extras) ~= "table" or not preset.extras[index] then return false end
    table.remove(preset.extras, index)
    return true
end

-- Chooses the next buff to cast from a pending list of { unit, role, kind = "extra"|"blessing", spell }.
-- Priority: role buffs, then blessings for tank, healer, DPS, other roles, and finally yourself.
-- Ties are ordered by unit token, then by list position.
function Presets.PickNext(pendingList)
    if type(pendingList) ~= "table" then return nil end
    local function rank(e)
        if e.kind == "extra" then return 0 end
        if e.unit == "player" or e.isSelf then return 5 end
        if e.role == "TANK" then return 1 end
        if e.role == "HEALER" then return 2 end
        if e.role == "DAMAGER" then return 3 end
        return 4
    end
    local best, bestRank, bestIndex
    for i, e in ipairs(pendingList) do
        if type(e) == "table" then
            local r = rank(e)
            local better = false
            if not best or r < bestRank then
                better = true
            elseif r == bestRank then
                local u1, u2 = tostring(e.unit), tostring(best.unit)
                if u1 < u2 then better = true end
            end
            if better then best, bestRank, bestIndex = e, r, i end
        end
    end
    return best, bestIndex
end

-- List management ------------------------------------------------------------------------------------

function Presets.Add(list, name, copyFromIndex)
    name = trim(name)
    if name == "" then name = "Preset " .. (#list + 1) end
    local source = copyFromIndex and list[copyFromIndex]
    local p = { name = name, map = deepCopy(source and source.map or {}), self = source and source.self or nil,
        extras = deepCopy(source and source.extras or {}) }
    Presets.MigratePreset(p)
    list[#list + 1] = p
    return #list
end

function Presets.Remove(list, index)
    if #list <= 1 or type(index) ~= "number" or not list[index] then
        return false
    end
    table.remove(list, index)
    return true
end

function Presets.Rename(list, index, name)
    name = trim(name)
    if name == "" or not list[index] then return false end
    list[index].name = name
    return true
end

-- Opt-in examples. Each returns a NEW preset table; the caller adds it (nothing is ever overwritten).
-- Paladin: the old shipped 5-man blessing rules.
function Presets.ExamplePaladin()
    local p = deepCopy(LEGACY[1])
    p.name = "Example: Paladin 5-man"
    return p
end

local MELEE = { WARRIOR = true, ROGUE = true, HUNTER = true }

Presets.EXAMPLE_CLASSES = { "PALADIN", "PRIEST", "MAGE", "DRUID" }

function Presets.ExampleFor(classToken)
    if classToken == "PALADIN" then return Presets.ExamplePaladin() end
    local names = { PRIEST = "Priest", MAGE = "Mage", DRUID = "Druid" }
    if not names[classToken] then return nil end
    local p = { name = "Example: " .. names[classToken], map = {}, extras = {} }
    for _, target in ipairs(CLASS_LIST) do
        local entry = {}
        local roles = { "DEFAULT" }
        for _, r in ipairs(rolesTable()[target] or {}) do roles[#roles + 1] = r end
        for _, role in ipairs(roles) do
            local set = {}
            if classToken == "PRIEST" then
                set[#set + 1] = "fortitude"
                if not MELEE[target] and role ~= "TANK" then set[#set + 1] = "spirit" end
                if role == "TANK" then set[#set + 1] = "shadowprot" end
            elseif classToken == "MAGE" then
                set[#set + 1] = "arcaneint"
                if role == "HEALER" then set[#set + 1] = "amplify" end
                if role == "TANK" then set[#set + 1] = "dampen" end
            else
                set[#set + 1] = "motw"
                if role == "TANK" then set[#set + 1] = "thorns" end
            end
            entry[role] = ordered(set)
        end
        p.map[target] = entry
    end
    return p
end
