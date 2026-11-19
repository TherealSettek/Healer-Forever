# Architecture

## Load order (HealerForever.toc)
`Util/Util.lua` → `Util/RaidLayout.lua` → `Data/Classes.lua` → `Buffs/Presets.lua` → `ClickCast/Bindings.lua` → `Core.lua`
→ `Buffs/Roles.lua` → `Data/Spells.lua` → `Frames/Auras.xml` → `Frames/Auras.lua` → `Frames/UnitFrames.lua`
→ `Frames/RaidStyle.lua` → `Frames/RaidFrames.lua` → `Frames/RaidPreview.lua` → `ClickCast/ClickCast.lua` → `Buffs/BuffButtons.lua`
→ `Options/*` (Widgets, Window, Panes, RaidPane, MinimapPane, BuffPresetsPane, SpellsPane, BindingsPane, CopyWindow, Report,
Perf, ContactPane, Slash) → `Minimap/MinimapButton.lua` → `Minimap/MinimapPins.lua`. `Bindings.xml` is auto-loaded by the client
and isn't listed in the TOC. Adding or removing a TOC file needs a full game restart, not just `/reload`.

The first six files (Util, RaidLayout, Classes, Presets, Bindings, Core) are **pure** (no WoW calls at load), so the tests load them
directly. The namespace is `local ADDON_NAME, ns = ...`.

## Modules
| File | Responsibility |
|---|---|
| `Util/Util.lua` | Pure helpers: DeepCopy, MergeDefaults, DiffFromDefaults/DeepEqual (sparse save), FormatAuraTime, ModifierKey, border/zone geometry (NormalizeBorder, BorderSpec, BarBorderColor, ZoneSize, IconOffset, CellLayout, TIMER_HEIGHT, ICON_GAP), NormalizeRange |
| `Data/Classes.lua` | Class colours, the BUFFS table (might/wisdom/kings/…), roles, res spells per class, curated Forever spells (Light's Vigil, Oath of Light hint …) |
| `Data/Spells.lua` | Spellbook scan (C_SpellBook, talents via C_ClassTalents/C_Traits, overrides), custom spells, SPELLS_UPDATED |
| `Buffs/Presets.lua` | Buff presets (schema 4): `map[TARGETCLASS][ROLE]` is a SET of buff keys (at most one per catalog group), `self` is a set too, `extras` are role buffs like the tank oath. Pure logic: CellBuffs, SetCellBuff / ClearGroup (one-per-group), GetMissingBuffs (catalog order, recast threshold), PickNext. `LEGACY` holds the old presets (migration only). `ExampleFor(class)` / `ExamplePaladin()` |
| `Data/Classes.lua` (buff catalog) | `Classes.BUFFS` (key, name, group, groupSpell, fallback icon) and `Classes.BUFF_CATALOG[CASTERCLASS]` = ordered groups (`multi` groups are radio + None, single-buff groups are checkboxes). Only the player's own class catalog is shown and armed |
| `Buffs/Roles.lua` | Role per member: manual override → UnitGroupRolesAssigned → spec |
| `Buffs/BuffButtons.lua` | Secure missing-buff buttons per member, role-buff (extra) buttons, `HealerForeverSmartBuff`, `HealerForeverTankBuff`. Strict macros plus out-of-combat range gating. `MissingCount`. `/hf debug buffs` |
| `ClickCast/Bindings.lua` | Binding keys `"<mods>|<button>"` (mods ordered alt,ctrl,meta,shift). Builds strict macros (BuildMacroText, BuildResOnlyMacro, BuildTargetMacro), attributes, override keys. `EXAMPLE_PALADIN` |
| `ClickCast/ClickCast.lua` | Applies bindings to the unit buttons: plain secure attributes, the **Cmd swap state driver** (`[mod:meta]`), and hover override bindings via SecureHandlerWrapScript |
| `Core.lua` | DEFAULTS, error capture (LogError/Safe/Wrap/NewFrame/SecureHook), event dispatch, AfterCombat queue, sanitize, migrations, buildDB, BuildSaveTable (sparse save), AddonVersion, ns.Exists/ns.InGroup/ns.InCombat, SpellKnown |
| `Frames/UnitFrames.lua` | Party frames (SecureUnitButtonTemplate), layout (horizontal/vertical, pets), bar borders, health/power/prediction, range states (badge style), target glow, aggro, dead/ghost/offline, tooltip, `/hf debug click` |
| `Frames/Auras.lua` | Aura enumeration (secret-safe fallback chain), buff and debuff zones, icons with timers, per-icon tooltips, `/hf debug auras` |
| `Options/*` | Options window (Window, Widgets, Panes, BuffPresetsPane, SpellsPane, BindingsPane, MinimapPane), slash commands (Slash.lua) |
| `Minimap/MinimapButton.lua` | Gold-ring button with heal icon, status dot (missing buffs), lock badge, preset initial, tooltip, drag along the rim |
| `Minimap/MinimapPins.lua` | Class-orb party pins with role glyph, low-HP pulse, combat badge, edge pointers, corpse "X" at the death spot, faded when out of range |
| `Util/RaidLayout.lua` | Pure raid logic: `Normalize` (raid settings), `DesiredLayout` (party/raid + reason), `GroupOrder`, `GridCells`, `AssignCells` (40 buttons onto 40 cells, a bijection), `TextLayout` (number never cut, name cut first), `DebuffIconSize`, `BuffMarkers`, `NextBuffCheck` |
| `Frames/RaidStyle.lua` | Style D regions shared by real raid buttons and the preview: `RS.Build(frame)` (bar, prediction, name, centre text, buff marker slots with pulse, debuff zone, glow, outlines), `RS.Apply(frame, cfg)`, `RS.PlaceText`, `RS.NameWidthCap` |
| `Frames/RaidFrames.lua` | `ns.RaidFrames` (RF): anchor `HealerForeverRaidFrame`, 40 buttons `HealerForeverRaidUnit1..40`, switching (`Evaluate` / `Apply`), layout, unit updates, buff markers, debuff containers, `StatusLine`, `/hf debug raid` |
| `Frames/RaidPreview.lua` | `ns.RaidPreview`: 40 plain (non-secure) fake frames built with RaidStyle, fake privacy-safe names, never saved |
| `Options/RaidPane.lua` | "Raid Layout" options tab (switching + live status, preview, groups, corner legend, size, bar, my buffs, debuffs, range, reset) |
| `Options/Perf.lua` | `/hf perf`: CPU/memory per addon (C_AddOnProfiler, else scriptProfile CPU, else memory only), `start`/`stop` sampling and our own hot-path timers; lines for `/hf report` and `/hf copy` |

## Raid layout design (why it looks like this)
- **Fixed tokens, no group header.** The raid uses 40 of our own `SecureUnitButtonTemplate` buttons with fixed units `raid1..raid40`,
  shown by `RegisterUnitWatch` and positioned out of combat, the same model as the party frames. `SecureGroupHeaderTemplate` was rejected:
  a header re-assigns `unit` in combat, but click-casting bakes `@unit` into strict macros and state drivers (`hfmeta`, `[@unit,dead]`)
  out of combat, so a re-assigned button would cast on the wrong person. With fixed tokens a click is always on the right player; only a
  bar's position can be stale until combat ends.
- **Bijection layout.** `RaidLayout.AssignCells` maps all 40 buttons onto 40 cells: members fill their group's cells, unused buttons fill the
  remaining free cells, so someone joining mid-combat appears in a free cell and never covers another bar.
- **Party stays untouched.** Switching to raid calls `UF:SetSuspended(true, soft)`; switching back runs the normal party layout again.
  `tests/test_party_golden.lua` checks the party frames are identical to 0.10.1.
  - *Soft* (Auto mode inside a raid): the party buttons keep their unit watch and layout, and both anchors get secure visibility drivers:
    party `[group:raid] hide; show`, raid `[group:raid] show; hide`. If the raid ends in combat, the game hides the raid frame and shows the
    party frames at once; the real switch (layout, click-casting) still waits for combat end. Unregistered when the party layout is active again.
  - *Hard* ("Always raid", or Auto while not in a raid group): party unwatched and hidden, no drivers.
- **Switching** happens out of combat only (`AfterCombat` keys `rf-create`, `raid-switch`, `rf-layout`). `GROUP_ROSTER_UPDATE` and raid option
  changes are coalesced (`RF:RequestEvaluate`: one `Evaluate` 0.1 s after the burst, 0.3 s in combat). Out of combat a layout pass re-styles the
  bars only when a raid setting or the debuff display changed (`RF.StyleKey`); in combat it refreshes only bars whose GUID changed. Internal messages: `RAID_FRAMES_CREATED`,
  `RAID_LAYOUT_CHANGED` (ClickCast re-applies to `RF:ActiveButtons()` or clears the raid buttons).
- **Auras:** my-buff markers are worked out out of combat only (0.5 s tick on the raid anchor, max 8 members per tick). Dispellable debuffs are
  drawn by the game (`Auras.CreateDebuffContainer`, filter `HARMFUL|RAID_PLAYER_DISPELLABLE`, template `HealerForeverRaidAuraButtonTemplate`
  with the mouse off from creation). The bar glow has its own container per bar (`Auras.GlowContainerGeometry`: max 1 invisible carrier,
  `HealerForeverRaidGlowButtonTemplate`); each carrier gets a plain holder frame with the glow texture handed to the game with
  `AddDispelTypeTexture` (icons-only fallback: `RF.glowSupported = false`). We only alpha/show our own frames (`glowFrame`, `debuffZone`,
  the holder), never the game-managed regions. Containers are created on the first switch to raid, only for the parts the display uses; an
  unused part has unit "none". A buff result is dropped when the GUID behind a raid token changes.
- **Idle in party mode:** raid anchor hidden (its OnUpdate doesn't run), containers set to "none", raid state drivers unregistered.

## Performance instrumentation
Hot paths (party bars OnUpdate `uf`, raid bars `rf`, raid buff tick `rfbuffs`, buff-button ticker `bb`, minimap pins `mp`) are wrapped as
`local t0 = ns.perfOn and debugprofilestop() ... if t0 then ns.Perf.Add(key, t0) end`. `ns.perfOn` is nil unless `/hf perf start` is running,
so the idle cost is one table lookup per tick. Add new hot paths to `Perf.PATHS`.

## Patterns to reuse
- **Frames:** always `ns.NewFrame(...)`, never raw `CreateFrame`. It wraps scripts in error capture but skips secure or protected frames. On secure frames, wrap our own handlers with `ns.SecureHook` / `ns.SecureSetScript`. A source scan enforces this.
- **Events:** `ns:RegisterEvent(event, fn)`. Internal messages: `ns:On(msg, fn)` / `ns:Fire(msg, ...)`. Config changes: `ns:Changed(group)` fires `CONFIG_CHANGED`.
- **Combat-deferred work:** `ns:AfterCombat(key, fn)`. It runs now if out of combat; otherwise it's queued and deduplicated by key.
- **Existence and grouping:** `ns.Exists(unit)` and `ns.InGroup()` (a secret answer counts as true). Don't call `UnitExists` or `IsInGroup` directly; a test checks this.

## Tests (tests/)
`run.lua` runs every `test_*.lua`. `wow_mock.lua` is the WoW API mock, with secret-value simulation (`S.secretAll` makes values secret even out of combat), combat lockdown, protected-call detection, and range and aura modes. `framework.lua` provides describe/it/expect. `test_mutation.lua` mutates source lines and checks the suite catches each one. When you rewrite a line a mutant targets, retarget the mutant. `secret_scan.lua` is a heuristic scan for truth tests on secret-prone APIs. `aura_geo.lua` is the overlap checker. `tests/README.md` lists every file plus an in-game checklist.
