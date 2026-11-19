# Healer Forever: project guide for Claude

A World of Warcraft **WoW Forever** healer addon: party frames, click-casting, buff presets, range states,
minimap pins and a minimap button. The owner plays a **Paladin healer on macOS**.

Read this file first, then the docs in `.claude/docs/` that match the task.

| Doc | When |
|---|---|
| `docs/architecture.md` | Where code lives, load order, module responsibilities |
| `docs/wow-api-rules.md` | **Before touching any Lua.** Secret values, taint, combat lockdown, secure clicks, Cmd |
| `docs/settings.md` | Saved settings, sparse save, migrations, adding an option |
| `docs/decisions.md` | What the owner chose, and why (look, defaults, UX). Don't re-litigate these |
| `docs/in-game-testing.md` | How the owner tests in WoW, debug commands, reading the real error log |

## Repo layout
```
HealerForever/        the addon (only this folder ships)
tests/                Lua 5.1 / LuaJIT test suite with a WoW API mock (run via ./run-tests.sh)
mockup/               HTML mockups (served at http://localhost:8765/ via python3 -m http.server)
scripts/release.sh    build dist/HealerForever-v<ver>.zip (no tests); scripts/release-tests.sh runs the full suite, then release.sh
.github/workflows/    test.yml (push to main + PRs, runs with HF_SKIP_MUTATION=1 to save free-plan minutes). No release workflow on purpose.
.settings-backup/     the owner's REAL SavedVariables backups (gitignored, never publish)
CHANGELOG.md          release notes
```

## Commands
- `./run-tests.sh`: luacheck + full suite. Takes several minutes, and the mutation tests are the slow part. `./run-tests.sh <filter>` runs matching files only.
- `luacheck HealerForever --config .luacheckrc` (installed in `~/.luarocks/bin`).
- `./scripts/release.sh 0.9.1`: stamp the TOC version and zip to `dist/` (does NOT run the tests). `./scripts/release-tests.sh 0.9.1`: full suite (with mutations) first, then the same build; nothing is built if a test fails.
- Mockups: `cd mockup && python3 -m http.server 8765`.

## Hard rules
1. **Never modify the owner's real settings.** They live in
   `/Applications/World of Warcraft/_forever_/WTF/Account/415205454#1/…/SavedVariables/HealerForever.lua`.
   Read them only to diagnose, because they contain `errorLog` entries from the real game. Back them up to `.settings-backup/` before
   any change that affects saved data. Tests use copies in `tests/fixtures/`.
2. The addon folder in WoW is a **symlink** to `HealerForever/` here, so edits are live after a game restart or `/reload`.
   A restart is needed when files are added or removed or the TOC changes.
3. Follow `docs/wow-api-rules.md`. Every real in-game bug so far came from breaking one of those rules.
4. Every change gets tests. The owner expects "test it fully so there are no errors". Keep `./run-tests.sh` green
   with lint clean. Don't weaken tests to make them pass.
5. Don't commit or push unless the owner asks. Branch first if on `main`. Keep `.settings-backup/` and `dist/` out of git.

## How the owner likes to work
- **Mockup first** for anything visual. Build an HTML mockup with 3–4 options side by side and an options panel, open it in
  Chrome, and let the owner pick. Then implement. See the `mockup-first` skill.
- **Use agents** for building, testing and reviewing; the owner asked for this explicitly. The project agents are in `.claude/agents/`.
- Short status replies in plain language. The owner tests in game and pastes Lua errors; triage them with the
  `triage-ingame-error` skill.
- The owner writes casually with typos; infer intent and confirm only when ambiguous.

## Unverified on the real client (check before relying on them)
- Several texture and atlas paths (minimap orb pieces, role atlases, skull, edge arrow). All have fallbacks.
- `GameTooltip:SetUnitBuffByAuraInstanceID` / `SetUnitDebuffByAuraInstanceID` (there's a fallback chain).
- Real font metrics for aura timers (the tests model them).
