std = "lua51"
max_line_length = false
exclude_files = { "mockup/", "tests/" }
ignore = { "212/self", "212/_.*", "213", "211/ADDON_NAME" }

globals = {
    "HealerForeverDB", "HealerForeverCharDB",
    "SlashCmdList", "SLASH_HEALERFOREVER1", "SLASH_HEALERFOREVER2",
    "UISpecialFrames", "_G", "BINDING_HEADER_HEALERFOREVER", 
}

read_globals = {
    "GetRealZoneText", "GetBuildInfo", "GetLocale", "GetNumGroupMembers", "IsInRaid", "GetNumAddOns", "GetAddOnInfo", "IsAddOnLoaded", "UnitLevel", "GetSpecializationInfo", "ChatFontNormal",
    "C_StringUtil", "C_CurveUtil",
    "UnitGUID",
    "AnchorUtil", "AuraContainerSortMethod", "AuraContainerSortDirection", "CreateFrame", "GameFontHighlight", "ChatFontNormal", "SecureCmdOptionParse", "IsMetaKeyDown", "GetBindingAction", "GetMouseFoci", "GetMouseFocus", "UnitPosition", "IsInInstance", "UnitAffectingCombat", "GetAddOnMetadata", "UnitIsVisible", "ColorPickerFrame", "AbbreviateNumbers", "UnitThreatSituation", "debugstack", "time", "date", "hooksecurefunc", "issecrettable", "canaccesstable", "IsSpellKnownOrOverridesKnown", "IsPassiveSpell", "GetNumSpellTabs", "GetSpellTabInfo", "GetSpellBookItemName", "C_ClassTalents", "C_Traits", "MenuUtil", "unpack", "C_Texture", "GetSpecialization", "GetSpecializationRole", "UnitFullName", "GetRealmName", "GetNormalizedRealmName", "UnitGroupRolesAssigned", "geterrorhandler", "SecureHandlerWrapScript", "ClearOverrideBindings", "CreateColor", "UIParent", "Minimap", "GameTooltip", "DEFAULT_CHAT_FRAME",
    "SettingsPanel", "Settings", "HideUIPanel", "ToggleFrame", "SpellBookFrame",
    "PlayerSpellsUtil", "ToggleSpellBook", "PartyFrame", "CompactPartyFrame",
    "RegisterUnitWatch", "UnregisterUnitWatch", "RegisterStateDriver", "UnregisterStateDriver",
    "InCombatLockdown", "GetTime", "GetCVar", "GetCursorPosition", "GetCursorInfo", "ClearCursor",
    "IsShiftKeyDown", "IsControlKeyDown", "IsAltKeyDown", "IsMetaKeyDown", "IsMacClient",
    "IsInGroup", "IsIndoors", "GetPlayerFacing", "issecretvalue",
    "PickupSpell", "IsPlayerSpell", "IsSpellKnown", "PowerBarColor", "RAID_CLASS_COLORS",
    "CurveConstants", "Enum", "CreateUnitHealPredictionCalculator", "UnitGetDetailedHealPrediction",
    "UnitGetIncomingHeals", "UnitHealthPercent", "UnitHealthMissing",
    "UnitExists", "UnitName", "UnitClass", "UnitHealth", "UnitHealthMax", "UnitPower", "UnitPowerMax",
    "UnitPowerType", "UnitIsDeadOrGhost", "UnitIsGhost", "UnitIsConnected", "UnitInRange", "UnitIsUnit",
    "UnitGroupRolesAssigned",
    "C_Spell", "C_SpellBook", "C_UnitAuras", "C_Map", "C_Timer", "C_CurveUtil", "C_AddOns",
}
