# Changelog

## 0.12.0

- New optional threat bar on the party frames (Options > Frames & Bars, off by default): a thin strip above each
  player's health bar. Yellow = more threat than the tank, orange = the tank is about to lose aggro, red = has aggro.
  It covers every mob in the fight, needs no target, and can be set to show only in combat. Height 2-6 px.
  Hover "Show threat bar" for a short explanation of the colours; the Help tab mentions it too.
  Optional "Green when below the tank" (off by default): green = safe: less threat than the tank, or no threat yet while you are fighting.

## 0.11.0

- New Raid layout with its own settings in a new "Raid Layout" options tab. Your party frames and every setting you
  saved before stay exactly as they were.
  - Switching: Auto (default), Always party or Always raid. In Auto the raid layout is used in raids above 5 players
    (a small raid split across groups uses it too) and in battlegrounds. If you join in combat, the switch waits until
    combat ends.
    If the raid ends (or you are removed) in combat, the party bars come back at once (Auto mode); the rest of the
    switch finishes after combat.
  - 40 bars in 8 groups, arranged as Columns or Rows with 8, 4 or 2 groups per line. Group labels G1-G8, empty groups
    hidden, sort by role or class inside a group.
  - Look "Hurt stands out": bars are muted at full health and full colour when hurt, missing health is shown big and
    red in the centre (never cut), the name is small in the top-left corner. DEAD, GHOST, OFFLINE, CAN'T RES and "?"
    (not visible) show in the centre; out of range dims the bar with a dashed outline.
  - Your buffs only: a small spell icon top-right. Gold border = missing; orange border that pulses = ending (under the
    rebuff %, default 5). Checked out of combat only and hidden in combat (or kept dimmed). Not clickable.
  - Debuffs: only the ones your class can dispel, as a coloured glow around the bar plus up to 3 icons.
  - Click-casting (including Cmd on Mac and resurrect on click) works on raid bars the same as on party bars.
  - "Preview full raid" button (10/20/25/40 fake players) to try the options; not clickable, turns itself off in
    combat or when you join a real raid, never saved.
  - "What each corner means" legend in the options tab.
  - Commands: `/hf raid` (which layout is active and why; `/hf raid auto|party|raid` sets it), `/hf raid preview
    [10|20|25|40|off]`, `/hf debug raid`, `/hf debug click raidN`.
- `/hf perf`: shows how much CPU and memory Healer Forever uses next to your other addons (top 8 plus ours).
  `/hf perf start [seconds]` (default 60) times our own code while you play and `/hf perf stop` ends it early. The
  numbers are also in `/hf report` and `/hf copy`. If the game can't measure CPU per addon, it says so instead of
  showing zeros.
- Buff Presets: Tank / Healer / DPS rows now follow the class row unless you pick buffs for them. In the role-row
  popup, "None" is replaced by "Use class row" (selected by default), which resets the row. Role rows you emptied
  before now follow the class row too, so setting a buff on the class row is enough. The class row and the Self row
  still use "None" for no buff.
- Fixed: a Lua error "bad argument #4 to 'SetTextColor'" when changing settings with a health bar colour other than
  "Class colours" (player names are drawn in class colour in that mode).
- Fixed: "addon blocked" (SetPropagateMouseMotion) logged many times in combat when new buff or debuff icons appeared.
  Their mouse setup now waits until combat ends; new icons are click-through from the start, so click-casting on the
  bar keeps working.

## 0.10.1

- New "Help & Contact" options tab with the support email (read-only box plus Copy button), a "Report a problem"
  button and a short how-to-report checklist. The options footer has a clickable "Contact" link.
- `/hf report` (or Report a problem) opens a copy window with a ready-to-email report: addon and settings version, game
  build, locale, OS, class, group, aura path, a settings summary, other loaded addons, the last 20 errors, debug runs
  and marks. No other players' names are included.
- `/hf mark [note]` saves a snapshot of the current moment (last 5 kept, `/hf mark clear` removes them) for the report.
- The Help & Contact tab (now scrollable) has a "Commands & Tips" section: every command, keybindings, a quick start and
  good-to-know notes, generated from the same list as `/hf help`.
- `/hf contact` prints the email and opens the Help & Contact tab.
- License: All Rights Reserved (LICENSE.txt ships with the addon; `## X-License` in the TOC).

## 0.10.0 (beta)

- Class-aware buff presets with stacking buffs. Pick buffs for each target class and role from YOUR class's catalog:
  Paladin blessings (one at a time), Priest Fortitude / Divine Spirit / Shadow Protection, Mage Arcane Intellect plus
  Dampen or Amplify Magic, Druid Mark of the Wild / Thorns. Buffs in different groups stack; within a group only one
  can be chosen. Classes without a catalog show a hint and can still use Role buffs.
- The Buff Presets grid shows small buff icons per cell, with a popup of checkboxes and radio buttons, plus
  "Load example" for Paladin, Priest, Mage and Druid (adds a preset, never overwrites).
- Each member's missing-buff button shows the NEXT missing buff with a count badge when several are missing;
  Left-click casts it and Right-click casts the group version (Greater / Prayer / Brilliance / Gift) when you know it.
  After each cast the next one arms. The smart key walks tank, healers, DPS, then you, one cast per press.
- Settings schema v4: preset cells become sets of buffs. Existing presets behave exactly as before.
- Early rebuff: a class buff also counts as missing when less than 5% of its duration is left (option 0-50%, 0 = only
  when gone); role buffs keep their seconds threshold. `/hf debug buffs` shows, for every assigned buff, the matching
  aura, time left, % left and the rule that applied.
- Buff and debuff icons on the bars are now drawn by the game itself (Blizzard's AuraContainer), so they update live in
  combat: dispelled or expired auras disappear at once. WoW Forever does not let addons read party auras in combat,
  which caused stuck icons and "Auras cannot be accessed when secret while tainted" errors; the addon no longer reads
  auras in combat at all. Clients without the container fall back to drawn icons that refresh after combat.
- Hovering an aura icon shows the game's own tooltip without the bar tooltip overwriting it; icons keep a stable order.
- Icons per row default to Auto (as many as fit the bar); a fixed 2-10 is still available.
- Max buffs can now go up to 20 and max debuffs up to 12 (were 8 and 6), so more rows of icons are possible.
- Compact aura timers ("6m", "45s") in a smaller outlined font that fits under each icon; "Timer position" applies.
- The creator credit (trtg) is shown in the options footer, the About block, `/hf version` and the TOC.

## 0.9.2 (beta)

- Dispelled or expired debuffs no longer stay stuck on the bars in combat: removals reported by the game hide the
  icon at once, auras that no longer exist are dropped even when the game's list is out of date, a failed aura read
  keeps the old icons for at most 1 second, and a half-second re-check refreshes any bar that shows a debuff.
- Debug output is saved: `/hf debug buffs|auras|click` keeps its last 10 runs in the settings file, and `/hf debug clear` empties them.
- `/hf copy` (or `/hf debug <x> copy`, `/hf errors copy`) opens a window with the last debug output and the error
  log, pre-selected for Cmd/Ctrl+C.
- `/hf debug auras` lists every visible debuff icon and whether its aura still exists.

## 0.9.1 (beta)

- Windows/Linux: the Meta modifier is now shown as "Win key (not recommended)" and greyed out in Click-Casting,
  with a tooltip explaining that the Windows key usually opens the Start menu. Existing bindings are kept and
  marked "(Win key)" in the summary and the bar tooltip.
- Mac: the modifier toggles read plain "Option" and "Cmd" (the symbol glyphs could show as empty boxes in WoW's font).
  The "Cmd+Left may act as a right click" note only shows on Mac.

## 0.9.0 (beta)

First public beta of Healer Forever for WoW Forever (Midnight 12.x API).

- Party frames for you, party1-4 and pets, horizontal (pet below) or vertical (pet right), movable as a group,
  manual / role / class / name ordering.
- Original frame look with borders around the health and power bars (none / thin / tooltip / vanilla gold,
  thickness, class / black / gold / custom colour), health text, power bar, heal prediction and overheal, range,
  target glow, aggro border, dead / ghost / offline states, optional low-HP pulse, role icons.
- Buffs and debuffs with timers, dispel-coloured borders, configurable positions, sizes, icons per row and grow
  direction; per-icon Blizzard aura tooltips and a full debuff / buff list in the unit tooltip, secret-value safe.
- Click-casting: Shift / Ctrl / Alt(Option) / Cmd x mouse buttons 1-8, strict macros that never fall back to
  casting on yourself, drag spells from the spellbook, tooltip showing only the held modifier's bindings.
- Resurrect on click for dead members (Paladin, Priest, Shaman, Druid).
- Buff presets by class and role with a Self override, role buffs (e.g. a tank-only oath), missing-buff buttons,
  a one-key smart buff button and a tank buff button with key bindings.
- Class spell list built from your actual spellbook and talents, with search and manual spell entry.
- Minimap button, class-coloured minimap pins, per-character settings saved sparsely, error log (`/hf errors`),
  `/hf debug buffs|auras`, `/hf version`.
- Clean install defaults: no preset rules and only target / unit menu click bindings; opt-in "Load example:
  Paladin" buttons.
