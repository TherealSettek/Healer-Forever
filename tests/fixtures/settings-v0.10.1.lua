-- SYNTHETIC saved settings in the shape Healer Forever 0.10.1 writes (schema 4, sparse: only non-default values).
-- Hand-written for the party golden / raid upgrade tests. Every name here is made up: this is NOT a copy of any
-- real SavedVariables file and must never become one.
HealerForeverCharDB = {
["version"] = 4,
["activePreset"] = 2,
["frames"] = {
["layout"] = "vertical",
["width"] = 150,
["height"] = 38,
["colorMode"] = "custom",
["customColor"] = {
["r"] = 0.1,
["g"] = 0.6,
["b"] = 0.9,
},
["healthText"] = "deficit",
["showPrediction"] = false,
["showRoleIcon"] = false,
["locked"] = true,
["lowHpPulse"] = true,
["spacing"] = 4,
["sortMode"] = "role",
["order"] = {
"party2",
"player",
"party1",
"party4",
"party3",
},
["point"] = {
["point"] = "BOTTOM",
["relativePoint"] = "BOTTOM",
["x"] = 12.5,
["y"] = 210,
},
["border"] = {
["style"] = "gold",
["width"] = 3,
["color"] = "custom",
["custom"] = {
["r"] = 0.9,
["g"] = 0.3,
["b"] = 0.2,
},
},
["range"] = {
["style"] = "dim",
["dim"] = 55,
["healable"] = false,
["outColor"] = {
["r"] = 0.4,
["g"] = 0.4,
["b"] = 0.45,
},
},
},
["auras"] = {
["onlyMine"] = true,
["onlyDispellable"] = true,
["maxBuffs"] = 6,
["maxDebuffs"] = 4,
["buffPosition"] = "left",
["debuffPosition"] = "inside",
["buffSize"] = 18,
["debuffSize"] = 24,
["perRow"] = 3,
["grow"] = "down",
["tooltipBuffs"] = true,
["tooltipIcons"] = false,
["zoneGap"] = 6,
["timerPos"] = "inside",
},
["buffs"] = {
["threshold"] = 45,
["showSolo"] = false,
["rebuffPercent"] = 10,
},
["resurrectOnClick"] = false,
["roleOverrides"] = {
["Brakkor-TestRealm"] = "TANK",
},
["smartButton"] = {
["show"] = true,
["point"] = {
["point"] = "CENTER",
["relativePoint"] = "CENTER",
["x"] = 40,
["y"] = -120,
},
},
["customSpells"] = {
{
["name"] = "Divine Shield",
["id"] = 642,
},
},
["ui"] = {
["extraButtons"] = true,
},
["minimap"] = {
["angle"] = 135,
["badges"] = false,
["lockPos"] = true,
},
["pins"] = {
["showPets"] = true,
["size"] = 20,
["showNames"] = false,
["pulse"] = false,
},
["bindings"] = {
["|1"] = {
["type"] = "spell",
["spell"] = "Flash of Light",
},
["|2"] = {
["type"] = "menu",
},
["|3"] = {
["type"] = "target",
},
["|6"] = {
["type"] = "spell",
["spell"] = "Blessing of Freedom",
},
["shift|1"] = {
["type"] = "spell",
["spell"] = "Cleanse",
},
["alt-ctrl|2"] = {
["type"] = "spell",
["spell"] = "Holy Shock",
},
["meta|1"] = {
["type"] = "spell",
["spell"] = "Holy Light",
},
["meta|2"] = {
["type"] = "target",
},
["meta-shift|1"] = {
["type"] = "spell",
["spell"] = "Lay on Hands",
},
["ctrl|4"] = {
["type"] = "macro",
["macrotext"] = "/say healing @mouseover",
},
},
["presets"] = {
{
["name"] = "Dungeon (made up)",
["self"] = {
"wisdom",
},
["map"] = {
["WARRIOR"] = {
["DEFAULT"] = {
"might",
},
["TANK"] = {
"kings",
"sanctuary",
},
},
["MAGE"] = {
["DEFAULT"] = {
"wisdom",
},
},
["PRIEST"] = {
["DEFAULT"] = {
"wisdom",
"kings",
},
},
},
["extras"] = {
},
},
{
["name"] = "Raid night (made up)",
["self"] = {
"kings",
},
["map"] = {
["WARRIOR"] = {
["DEFAULT"] = {
"might",
},
["TANK"] = {
"kings",
},
},
["PALADIN"] = {
["DEFAULT"] = {
"wisdom",
},
["TANK"] = {
"sanctuary",
},
["HEALER"] = {
"wisdom",
"light",
},
},
["PRIEST"] = {
["DEFAULT"] = {
"wisdom",
},
},
["MAGE"] = {
["DEFAULT"] = {
"kings",
},
},
["ROGUE"] = {
["DEFAULT"] = {
"might",
"salvation",
},
},
["DRUID"] = {
["DEFAULT"] = {
},
["HEALER"] = {
"wisdom",
},
},
},
["extras"] = {
{
["spell"] = "Blessing of Freedom",
["roles"] = {
["TANK"] = true,
},
["single"] = true,
},
},
},
},
["marks"] = {
},
["errorLog"] = {
},
}
