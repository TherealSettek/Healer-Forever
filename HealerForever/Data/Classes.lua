local ADDON_NAME, ns = ...

-- Static class data. Pure tables plus lookups; availability of spells is resolved at runtime
-- (see ns.SpellKnown in Core.lua). Spell IDs are best-effort; names are always used as fallback.
ns.Classes = ns.Classes or {}
local Classes = ns.Classes

Classes.ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

Classes.NAMES = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}

-- Roles a class can fill (used by the preset UI and for validation).
Classes.ROLES = {
    WARRIOR = { "TANK", "DAMAGER" },
    PALADIN = { "TANK", "HEALER", "DAMAGER" },
    HUNTER = { "DAMAGER" },
    ROGUE = { "DAMAGER" },
    PRIEST = { "HEALER", "DAMAGER" },
    SHAMAN = { "HEALER", "DAMAGER" },
    MAGE = { "DAMAGER" },
    WARLOCK = { "DAMAGER" },
    DRUID = { "TANK", "HEALER", "DAMAGER" },
}

Classes.ROLE_LABELS = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS", DEFAULT = "Default" }

function Classes.IsValidRole(classToken, role)
    local roles = Classes.ROLES[classToken]
    if not roles then return false end
    if role == "DEFAULT" then return true end
    for _, r in ipairs(roles) do
        if r == role then return true end
    end
    return false
end

Classes.COLORS = {
    WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
    PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
    HUNTER  = { r = 0.67, g = 0.83, b = 0.45 },
    ROGUE   = { r = 1.00, g = 0.96, b = 0.41 },
    PRIEST  = { r = 1.00, g = 1.00, b = 1.00 },
    SHAMAN  = { r = 0.00, g = 0.44, b = 0.87 },
    MAGE    = { r = 0.25, g = 0.78, b = 0.92 },
    WARLOCK = { r = 0.53, g = 0.53, b = 0.93 },
    DRUID   = { r = 1.00, g = 0.49, b = 0.04 },
}

Classes.POWER_COLORS = {
    MANA = { r = 0.00, g = 0.44, b = 0.87 },
    RAGE = { r = 0.77, g = 0.12, b = 0.23 },
    FOCUS = { r = 1.00, g = 0.50, b = 0.25 },
    ENERGY = { r = 1.00, g = 0.96, b = 0.41 },
}

-- Per-class data. res = resurrection spell, resOutOfCombat = optional extra out-of-combat res.
Classes.DATA = {
    PALADIN = {
        power = "MANA",
        res = "Redemption",
        resId = 7328,
        heals = {
            { name = "Flash of Light", id = 19750 },
            { name = "Holy Light", id = 635 },
            { name = "Holy Shock", id = 20473 },
            { name = "Lay on Hands", id = 633 },
            { name = "Divine Favor", id = 31842 },
            -- WoW Forever Holy capstone talent: 30s on a target, next Holy Shock has no cooldown and
            -- heals the target's group. Name taken from kami-labs.fr; ID resolved at runtime.
            { name = "Light's Vigil" },
        },
        utility = {
            { name = "Cleanse", id = 4987 },
            { name = "Purify", id = 1152 },
            { name = "Blessing of Protection", id = 1022 },
            { name = "Blessing of Freedom", id = 1044 },
            { name = "Holy Strike" },
            { name = "Hammer of the Righteous" },
            { name = "Templar's Bulwark" },
        },
        -- Targeted ally buffs that are not class-wide (good for click-casting, not for presets).
        -- "Oath of Light" is reported by the community (one target at a time) but was not found in the
        -- researched guides; it only appears if the spellbook/talent scan finds it.
        buffSpells = { { name = "Oath of Light" } },
        blessings = { "might", "wisdom", "kings", "salvation", "light", "sanctuary" },
        dispels = { "Magic", "Poison", "Disease" },
    },
    PRIEST = {
        power = "MANA",
        res = "Resurrection",
        resId = 2006,
        heals = { { name = "Flash Heal" }, { name = "Heal" }, { name = "Renew" }, { name = "Power Word: Shield" } },
        utility = { { name = "Dispel Magic" }, { name = "Abolish Disease" } },
        blessings = {},
        dispels = { "Magic", "Disease" },
    },
    SHAMAN = {
        power = "MANA",
        res = "Ancestral Spirit",
        resId = 2008,
        heals = { { name = "Healing Wave" }, { name = "Lesser Healing Wave" }, { name = "Chain Heal" } },
        utility = { { name = "Cure Poison" }, { name = "Cure Disease" } },
        blessings = {},
        dispels = { "Poison", "Disease" },
    },
    DRUID = {
        power = "MANA",
        res = "Rebirth",
        resId = 20484,
        resOutOfCombat = "Revive",
        heals = { { name = "Healing Touch" }, { name = "Rejuvenation" }, { name = "Regrowth" } },
        utility = { { name = "Remove Curse" }, { name = "Abolish Poison" } },
        blessings = {},
        dispels = { "Curse", "Poison" },
    },
    WARRIOR = { power = "RAGE", heals = {}, utility = {}, blessings = {}, dispels = {} },
    HUNTER = { power = "MANA", heals = {}, utility = {}, blessings = {}, dispels = {} },
    ROGUE = { power = "ENERGY", heals = {}, utility = {}, blessings = {}, dispels = {} },
    MAGE = { power = "MANA", heals = {}, utility = {}, blessings = {}, dispels = {} },
    WARLOCK = { power = "MANA", heals = {}, utility = {}, blessings = {}, dispels = {} },
}

-- Party buff catalog ------------------------------------------------------------------------------------------
-- Every buff the addon knows how to suggest, across all caster classes. key -> { key, name, group, groupSpell,
-- greater (= groupSpell, kept for older code), abbr, color, icon (fallback texture), spellIds, names }.
-- Spell names are vanilla names; only spells the player actually knows are armed (ns.SpellKnown).
Classes.BUFFS = {}

local function buff(key, name, group, groupSpell, abbr, color, icon, spellIds)
    local names = { name }
    if groupSpell then names[#names + 1] = groupSpell end
    Classes.BUFFS[key] = {
        key = key, name = name, group = group, groupSpell = groupSpell, greater = groupSpell, abbr = abbr,
        color = color, icon = "Interface\\Icons\\" .. icon, spellIds = spellIds or {}, names = names,
    }
end

-- Paladin: one group, the blessings exclude each other
buff("might", "Blessing of Might", "blessing", "Greater Blessing of Might", "Mi",
    { r = 0.71, g = 0.27, b = 0.16 }, "Spell_Holy_FistOfJustice", { 19740, 25782 })
buff("wisdom", "Blessing of Wisdom", "blessing", "Greater Blessing of Wisdom", "Wi",
    { r = 0.23, g = 0.44, b = 0.82 }, "Spell_Holy_SealOfWisdom", { 19742, 25894 })
buff("kings", "Blessing of Kings", "blessing", "Greater Blessing of Kings", "Ki",
    { r = 0.63, g = 0.49, b = 0.88 }, "Spell_Magic_MageArmor", { 20217, 25898 })
buff("salvation", "Blessing of Salvation", "blessing", "Greater Blessing of Salvation", "Sa",
    { r = 0.85, g = 0.77, b = 0.42 }, "Spell_Holy_SealOfSalvation", { 1038, 25895 })
buff("light", "Blessing of Light", "blessing", "Greater Blessing of Light", "Li",
    { r = 0.94, g = 0.88, b = 0.48 }, "Spell_Holy_PrayerOfHealing02", { 19977, 25890 })
buff("sanctuary", "Blessing of Sanctuary", "blessing", "Greater Blessing of Sanctuary", "Sn",
    { r = 0.54, g = 0.54, b = 0.54 }, "Spell_Nature_LightningShield", { 20911, 25899 })
-- Priest: each buff is its own group (they stack)
buff("fortitude", "Power Word: Fortitude", "fortitude", "Prayer of Fortitude", "Fo",
    { r = 0.85, g = 0.82, b = 0.6 }, "Spell_Holy_WordFortitude")
buff("spirit", "Divine Spirit", "spirit", "Prayer of Spirit", "Sp",
    { r = 0.48, g = 0.72, b = 0.94 }, "Spell_Holy_DivineSpirit")
buff("shadowprot", "Shadow Protection", "shadowprot", "Prayer of Shadow Protection", "Sh",
    { r = 0.42, g = 0.29, b = 0.63 }, "Spell_Shadow_AntiShadow")
-- Mage: Arcane Intellect is its own group; Dampen / Amplify Magic exclude each other
buff("arcaneint", "Arcane Intellect", "intellect", "Arcane Brilliance", "AI",
    { r = 0.35, g = 0.63, b = 0.94 }, "Spell_Holy_MagicalSentry")
buff("dampen", "Dampen Magic", "magic", nil, "Da",
    { r = 0.54, g = 0.54, b = 0.85 }, "Spell_Nature_AbolishMagic")
buff("amplify", "Amplify Magic", "magic", nil, "Am",
    { r = 0.85, g = 0.54, b = 0.85 }, "Spell_Holy_FlashHeal")
-- Druid: separate groups
buff("motw", "Mark of the Wild", "motw", "Gift of the Wild", "MW",
    { r = 0.35, g = 0.69, b = 0.29 }, "Spell_Nature_Regeneration")
buff("thorns", "Thorns", "thorns", nil, "Th",
    { r = 0.54, g = 0.42, b = 0.16 }, "Spell_Nature_Thorns")

-- Per caster class: ordered groups. multi = true shows radio buttons with "None"; a single-buff group is a checkbox.
-- Classes not listed have an empty catalog (nothing to assign; role buffs still work).
Classes.BUFF_CATALOG = {
    PALADIN = { { id = "blessing", name = "Blessing", multi = true,
        buffs = { "might", "wisdom", "kings", "salvation", "light", "sanctuary" } } },
    PRIEST = {
        { id = "fortitude", name = "Fortitude", buffs = { "fortitude" } },
        { id = "spirit", name = "Divine Spirit", buffs = { "spirit" } },
        { id = "shadowprot", name = "Shadow Protection", buffs = { "shadowprot" } },
    },
    MAGE = {
        { id = "intellect", name = "Intellect", buffs = { "arcaneint" } },
        { id = "magic", name = "Magic", multi = true, buffs = { "dampen", "amplify" } },
    },
    DRUID = {
        { id = "motw", name = "Mark of the Wild", buffs = { "motw" } },
        { id = "thorns", name = "Thorns", buffs = { "thorns" } },
    },
}

-- Older code (and the Paladin spell list) still read this
Classes.BUFF_ORDER = { "might", "wisdom", "kings", "salvation", "light", "sanctuary" }

function Classes.BuffCatalog(classToken)
    return Classes.BUFF_CATALOG[classToken] or {}
end

-- Flat, ordered list of buff keys for a caster class (catalog order).
function Classes.CatalogBuffs(classToken)
    local out = {}
    for _, group in ipairs(Classes.BuffCatalog(classToken)) do
        for _, key in ipairs(group.buffs) do out[#out + 1] = key end
    end
    return out
end

function Classes.BuffGroup(key)
    local def = Classes.BUFFS[key]
    return def and def.group or nil
end

-- Position of a buff in the catalog order (all classes concatenated), used to keep sets in a stable order.
local orderIndex
function Classes.BuffOrder(key)
    if not orderIndex then
        orderIndex = {}
        local n = 0
        for _, class in ipairs({ "PALADIN", "PRIEST", "MAGE", "DRUID" }) do
            for _, k in ipairs(Classes.CatalogBuffs(class)) do
                n = n + 1
                orderIndex[k] = n
            end
        end
    end
    return orderIndex[key] or 999
end

Classes.DISPEL_COLORS = {
    Magic = { r = 0.20, g = 0.60, b = 1.00 },
    Curse = { r = 0.60, g = 0.00, b = 1.00 },
    Disease = { r = 0.60, g = 0.40, b = 0.00 },
    Poison = { r = 0.00, g = 0.60, b = 0.00 },
}

function Classes.GetData(classToken)
    return Classes.DATA[classToken]
end

function Classes.GetResSpell(classToken)
    local data = Classes.DATA[classToken]
    return data and data.res or nil
end

function Classes.GetResSpellOutOfCombat(classToken)
    local data = Classes.DATA[classToken]
    return data and data.resOutOfCombat or nil
end

function Classes.GetColor(classToken)
    local c = (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]) or Classes.COLORS[classToken]
    return c or { r = 1, g = 1, b = 1 }
end
