---
name: add-setting
description: End-to-end checklist for adding, renaming or removing a HealerForever option (default, sanitize, UI, live apply, sparse save, migration, tests).
---

# Adding or changing a HealerForever setting

1. **Default:** add it to `ns.DEFAULTS` in `HealerForever/Core.lua` under the right group (`frames`, `auras`, `buffs`, `pins`, `minimap`, `ui`, …).
   - If it's a table that should be saved whole, such as a list, colour or position, add it to the atomic list used by `BuildSaveTable`.
2. **Sanitize:** validate it on load (type, numeric range, enum). Bad or missing values fall back to the default. Never crash on corrupted saves.
3. **UI:** add the control in the matching `Options/*` pane using the widgets in `Options/Widgets.lua`, and label it the way the owner would read it.
   - Write the value to `ns.db`, then call `ns:Changed("<group>")`.
4. **Live apply:** handle `CONFIG_CHANGED`. Anything that resizes, moves, shows or hides secure frames, or changes their attributes, goes through
   `ns:AfterCombat(key, fn)`. Non-secure visuals can update right away.
5. **Rename or remove:** add `ns.migrations[n]` (n is the old schema) and bump `ns.DEFAULTS.version`. Delete or rename the old key there.
   Note it in `CHANGELOG.md`.
6. **Tests** (delegate to the `wow-addon-tester` agent):
   - the default value;
   - sanitizing bad values;
   - the control saves and applies live;
   - surviving `BuildSaveTable` and reload;
   - not saved when equal to the default;
   - applying in combat is queued;
   - everything-secret mode doesn't error.
7. If it's visual, do a mockup first (`mockup-first` skill).
