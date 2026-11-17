# Architecture

## Load order (HealerForever.toc)
`Util/Util.lua` → `Data/Classes.lua` → `Buffs/Presets.lua` → `ClickCast/Bindings.lua` → `Core.lua` → `Buffs/Roles.lua`
→ `Data/Spells.lua` → `Frames/Auras.lua` → `Frames/UnitFrames.lua` → `ClickCast/ClickCast.lua` → `Buffs/BuffButtons.lua`
→ `Options/*` → `Minimap/MinimapButton.lua` → `Minimap/MinimapPins.lua`. `Bindings.xml` is auto-loaded by the client and isn't listed in the TOC.

The first five files are **pure** (no WoW calls at load), so the tests load them directly. The namespace is `local ADDON_NAME, ns = ...`.

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

## Patterns to reuse
- **Frames:** always `ns.NewFrame(...)`, never raw `CreateFrame`. It wraps scripts in error capture but skips secure or protected frames. On secure frames, wrap our own handlers with `ns.SecureHook` / `ns.SecureSetScript`. A source scan enforces this.
- **Events:** `ns:RegisterEvent(event, fn)`. Internal messages: `ns:On(msg, fn)` / `ns:Fire(msg, ...)`. Config changes: `ns:Changed(group)` fires `CONFIG_CHANGED`.
- **Combat-deferred work:** `ns:AfterCombat(key, fn)`. It runs now if out of combat; otherwise it's queued and deduplicated by key.
- **Existence and grouping:** `ns.Exists(unit)` and `ns.InGroup()` (a secret answer counts as true). Don't call `UnitExists` or `IsInGroup` directly; a test checks this.

## Tests (tests/)
`run.lua` runs every `test_*.lua`. `wow_mock.lua` is the WoW API mock, with secret-value simulation (`S.secretAll` makes values secret even out of combat), combat lockdown, protected-call detection, and range and aura modes. `framework.lua` provides describe/it/expect. `test_mutation.lua` mutates source lines and checks the suite catches each one. When you rewrite a line a mutant targets, retarget the mutant. `secret_scan.lua` is a heuristic scan for truth tests on secret-prone APIs. `aura_geo.lua` is the overlap checker. `tests/README.md` lists every file plus an in-game checklist.
