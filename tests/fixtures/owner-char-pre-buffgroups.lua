
HealerForeverCharDB = {
["version"] = 3,
["errorLog"] = {
{
["combat"] = false,
["count"] = 1,
["label"] = "OnHide",
["msg"] = "...d_RestrictedAddOnEnvironment/RestrictedExecution.lua:470: Cannot call restricted closure from insecure code",
["stack"] = "[Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/RestrictedExecution.lua]:470: in function <...d_RestrictedAddOnEnvironment/RestrictedExecution.lua:444>\n[tail call]: ?\n[Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/SecureHandlers.lua]:335: in function <...izzard_RestrictedAddOnEnvironment/SecureHandlers.lua:332>\n[tail call]: ?\n[tail call]: ?\n[C]: in function 'xpcall'\n[Interface/AddOns/HealerForever/Core.lua]:144: in function <Interface/AddOns/HealerForever/Core.lua:142>\n[C]: in function 'Hide'\n...",
["kind"] = "error",
["time"] = 1794679370,
},
{
["time"] = 1794689077,
["combat"] = false,
["label"] = "PLAYER_LOGIN",
["msg"] = "Interface/AddOns/HealerForever/Frames/UnitFrames.lua:492: attempt to perform boolean test on local 'secretInRange' (a secret boolean value, while execution tainted by 'HealerForever')",
["stack"] = "[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:554: in function 'UpdateAll'\n[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:563: in function 'UpdateEverything'\n[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:1032: in function 'Layout'\n[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:1124: in function 'CreateNow'\n[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:1113: in function 'fn'\n[Interface/AddOns/HealerForever/Core.lua]:310: in function 'AfterCombat'\n[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:1111: in function 'Create'\n[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:1137: in function <Interface/AddOns/HealerForever/Frames/UnitFrames.lua:1136>\n...",
["kind"] = "error",
["count"] = 1,
},
{
["time"] = 1794689078,
["combat"] = false,
["label"] = "PLAYER_ENTERING_WORLD",
["msg"] = "Interface/AddOns/HealerForever/Frames/UnitFrames.lua:492: attempt to perform boolean test on local 'secretInRange' (a secret boolean value, while execution tainted by 'HealerForever')",
["stack"] = "[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:554: in function 'UpdateAll'\n[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:563: in function 'UpdateEverything'\n[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:1140: in function <Interface/AddOns/HealerForever/Frames/UnitFrames.lua:1139>\n[tail call]: ?\n[C]: in function 'xpcall'\n[Interface/AddOns/HealerForever/Core.lua]:136: in function 'Safe'\n[Interface/AddOns/HealerForever/Core.lua]:215: in function <Interface/AddOns/HealerForever/Core.lua:211>\n",
["kind"] = "error",
["count"] = 1,
},
{
["time"] = 1794689151,
["combat"] = false,
["label"] = "OnUpdate",
["msg"] = "Interface/AddOns/HealerForever/Frames/UnitFrames.lua:492: attempt to perform boolean test on local 'secretInRange' (a secret boolean value, while execution tainted by 'HealerForever')",
["stack"] = "[Interface/AddOns/HealerForever/Frames/UnitFrames.lua]:752: in function <Interface/AddOns/HealerForever/Frames/UnitFrames.lua:740>\n[tail call]: ?\n[C]: in function 'xpcall'\n[Interface/AddOns/HealerForever/Core.lua]:143: in function <Interface/AddOns/HealerForever/Core.lua:141>\n",
["kind"] = "error",
["count"] = 279,
},
},
["migratedFrom"] = "account",
["bindings"] = {
["|2"] = {
["type"] = "spell",
["spell"] = "Flash of Light",
},
["|3"] = {
["type"] = "spell",
["spell"] = "Holy Shock",
},
["|1"] = {
["type"] = "spell",
["spell"] = "Holy Light",
},
["meta|2"] = {
["type"] = "spell",
["spell"] = "Blessing of Protection",
},
["ctrl|2"] = {
["type"] = "spell",
["spell"] = "Purify",
},
["alt|3"] = {
["type"] = "spell",
["spell"] = "Oath of Light",
},
["meta|3"] = {
["type"] = "spell",
["spell"] = "Lay on Hands",
},
},
["auras"] = {
["maxDebuffs"] = 5,
["maxBuffs"] = 6,
},
["presets"] = {
{
["self"] = "kings",
["extras"] = {
{
["roles"] = {
["TANK"] = true,
},
["spell"] = "Oath of Light",
["single"] = false,
},
},
["name"] = "5-man Dungeon",
["map"] = {
["HUNTER"] = {
["DAMAGER"] = "kings",
["DEFAULT"] = "kings",
},
["WARRIOR"] = {
["DAMAGER"] = "kings",
["DEFAULT"] = "kings",
["TANK"] = "kings",
},
["SHAMAN"] = {
["DAMAGER"] = "kings",
["DEFAULT"] = "kings",
["HEALER"] = "kings",
},
["MAGE"] = {
["DAMAGER"] = "kings",
["DEFAULT"] = "kings",
},
["PRIEST"] = {
["DEFAULT"] = "kings",
},
["WARLOCK"] = {
["DAMAGER"] = "kings",
["DEFAULT"] = "kings",
},
["DRUID"] = {
["DAMAGER"] = "kings",
["DEFAULT"] = "kings",
["HEALER"] = "kings",
["TANK"] = "kings",
},
["PALADIN"] = {
["DAMAGER"] = "kings",
["DEFAULT"] = "kings",
["HEALER"] = "kings",
["TANK"] = "kings",
},
["ROGUE"] = {
["DAMAGER"] = "kings",
["DEFAULT"] = "kings",
},
},
},
{
["map"] = {
["HUNTER"] = {
["DEFAULT"] = "kings",
},
["WARRIOR"] = {
["DEFAULT"] = "kings",
},
["PALADIN"] = {
["DEFAULT"] = "kings",
},
["MAGE"] = {
["DEFAULT"] = "kings",
},
["PRIEST"] = {
["DEFAULT"] = "kings",
},
["WARLOCK"] = {
["DEFAULT"] = "kings",
},
["DRUID"] = {
["DEFAULT"] = "kings",
},
["ROGUE"] = {
["DEFAULT"] = "kings",
},
["SHAMAN"] = {
["DEFAULT"] = "kings",
},
},
["name"] = "Raid - Group 1",
["extras"] = {
},
},
{
["map"] = {
["HUNTER"] = {
["DEFAULT"] = "light",
},
["WARRIOR"] = {
["DEFAULT"] = "light",
},
["PALADIN"] = {
["DEFAULT"] = "light",
},
["MAGE"] = {
["DEFAULT"] = "light",
},
["PRIEST"] = {
["DEFAULT"] = "light",
},
["WARLOCK"] = {
["DEFAULT"] = "light",
},
["DRUID"] = {
["DEFAULT"] = "light",
},
["ROGUE"] = {
["DEFAULT"] = "light",
},
["SHAMAN"] = {
["DEFAULT"] = "light",
},
},
["name"] = "Raid - Group 2",
["extras"] = {
},
},
{
["map"] = {
["HUNTER"] = {
["DEFAULT"] = "salvation",
},
["WARRIOR"] = {
["DEFAULT"] = "might",
},
["PALADIN"] = {
["DEFAULT"] = "salvation",
},
["MAGE"] = {
["DEFAULT"] = "salvation",
},
["PRIEST"] = {
["DEFAULT"] = "salvation",
},
["WARLOCK"] = {
["DEFAULT"] = "salvation",
},
["DRUID"] = {
["DEFAULT"] = "salvation",
},
["ROGUE"] = {
["DEFAULT"] = "salvation",
},
["SHAMAN"] = {
["DEFAULT"] = "salvation",
},
},
["name"] = "Salv Duty",
["extras"] = {
},
},
},
["frames"] = {
["locked"] = true,
["healthText"] = "current",
["point"] = {
["y"] = 181.0001525878906,
["x"] = -68.00017547607422,
["point"] = "BOTTOM",
["relativePoint"] = "BOTTOM",
},
["width"] = 126,
},
["minimap"] = {
["angle"] = 222.1996844123392,
},
}
