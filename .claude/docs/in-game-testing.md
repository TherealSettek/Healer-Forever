# In-game testing and diagnostics

## Setup on the owner's Mac
- WoW Forever is installed at `/Applications/World of Warcraft/_forever_/`.
- `Interface/AddOns/HealerForever` is a symlink to this repo's `HealerForever/`.
- Other addons are installed too, which can interact with this one: HealBot, Bartender4, Details, DBM, ClassicUIForever, Questie, Bagnon, Auctionator.

## Owner's test loop
1. Restart WoW when files are added or the TOC changes; otherwise `/reload`.
2. `/console scriptErrors 1` so Lua errors pop up. The owner pastes them into chat.
3. `/reload` or log out afterwards so the error log gets saved.

## Slash commands
| Command | Use |
|---|---|
| `/hf` | Open options |
| `/hf version` | Addon version and settings schema |
| `/hf errors` / `/hf errors clear` | Last captured Lua errors and "addon blocked" events |
| `/hf debug auras` | What the aura API returned per unit (method, count, secret fields, errors) |
| `/hf debug buffs` | Why buff buttons are or aren't armed (spell known, range, tank state) |
| `/hf debug click` | The player's button attributes, the Cmd swap state, override bindings, and frames covering the button |
| `/hf debug click watch` | Toggle printing that output on every modifier change (Cmd diagnosis) |
| `/hf profile`, `/hf copyaccount [confirm]`, `/hf reset` | Profile management |
| `/hf lock`, `/hf unlock`, `/hf preset <n>` | Quick toggles |

## Reading the real error log yourself (read only)
```
cat "/Applications/World of Warcraft/_forever_/WTF/Account/415205454#1/93/Isbuli-Fat/SavedVariables/HealerForever.lua"
```
Look at `errorLog` entries (`label`, `msg`, `stack`, `combat`, `kind = "blocked"` for taint). Copy the file to `.settings-backup/` first, and never edit it.

## Known-good in game (confirmed by the owner)
- Interface number **16001** (`/dump select(4, GetBuildInfo())` returned 16001 on 2026-11-15). This matches the TOC's `## Interface: 16001`
  and CurseForge's "Forever 1.60.1" game version.
- Cmd+Middle and Cmd+Right click-casting work, through the Cmd swap driver.

## Still open
- Self-heal click sometimes failing at the start of a fight. The probable cause (buff buttons overlapping the player bar) is fixed but not confirmed.
  If it recurs, ask for `/hf debug click` output.
