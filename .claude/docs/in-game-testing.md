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
| `/hf raid` | Which layout is active (party/raid) and why. `/hf raid auto\|party\|raid` sets the switching |
| `/hf raid preview [10\|20\|25\|40\|off]` | Fake full raid at the raid position (not clickable, off in combat or in a real raid) |
| `/hf debug raid` | Raid state: active layout and reason, buttons, tokens, cells, aliases, glow support, buff tick |
| `/hf debug click raidN` | Click-casting state of one raid bar (e.g. `raid5`) |
| `/hf perf` | CPU and memory per addon: top 8 plus Healer Forever |
| `/hf perf start [seconds]` / `/hf perf stop` | Time our own code over a window (default 60 s; 5-600) and print the result |
| `/hf report`, `/hf copy` | Both include the `/hf perf` block |

## Reading the real error log yourself (read only)
```
cat "/Applications/World of Warcraft/_forever_/WTF/Account/415205454#1/93/Isbuli-Fat/SavedVariables/HealerForever.lua"
```
Look at `errorLog` entries (`label`, `msg`, `stack`, `combat`, `kind = "blocked"` for taint). Copy the file to `.settings-backup/` first, and never edit it.

## Known-good in game (confirmed by the owner)
- Interface number **16001** (`/dump select(4, GetBuildInfo())` returned 16001 on 2026-11-15). This matches the TOC's `## Interface: 16001`
  and CurseForge's "Forever 1.60.1" game version.
- Cmd+Middle and Cmd+Right click-casting work, through the Cmd swap driver.

## Raid layout checklist (new, needs a game restart: new files in the TOC)
1. Solo and in a 5-man party: the party bars look and behave exactly like before. `/hf raid` says "party".
2. Join a raid with more than 5 players out of combat: the raid bars appear at once and the party bars hide. `/hf raid` says "raid" and why.
3. Get invited / converted to raid **in combat**: one chat line "switching after combat"; the switch happens when combat ends, no error and no
   "addon blocked" popup.
4. Click-casting on raid bars: every binding casts on the bar's player, including Cmd+click on Mac and resurrect on a dead player. Check one bar
   with `/hf debug click raidN`. Out of range or not visible: nothing is cast (no cast on yourself).
5. A dispellable debuff: the bar edge glows in the dispel colour and the icon shows bottom-right, also in combat. If there's no glow,
   `/hf debug raid` shows whether the glow fell back to icons (glowSupported = false). Report which. Also check: the glow sits under the
   name/number and doesn't touch the neighbouring bars; hovering a debuff icon in combat shows the bar tooltip (icons take no mouse);
   "Bar glow" display shows no icons; two dispellable debuffs where the first is dispelled: the glow stays (second debuff).
6. My buff markers out of combat: a gold-bordered icon for a missing buff; orange and pulsing when it's about to run out. They hide (or dim) in
   combat and come back after.
7. Preview: Raid Layout tab > "Preview full raid" (or `/hf raid preview 40`). The preview can't be clicked, moves with the drag handle when
   unlocked, and turns off on entering combat. After `/reload` it is off.
8. Leave the raid: the party bars come back unchanged (positions, size, bindings). **Also in combat** (Auto mode): when the raid ends or you
   are removed mid-fight, the party bars should appear at once and be clickable; the raid bars disappear. No chat line, no "addon blocked".
   The party bars may sit in their old order until combat ends. With "Always raid" there are no party bars until combat ends (by design).
   `/hf debug raid` shows "visibility drivers: raid=true party=true" while the raid layout is active in Auto mode.
9. Battleground: the raid layout is used.
10. `/hf perf` with the raid active, and `/hf perf start 60` during a raid fight then `/hf perf stop`: paste the output (or use `/hf report`).

11. Deficit text: a member at full health shows no number (also right after a heal tops them up); a hurt member shows "-1.2k" in red.

## Performance and the Questie report
- `/hf perf` lists addons by CPU when the game has the addon profiler (`C_AddOnProfiler`, average ms per frame since `/reload`). Without it,
  CPU per addon needs `/console scriptProfile 1` + `/reload` (slows the game; turn it off after); otherwise the output says CPU isn't available
  and lists memory only. Unverified on Forever: whether `C_AddOnProfiler` and `Enum.AddOnProfilerMetric` exist there.
- Minimap pins (code check, 2026-11-18): `Minimap/MinimapPins.lua` only reads the minimap (`GetZoom`, `GetWidth`, `GetFrameLevel`) and never
  changes its zoom, mask, blips or children. Pins are our own buttons parented to `Minimap` at strata MEDIUM, frame level Minimap + 6, and only
  shown while grouped. They could draw on top of other addons' minimap pins (Questie uses HereBeDragons pins) but can't remove them.
  If a user reports Questie circles vanishing, ask them to turn pins off (Options > Minimap) and check whether the circles come back, and to send
  `/hf perf` output. Not reproduced yet.

## Still open
- Self-heal click sometimes failing at the start of a fight. The probable cause (buff buttons overlapping the player bar) is fixed but not confirmed.
  If it recurs, ask for `/hf debug click` output.
