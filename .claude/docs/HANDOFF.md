# Handoff: continue yesterday's work (written 2026-11-18, late evening)

When the owner says "continue yesterday's work", read this file first, then `.claude/docs/raid-layout-plan.md`.

## Where things stand
- Branch: **`feature/raid-layout`** (created from `main` @ d24867c = v0.10.1). **Nothing committed** since v0.10.1. Commit/push only when the owner asks.
- All agents were stopped on purpose by the owner. No background jobs, no cron.
- Last check (all agents stopped): `HF_SKIP_MUTATION=1 ./run-tests.sh` → **2523 passed, 0 failed, 6 warnings (pre-existing), lint clean.** The full run WITH mutation tests has NOT been done since Phase 2.
- **The owner has NOT restarted WoW with this code.** Don't tell them to restart/reload until tests (incl. mutations) + review are done. New files were added to the TOC → a **full game restart** is needed (not /reload).
- The WoW AddOns folder is a symlink to `HealerForever/` here, so whatever is on disk is what loads.

## Done in this branch (uncommitted)
1. **Fixes from the owner's real error log** (tested, full mutation run was green at 2652 tests before the raid work):
   - `SetTextColor` "bad argument #4" (UnitFrames UpdateName passed the class token as alpha).
   - "ADDON_ACTION_BLOCKED: Button:SetPropagateMouseMotion()" in combat (aura mouse setup now deferred to combat end; XML template defaults click-through). Rule added to wow-api-rules.md.
2. **Buff presets: role rows follow the class row** (owner decision). "None" on Tank/Healer/DPS rows became "Use class row" (default); old empty role rows now follow the class row (owner explicitly approved this behaviour change for old saves).
3. **Raid layout, Phases 0–5 built** (spec: `mockup/raid-style-d.html`; plan: `.claude/docs/raid-layout-plan.md`):
   - Phase 0: party "golden snapshot" test (`tests/test_party_golden.lua`, `tests/fixtures/party-golden-0.10.1.lua`, synthetic old save `tests/fixtures/settings-v0.10.1.lua`). Party must stay identical. **Never regenerate the golden unless the owner wants a party change.**
   - Phase 1: 40 fixed-token secure raid buttons, auto party/raid switching (waits for combat end), separate `ns.db.raid` settings (no schema bump), click-casting on raid bars, `/hf raid`, `/hf debug raid`.
   - Phase 2: style D look (muted when full, big red missing HP centre, small name top-left, DEAD/OFFLINE/…, outlines, range dim, incoming heals).
   - Phase 3: my buffs only (gold = missing, orange + pulse = ending < rebuff %), dispellable-only debuffs (glow + up to 3 icons, falls back to icons if glow fails), smart buff + minimap count raid-aware.
   - Phase 4: "Raid Layout" options tab (switching, Preview full raid, Groups Columns/Rows, "What each corner means" legend, all settings, reset) + `Frames/RaidPreview.lua`, `/hf raid preview`.
   - Phase 5: CHANGELOG "Unreleased" (fixes + role rows + raid layout + /hf perf), docs (architecture, settings, decisions, in-game-testing, addon README), **`/hf perf`** (`Options/Perf.lua`, also in /hf report and /hf copy).
4. Other: `media/screenshots/` (8 cropped in-game screenshots, uploaded to CurseForge Media by the owner); CurseForge description with screenshots was put in the editor (owner clicks Save themselves); mockups in `mockup/` (raid-frames, raid-auras, raid-style-d, curseforge-description).

## Next steps, in order
1. **Tests still missing** (the tester was stopped mid-way; it had written test_raid_layout/frames/clickcast/settings/visuals/buffs/debuffs/preview and was about to write `tests/test_perf.lua`):
   - Check every Phase 1–4 test item in `raid-layout-plan.md` §6 + the builder notes below actually exists; fill gaps.
   - Write `tests/test_perf.lua` (list: profiler present/absent/IsEnabled false/scriptProfile 0/1, secrets → "?", combat no memory refresh, perfOn nil when idle, sampling keys uf/mp/bb (+rf/rfbuffs only with raid), start-while-running refused, clamp 5–600, ticker stops, no debugprofilestop → refused, Report/CopyText blocks, slash/help/bad args, mutants: drop perfOn=true, flip CPU sort, remove scriptProfile check; README row).
   - Raid-pane driving in test_profiles + pane geometry (no overlaps, ≤540 wide), preview tests (refusal messages, auto-off, only non-secure frames, sizes, privacy names), NameWidthCap bounds, secret UnitName in applySmart — verify they exist.
   - Then the **FULL `./run-tests.sh` with mutations** → green.
2. **Review**: DONE (wow-addon-reviewer, 2026-11-19). The builder fixed all 11 findings (uncommitted, 2026-11-19):
   1 glow in a plain holder on its own one-button glow container per bar (we only alpha/show our frames; "glow" display = icon container idle,
   "icons" display = glow never attached); 2 raid aura template with the mouse off (`HealerForeverRaidAuraButtonTemplate`, party template
   unchanged); 3 deficit fallback through `calc:GetMissingHealth()`, percent fallback coloured by `RS.PercentColorCurve()`; 4 deficit text alpha
   from a float Step curve (`RS.HurtAlphaCurve`), full health from 0.995 (`RS.FULL_AT`, also the mute curve); 5 Auto mode in a raid: secure
   visibility drivers on both anchors, party buttons keep their unit watch, so leaving the raid in combat shows the party frames at once
   ("Always raid" unchanged); 6 roster / option bursts coalesced (`RF:RequestEvaluate`, 0.1 s / 0.3 s in combat; immediate when not in a raid),
   re-style only on a settings change (`RF.StyleKey`), in combat only bars whose GUID changed; 7 glow host robustness (dedicated container,
   per-frame holder, init counter keyed by frame), glow under the text, outset <= spacing/2; 8 buff data dropped when the GUID behind a token
   changes; 9 "Offline" tooltip line; 10 `Reserves(cfg, n, mode)` with `RS.DebuffMode`; 11 raid containers created on the first switch to raid.
   **Tester next:** update the tests that assert the old design (list in the builder's report: test_raid_debuffs glow tests, test_raid_visuals
   deficit/mute curve tests, test_aura_container counts, test_raid_frames + test_party_golden "party buttons unwatched", test_aura_combat timer
   count) and add tests for every fix; mock needs a Step-aware `C_CurveUtil.CreateCurve` and a realistic calculator `GetMissingHealth`.
   Then the FULL `./run-tests.sh` with mutations, then a short re-review of the fix diff.
3. **Owner in-game test** (only after 1+2): full WoW restart, then the 10-step raid checklist in `.claude/docs/in-game-testing.md` (party bars unchanged; `/hf raid raid` to force raid layout solo; Raid Layout tab + Preview full raid; real raid join; switch mid-combat waits; click-casting incl. Cmd on raid bars; glow on a dispellable debuff or fallback; buff markers out of combat; `/hf perf`). Use `/hf errors`, `/hf debug raid`, `/hf report`; triage with the `triage-ingame-error` skill. Screenshots: `screencapture -x` (needs dangerouslyDisableSandbox), crop with `sips`, save to `media/screenshots/`.
4. Small UI follow-ups noted by the tester (not done): role popup — unticking a class-row buff on a role row does nothing visible (add a hint); radio groups show inherited buffs unticked while checkboxes show them ticked (make consistent).
5. When the owner is happy: release (skill `release`) — next version e.g. 0.11.0; move CHANGELOG "Unreleased" to the version; commit/tag only when asked.

## Builder notes worth knowing
- Raid uses fixed tokens raid1..raid40 (NOT SecureGroupHeaderTemplate) so strict @unit macros never retarget in combat; layout is a 40-buttons→40-cells bijection.
- In raid mode the smart buff and minimap missing-count REPLACE the party class-buff entries (party1–4 are raid members too). Tank button stays party-only.
- Glow: own one-button container per bar (`Auras.GlowContainerGeometry`); the carrier gets a plain holder frame with the glow texture handed over with `AddDispelTypeTexture` (`showWhenHarmful = true`). Unverified in the real client.
- Deficit uses `UnitHealthMissing(unit, false)` on raid (party still `true`).
- "Name length" caps raid name width via `RS.NameWidthCap` (raid only).
- Unverified in client: float Step curve + `FontString:SetAlpha(secret)` for the deficit, glow carrier shown by the game with max 1 frame, `[group:raid]` visibility drivers on our anchors (raid ending in combat), mouse attributes on the derived raid XML templates, Step curves at 0.995, GetRGBA on curve results, UnitHealthMissing signature, UNIT_* events for raidN, GetRaidRosterInfo secrecy, IsInInstance "pvp", C_AddOnProfiler/Enum metric names, LockHighlight, CPU with 40 bars.

## Standing rules (also in CLAUDE.md / memory)
- Never write the owner's real WTF SavedVariables (read-only; backups in `.settings-backup/`, gitignored).
- New features must not change party settings saved by older versions.
- Mockup first for visuals; use agents (builder/tester/reviewer); short plain-language replies.
- Commits: `git -c user.name="trtg" -c user.email="sc.settech@gmail.com" commit` + the Co-Authored-By / Claude-Session trailer.

## Update 2026-11-19
Steps 1 (tests) and 2 (review + all 11 fixes) are DONE. Full run with mutations: 2969 passed, 0 failed, 394 mutants caught. Then Report.lua secret-safe IsInRaid fix (ns.InRaid) → quick run 2575 passed, lint clean. NEXT = step 3: owner restarts WoW fully and runs the raid checklist in in-game-testing.md. Still nothing committed.
Quick visual fix done (raid text cut on the left = bar glow drawn over the texts + centred text overflow; preview debuff icons now spell icons; 2 px name/number gap). Quick run: only the 16 TOC-version failures (temporary 0.11.0 stamp). Tests for this fix still to add before release.

## TEMPORARY (2026-11-19): TOC says "## Version: 0.11.0" only for screenshots. Revert to "## Version: @project-version@" after the screenshot session, before any commit/release.

- 2026-11-19: screenshot session finished (17 files in media/screenshots, raid shots retaken after the text-clipping/icon fix). TOC version reverted to @project-version@. Still to do before release: tests for the quick visual fix (list in builder report: text frame levels, PlaceText sweep, state text shrink, stacked gap, name drop, fake debuff icons, mutants), cosmetic list (popup see-through + "Not in your spellbook" overflow, wrapped labels "Spacing between frames"/"Spacing between buffs/debuffs and bar"/"rebuff below" labels, outdated "Aura icons have no tooltips" note), then full run.

- Owner (2026-11-19): WAIT for the owner before each of these: (1) tests for the quick visual fix, (3) full test run + release 0.11.0, (4) CurseForge description/media update. (2) cosmetic list is postponed ("we will change it later"). Owner asked why release.sh re-runs the tests; answered, decision pending.

- 2026-11-19 ~12:40: owner said GO for (1) visual-fix tests + full run, then (5) release 0.11.0 (release.sh keeps running tests = option A). Owner checked raid in game: "looks ok for now". (6) CurseForge update only after owner approval. Status cron every 5 min until step 6.

- 2026-11-19: full run green (3000 passed, 407 mutants). CHANGELOG "Unreleased" → "## 0.11.0". ./scripts/release.sh 0.11.0 running (re-runs full tests, log in session scratchpad release.log). Minor latent bugs for later: RS.SetFakeDebuffs keeps "?" icon until type changes (RaidStyle.lua:584); RS.Apply doesnt re-set buff slot/debuff zone levels (RaidStyle.lua:409-412). After zip: ask owner OK for git (commit on branch, merge main, tag v0.11.0, push) and for step 6 (CurseForge).

- 2026-11-19 15:15: owner decision: scripts split. release.sh = build only (no tests). release-tests.sh = full suite then release.sh. test_release.lua updated (35 passed). Docs updated (CLAUDE.md, release skill, tests/README, addon README).

- 2026-11-19 15:16: dist/HealerForever-v0.11.0.zip built (release.sh, 43 files, TOC 0.11.0, sha256 8bdfffb0…ce601). Status cron deleted. Waiting for owner: git OK (commit/merge main/tag v0.11.0/push) and step 6 (CurseForge upload + Media + description).

- 2026-11-19: CurseForge upload form for 0.11.0 filled (display name "Healer Forever 0.11.0", Release, 1.60.1, changelog HTML). Owner clicks Add File. NEXT (owner decides): after CurseForge approves the file → Media (upload new screenshots, remove old) + description update with raid section. Git (commit/merge/tag v0.11.0/push) still awaiting owner OK.
