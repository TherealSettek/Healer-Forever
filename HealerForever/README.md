# Healer Forever

Created by trtg.

Party and raid healing frames for **WoW Forever** (modern Mainline/Midnight addon API): click-casting, buff presets,
heal prediction, one-click resurrection and class-coloured minimap pins. No external libraries.

## Install

Install it from CurseForge with the CurseForge app set to WoW Forever, or download the `HealerForever-v<version>.zip`
file and extract it so that the `HealerForever` folder ends up in `World of Warcraft/_forever_/Interface/AddOns/`.
Restart the game.

Updating: close the game (or `/reload`), replace the `HealerForever` folder with the new one. Your settings live in
`WTF/Account/<account>/<realm>/<character>/SavedVariables/HealerForever.lua` and are kept. `/hf version` prints the
addon version and the settings schema version. `/hf reset` resets the current character's settings to the defaults.

A fresh install is clean: one empty buff preset (no buff buttons until you add rules) and only plain Left = target and
plain Right = unit menu bindings. Optional examples: "Load example: Paladin" (Buff Presets) adds a preset and
"Load example bindings (Paladin)" (Click-Casting) fills empty slots only. Settings are saved sparsely: only the values
that differ from the defaults are written, on /reload or logout.

The TOC uses `## Interface: 16001, 120005`. 16001 is the community-reported Forever number; verify yours in game with
`/dump select(4, GetBuildInfo())` and adjust the TOC if needed.

## Features

- Party frames (player + party1-4 + pets): horizontal (pet below) or vertical (pet right); movable as a group,
  manual order with up/down plus sort by role / class / name.
- Raid layout (Options > Raid Layout) with its own settings; your party frames and settings are not changed. Switching:
  Auto (raids above 5 players and battlegrounds; a small raid split across groups too) / Always party / Always raid; the
  switch waits for the end of combat. 40 bars in 8 groups as Columns or Rows (8, 4 or 2 groups per line), group labels,
  hide empty groups, sort by role or class. Look "Hurt stands out": muted at full health, missing health big and red in
  the centre, small name top-left, DEAD / GHOST / OFFLINE / CAN'T RES / "?" states, out-of-range dimming. Your own buffs
  only, top-right (gold border = missing, orange pulsing border = ending; checked out of combat, not clickable).
  Debuffs you can dispel: a coloured glow around the bar plus up to 3 icons. Click-casting works on raid bars.
  "Preview full raid" (10/20/25/40 fake players, never saved) and a "What each corner means" legend.
- Original party-frame look with a border around the health and power bars only (Options > Frames & Bars): style
  None / Thin / Tooltip / Vanilla gold, thickness 1-4, colour class / black / gold / custom. Buffs sit above the bar and
  debuffs below (larger, dispel-coloured borders, timers); positions, sizes, icons per row and grow direction are in
  Buffs & Debuffs. Target glow, red aggro border, out-of-range dimming, dead/ghost/offline state, optional low-HP pulse.
- Optional threat bar on the party frames (Options > Frames & Bars > Threat bar, off by default): a thin strip above each
  member's health bar, yellow = more threat than the tank, orange = tanking but about to lose it, red = has aggro,
  optional green = safe, below the tank or no threat yet in a fight ("Green when below the tank", off by default). It covers every mob in the
  fight (no target needed). Height 2-6 px, "Only in combat" (default on). When the game hides the
  threat state in combat, the strip keeps the last known colour, like the red aggro border.
- Health bar (class / custom / gradient colour), health text (percent / current / deficit), power bar,
  incoming-heal prediction bar and overheal, range dimming, dead / ghost / offline states.
- Buffs (left) and debuffs (right) with timers (minutes above 60s, seconds below, red under 10s),
  debuff border by type, "only my buffs", "only debuffs I can dispel".
- Hover tooltip lists ALL of the unit's debuffs (name, type, stacks, time left, dispellable ones marked and first),
  regardless of the bar's icon limit or "only dispellable" filter; it refreshes live while hovering. Options in
  Buffs & Debuffs: "Show debuff list in hover tooltip" (default on) and "Also list buffs" (default off). In combat the
  game may hide aura data: unreadable entries show only what the game allows, else "Debuffs hidden by the game during combat".
- Hovering a buff or debuff icon shows Blizzard's real aura tooltip at the icon (works in combat; option in Buffs & Debuffs,
  default on). Icons inside the bar let clicks pass through to the frame so click-casting still works.
- Click-casting editor: toggle Shift / Ctrl / Alt(Option) / Cmd, then set each mouse button 1-8 (drag a spell from
  the spellbook or Class Spells tab, or use Pick); a summary lists the combos that already have bindings. Empty plain Left = target, plain Right = unit menu.
- Hover tooltip listing only the assigned bindings for the modifier combination currently held.
- Class Spells, the click-cast Pick menu and the spell list are built from your ACTUAL spellbook and talents at runtime
  (skill lines, overrides, purchased talent nodes; passives and off-spec spells skipped, deduped by name), grouped into
  Healing / Blessings-Buffs / Utility-Other, with a search box and "+ Add spell by name" (stored in `customSpells`) as a
  manual fallback. Curated names in `Data/Classes.lua` only categorise and act as fallback (Paladin includes Forever's
  Light's Vigil, Holy Strike, Hammer of the Righteous, Templar's Bulwark).
- Class-aware buff presets with stacking buffs: choose which of YOUR buffs each target class and role should get, from your
  class's catalog (Paladin blessings, Priest Fortitude / Spirit / Shadow Protection, Mage Intellect + Dampen/Amplify, Druid
  Mark of the Wild / Thorns). Buffs in different groups stack; within a group only one can be picked. The missing-buff
  button shows the next missing buff with a count when several are missing: Left-click casts it, Right-click casts the group
  version (Greater / Prayer / Brilliance / Gift). The smart key walks tank, healers, DPS, then you, one cast per press.
  Class buffs are shown again when less than 5% of their duration is left (adjustable, 0 = only when gone).
  "Load example" adds a ready-made preset for Paladin, Priest, Mage or Druid. Add a Self override, role buffs (e.g. a
  tank-only oath), and mark roles in the Group roles list.
- **Role buffs**: per preset, extra targeted buffs by role (Tank / Healer / DPS / Self), e.g. a tank-only Paladin oath.
  Add any spell from your spellbook in Buff Presets -> Role buffs (or drag it on); "One target at a time" suppresses
  the button while your aura is already on another group member. Each frame gets a second pulsing button for them.
- **Smart buff (one key)**: casting needs a hardware event, so nothing is cast automatically. The secure button
  `HealerForeverSmartBuff` is pointed out of combat at the next pending buff (role buffs first, then blessings for
  tank, healer, DPS, then yourself). Bind it in Esc > Options > Keybindings > AddOns > Healer Forever
  ("Cast next missing buff"), or use `/click HealerForeverSmartBuff`. `HealerForeverTankBuff` ("Cast tank buff on
  tank", macro `/click HealerForeverTankBuff`) casts the first tank role buff on the current tank. An optional
  movable "Buff next" button (Buffs & Debuffs option) shows the next buff and its target.
- **Resurrect on click**: a dead or ghost member shows a grey bar, DEAD/GHOST text and a res icon, and EVERY
  binding (all modifier + button combos, including hover bindings) casts only your class resurrection spell on
  that member. Paladin Redemption, Priest Resurrection, Shaman Ancestral Spirit, Druid Rebirth (Revive out of
  combat if known). Classes without a res, or without the spell learned, keep their normal bindings.
  Toggle: General -> "Click on dead member = Resurrect".
- Minimap button ("HF", padlock badge while frames are locked; unlocked frames show the drag handle and a gold outline): left-click options, right-click lock/unlock frames, shift-click cycle buff preset;
  draggable around the minimap.
- Minimap pins: glossy class-coloured orbs with a role glyph, in-combat sword badge, low-HP pulse, optional smaller pet
  orbs, an edge pointer clamped to the rim when a member is out of range, and a red-X corpse marker (in the member's
  class colour) where someone died, kept until they are revived, leave the group or you change map. Hover for name,
  class, role, health (when readable) and distance. Options > Minimap: size, role glyph, names on hover, pets, edge
  pointers, low-HP pulse, corpse marker.
- Blizzard's own party frames are not touched (hiding them taints the UI); turn off Raid-style party frames in Blizzard Settings > Edit Mode / Interface.

## Settings storage

Settings are per character (`HealerForeverCharDB`). A character without saved settings starts from the clean defaults
(since 0.12.1; earlier versions copied the account-wide `HealerForeverDB` in automatically). The account-wide table is
never modified. `/hf profile` shows the profile in use; `/hf copyaccount` (then `/hf copyaccount confirm`) copies the
account-wide settings into this character on request; buff presets and click-casting that belong to another class are
not copied. A character that an older version seeded with another class's presets gets them cleared once on load.
WoW only writes SavedVariables on /reload or a clean logout/exit, so changes are lost if the game crashes first.

## Slash commands

`/hf` or `/healerforever` opens options. `/hf lock`, `/hf unlock`, `/hf preset <n>` (no number lists presets),
`/hf reset`, `/hf profile`, `/hf copyaccount`, `/hf debug buffs` / `/hf debug auras` (prints why each unit's buff button is shown or hidden, including role buffs).
`/hf raid` shows which layout is active and why (`/hf raid auto|party|raid` sets the switching); `/hf raid preview
[10|20|25|40|off]` shows a fake full raid; `/hf debug raid` and `/hf debug click raidN` explain the raid state.
`/hf perf` shows CPU and memory per addon (top 8 plus Healer Forever); `/hf perf start [seconds]` / `/hf perf stop`
time our own code over a window. CPU per addon needs the game's addon profiler, or the scriptProfile CVar; without
either, only memory is shown and the output says so.
`/hf mark [note]` saves a snapshot of the current moment (time, combat state, zone, group size, aura and buff debug
output; the last 5 are kept, `/hf mark clear` removes them). `/hf report` opens a copy window with a ready-to-email
report (versions, client, settings summary, performance, other addons, recent errors, debug runs and marks). `/hf contact` prints the
support email and opens the Help & Contact tab. The Help & Contact tab also lists every command, the keybindings, a
3-step quick start and a few good-to-know notes (the in-game list is generated from the same table as `/hf help`).

## Help & Contact

The Help & Contact options tab (also reachable through "Contact" in the options footer) shows the support email
(healer.forever.trtg@gmail.com) in a select-and-copy box and a "Report a problem" button. Please include what you did,
when it happened (in combat, on login, on reload) and a screenshot if it is visual.

## License

All rights reserved. See LICENSE.txt. Contact: healer.forever.trtg@gmail.com

## How resurrection and Cmd work (technical)

Secure clicks only know `alt-ctrl-shift-` prefixes (verified in Blizzard's live `SecureTemplates.lua`; no `meta-`).
- Buttons 1-5 without Cmd are plain secure attributes.
- Buttons 6+ and every Cmd combination are applied as hover override bindings from a secure snippet
  (`SecureHandlerEnterLeaveTemplate`, Clique style) which click the unit button as `HFB<n>`.
- Spell bindings are secure macros so the alive -> dead switch needs no addon-side `SetAttribute` in combat:
  `/cast [@party1,dead] Redemption; [@party1] Flash of Light`.
- Target / menu bindings use a secure state driver (`[@unit,dead] dead; alive`) whose restricted snippet swaps the
  button's own attributes to `/cast [@unit,dead] Redemption` and back.

## Notes on Cmd and menu bindings

Cmd has no secure modifier prefix, so Cmd bindings use hover override bindings and are experimental; if the
override does not win, the plain binding of that button runs. "Unit menu" only works on plain Right-click and
"target" is emitted as a macro, because Mainline gates both on C_ClickBindings.

## Limitations (Forever / Midnight restrictions)

- In combat, health, power, heals and auras are "secret values": the addon only pipes them into Blizzard widgets
  (status bars, cooldown frames, font strings). Overheal text and addon-side timers appear only when values are readable.
- Missing-buff buttons are evaluated out of combat and hidden in combat; protected frames are never changed in combat
  (changes are queued until combat ends).
- Aura icons have no tooltips so they never intercept click-casting.
- Minimap pins use `C_Map` positions, which are unavailable in instances (and may be restricted); pins then hide,
  the native blips stay, and a one-time "Minimap pins unavailable here" hint is printed. Zoom radii are approximate.
- Cmd (meta) binding key syntax on the Mac client is unverified; if Cmd combos do nothing, test with `/dump IsMetaKeyDown()`.

## Development

`.luacheckrc` is at the repository root. Pure modules (`Util`, `Data/Classes`, `Buffs/Presets`, `ClickCast/Bindings`,
`Minimap/MinimapPins.ToMinimapOffset`) use no WoW API and load in plain Lua 5.1.

## For developers: releasing

`./run-tests.sh` runs luacheck and the Lua tests. `scripts/release-tests.sh <version>` (e.g. `0.9.0`) runs the full test suite and then
`scripts/release.sh <version>`, which validates the version, copies `HealerForever/` to `dist/`, stamps the version into the copied TOC (the source TOC has
`## Version: @project-version@`, shown as "dev" in game) and builds `dist/HealerForever-v<version>.zip` with the
`HealerForever` folder at the zip root, then prints the sha256. Upload that zip to CurseForge by hand, with game
version "Forever 1.60.1". `.github/workflows/test.yml` runs the tests on pushes to `main` and on pull requests, without
the slow mutation tests (`HF_SKIP_MUTATION=1`). Run the full `./run-tests.sh` locally before every release.
