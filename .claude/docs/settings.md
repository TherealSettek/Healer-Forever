# Settings, saving and migrations

## Storage
- `HealerForeverCharDB` (SavedVariablesPerCharacter) is the **active** store, saved per character in
  `WTF/Account/<acct>/<realm>/<char>/SavedVariables/HealerForever.lua`.
- `HealerForeverDB` (account-wide) is **legacy** and never written. Since 0.12.1 it is **not** copied into new characters any more:
  a character without `HealerForeverCharDB` always starts from clean `ns.DEFAULTS` (owner decision 2026-11-20).
  `/hf copyaccount [confirm]` imports it on request (`migratedFrom = "account"`). If the copied presets hold a buff key outside
  `Classes.CatalogBuffs(<player class>)`, presets and bindings stay at the defaults and the command says so.
  `/hf profile` shows which profile is active. `/hf reset` resets the current character only.
- **One-time cleanup (0.12.1, no schema bump):** on load, a profile with `migratedFrom == "account"` whose presets hold a buff the
  player's class can't cast (`ns.PresetsHaveForeignBuffs`) gets `presets`, `activePreset` and `bindings` reset to the defaults, one chat
  line, and `migratedFrom = "account-cleared"` so it never runs again. Everything else is kept. Class read with `pcall(UnitClass, "player")`;
  secret/unknown class = nothing changes. A matching class (the owner's Paladin seeded from the Paladin account DB) is left untouched.

## Runtime vs disk (sparse save, schema v3)
- At runtime `ns.db` is a **full** table: saved values merged over DEFAULTS, then sanitized, then migrated.
- On `PLAYER_LOGOUT`, `ns:BuildSaveTable()` writes **only what differs from DEFAULTS** (`Util.DiffFromDefaults`). That way, improved defaults
  reach users who never changed them.
- **Atomic tables** are saved whole when they differ and omitted when equal: `bindings`, `presets`, `frames.order`, `frames.point`,
  `roleOverrides`, `customSpells`, and custom colour tables. A deleted default binding stays deleted because its table differs.
- Always kept: `version`, `migratedFrom`, and a non-empty `errorLog` (capped at 50 entries, with repeats counted).

## Raid layout settings (`raid`, added after 0.10.1, no schema bump)
- All raid options live under `ns.db.raid` (defaults in `ns.DEFAULTS.raid`): `layoutMode` (auto|party|raid), `onlyAbove5`, `point`, `scale`,
  `width`, `height`, `spacing`, `groupArrange` (columns|rows), `groupsPerLine` (8|4|2), `groupLabels`, `sortWithin` (none|role|class),
  `hideEmptyGroups`, `showNames`, `nameSize`, `nameLength`, `healthText` (deficit|percent|none), `muteFull`, `showIncoming`, `rangeAlpha`,
  `buffs.{show,size,rebuffPercent,showEnding,endingLook,multi,inCombat}`, `debuffs.{show,display,max,size}`. Ranges and enums are in
  `.claude/docs/raid-layout-plan.md` §1.
- **No schema bump and no migration:** the keys are new, so old saves simply don't have them and get the defaults. Nothing that 0.10.1 saved
  changes (`tests/test_raid_settings.lua` and the 0.10.1 fixtures check this).
- Validation is the pure `RaidLayout.Normalize(r)`, called from `buildDB`. Bad values fall back to the default.
- **Sparse save:** an untouched raid block writes no `raid` key at all; one change saves only that leaf. `raid.point` is **atomic** (the global
  `point` entry in `ATOMIC_KEYS`), so a moved raid frame saves the whole point table. Don't name raid sub-keys `order` or `custom`: those names
  are atomic globally.
- The lock is shared: the raid uses `frames.locked`. The preview state (on/off, size) is runtime only and never saved.
- "Reset raid defaults" in the Raid Layout tab resets everything under `raid` except `point`.

## Threat bar settings (`frames`, added after 0.11.0, no schema bump)
- `frames.showThreatBar` (boolean, default `false`), `frames.threatBarHeight` (whole number 2-6, default 3; clamped and rounded in
  `buildDB`), `frames.threatBarOnlyCombat` (boolean, default `true`), `frames.threatBarShowSafe` (boolean, default `false`: green strip at
  threat level 0, added 2026-11-20). Wrong types fall back to the default (generic `sanitize`).
- New keys only, so old saves get the defaults and party frames look exactly as in 0.11.0 while the bar is off (the strip's textures
  aren't even created then). Untouched values are not saved (sparse save).
- Turning the bar on reserves `height + 2 (black edge) + 1 (gap) + border outset` px above the health bar (layout, out of combat only).

## Clean-install defaults (deliberate, see decisions.md)
- Bindings: only plain Left = target and plain Right = menu.
- One empty preset, "Default". No buff buttons appear until the user adds rules.
- `roleOverrides`, `customSpells` and extras are empty.
- Opt-in loaders: "Load example: Paladin" (adds a preset; never overwrites) and "Load example bindings (Paladin)" (fills empty slots only).

## Adding a setting (checklist, also in the `add-setting` skill)
1. Add the default to `ns.DEFAULTS` in `Core.lua`. Decide whether it's atomic for sparse save.
2. Validate it on load in sanitize: type, range or enum. Bad values fall back to the default.
3. Add a UI control in the right pane (`Options/*`) and call `ns:Changed("<group>")`. Apply it live. Anything that touches secure frames goes through AfterCombat.
4. Write tests for the default, sanitizing a bad value, live apply, and that it survives sparse save and reload (see `test_shipping.lua` and `test_profiles.lua`).
5. If you rename or remove a key, add a step to `ns.migrations` and bump `DEFAULTS.version`. Add an old-format fixture to the tests.

## Migrations
`ns.migrations[n]` upgrades schema n to n+1, runs once, in order. The current schema is **4**. The v3→v4 step converts every preset cell and
`self` from a single buff key into a **set of keys** (at most one per catalog group): `"kings"` becomes `{ "kings" }`, and `"none"`/nil become `{}`. A saved version newer than the code means a downgrade: the addon warns once,
doesn't migrate backwards, and doesn't crash. Keys removed so far, which are deleted on load: `frames.style`, `appearance`, `ui.appearanceTarget`,
`hideBlizzardParty`, `taintMigrated`.

## Versioning
`## Version: @project-version@` in the TOC is stamped by `scripts/release.sh`. `ns.AddonVersion()` returns "dev" when the TOC isn't stamped.
The version shows in `/hf version`, the options title and the options footer (`Healer Forever vX · settings v3`). The settings schema version
(`DEFAULTS.version`) is separate from the release version.
