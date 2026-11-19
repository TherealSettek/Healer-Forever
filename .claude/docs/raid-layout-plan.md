# Raid layout: implementation plan (style D)

Spec: `mockup/raid-style-d.html` (Decided box, options panel, API notes) + `mockup/raid-frames.html` (preview, layout switching).
Branch: `feature/raid-layout`. Nothing is committed unless the owner asks.

## Owner decisions (2026-11-18), final
- Separate Raid layout with its OWN settings (`ns.db.raid`). **Party layout and every setting saved by previous versions stay exactly as they were** (hard rule, see memory "updates-keep-user-settings").
- Auto switching: Layout Auto / Always party / Always raid (default Auto); "raid layout only above 5 players" (default on). Battlegrounds = raid. Switch only out of combat.
- Style D "Hurt stands out": muted at full health, full colour when hurt; missing HP big bold red in the centre (never cut); name small top-left (cut first); DEAD/GHOST/OFFLINE/CAN'T RES/"?" in the centre.
- Groups Columns / Rows option + groups per line 8 / 4×2 / 2×4. "What each corner means" legend in the options.
- My buffs only: top-right small spell icon, gold border = missing, orange border + PULSE = ending (< rebuff %, default 5). Several buffs: "one icon per state" default (first missing + count badge, plus first ending; max 2). Out of combat only; hidden in combat (option: keep last known dimmed). Not clickable.
- Debuffs: only types my class can dispel; display "Glow + icons" (bar edge glow in the first dispellable type colour + game-drawn icons bottom-right), max 3 (shrink to fit). Glow "needs checking in game", fallback icons.
- "Preview full raid" button (10/20/25/40), not clickable, auto-off on combat / real raid, never saved.
- Open questions resolved with the recommended defaults (owner said "go build it"): smart buff key covers the raid while the raid layout is active; a ≤5 raid split across subgroups uses the raid layout; group labels G1–G8 on; raid shares the existing "Lock frames" toggle; default raid position TOPLEFT 60,-330 (tune in game).

## 0. Architecture: 40 fixed-token SecureUnitButtons (not SecureGroupHeaderTemplate)
Our own 40 `SecureUnitButtonTemplate` buttons with fixed tokens `raid1..raid40`, shown/hidden by `RegisterUnitWatch`, positioned out of combat (same model as party). Reasons: ClickCast bakes `@unit` into strict macros and state drivers (`[@unit,dead]`, `hfmeta`) out of combat; a header re-assigns `unit` in combat → casts on the wrong person. Fixed tokens stay correct in combat; only the cell position can be stale until combat ends. `applyToButton` works unchanged.
Roster: layout is a bijection of 40 buttons onto 40 cells (8×5): members fill their group's cells in sort order; unused buttons fill the remaining free cells deterministically, so a mid-combat joiner shows in a unique free cell and never covers another bar. "Hide empty groups" = non-empty groups first, empty last, anchor sized to visible groups only.
"Always raid" outside a raid: first 5 buttons get `player`, `party1..party4`; tokens change only out of combat, then ClickCast re-applies.

## 1. Settings (`ns.DEFAULTS.raid`, new sparse keys, NO schema bump)
```lua
raid = {
  layoutMode = "auto", onlyAbove5 = true,
  point = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 60, y = -330 },
  scale = 100, width = 64, height = 24, spacing = 2,
  groupArrange = "columns", groupsPerLine = 8, groupLabels = true,
  sortWithin = "none", hideEmptyGroups = true,
  showNames = true, nameSize = 7, nameLength = 7,
  healthText = "deficit", muteFull = true, showIncoming = true, rangeAlpha = 50,
  buffs = { show = true, size = 10, rebuffPercent = 5, showEnding = true,
            endingLook = "pulse", multi = "state", inCombat = "hide" },
  debuffs = { show = true, display = "glowIcons", max = 3, size = 10 },
}
```
Ranges: scale 50–150 step 5; width 40–120; height 14–40; spacing 0–8 (group gap = spacing + 6); nameSize 6–10; nameLength 3–12; rangeAlpha 10–100 step 5; buffs.size 8–16; rebuffPercent 1–20; debuffs.max 1–3; debuffs.size 8–16. Enums: layoutMode auto|party|raid; groupArrange columns|rows; groupsPerLine 8|4|2; sortWithin none|role|class; healthText deficit|percent|none; endingLook pulse|sweep|border; multi state|first|stack; inCombat hide|dim; display glowIcons|icons|glow.
Validation in pure `RaidLayout.Normalize(r)` called from `buildDB`. Don't name raid subkeys `order` or `custom` (atomic globally). Lock reuses `ns.db.frames.locked`. Preview state runtime only. Dropped from mockup: "Letters" debuff modes and "All dispellable types" (need the secret debuff type in our code / no game filter) — note in decisions.md.

## 2. Files
New:
- `Util/RaidLayout.lua` (pure, load right after Util/Util.lua; add to tests/loader.lua CONTRACT_FILES): `Normalize`, `DesiredLayout(ctx)` → "party"|"raid" + reason, `GroupOrder`, `GridCells(cfg, groupOrder)`, `AssignCells(roster, cfg)` (bijection), `TextLayout(cfg, rightReserve)` (number never <10 px and never cut; name cut first, dropped below 6 px), `DebuffIconSize(width, max, base)` = `max(7, min(base, floor((floor(w*0.45)-1)/max)-1))`, `BuffMarkers(report, multi, showEnding)`, `NextBuffCheck(report, percent, now)`.
- `Frames/RaidStyle.lua`: `RS.Build(frame)` creates all style-D regions (health bar, prediction, name, centre text, 3 buff marker slots with border/count/pulse anim, debuff zone, glow texture, target/aggro outlines, dash frame); `RS.Apply(frame, cfg)` sizes + text layout. Shared by real buttons and preview.
- `Frames/RaidFrames.lua` (`ns.RaidFrames`, RF): anchor `HealerForeverRaidFrame` + drag handle/outline, 40 buttons `HealerForeverRaidUnit1..40`, switching, layout, unit updates, buff markers, debuff containers, `/hf debug raid`.
- `Frames/RaidPreview.lua` (`ns.RaidPreview`): 40 plain `ns.NewFrame("Frame")` frames via RS.Build, fake data, solid gold "PREVIEW, not real players" tag.
- `Options/RaidPane.lua`: "Raid Layout" tab after Frames & Bars.
Changed:
- TOC: `Util\RaidLayout.lua` after Util; `Frames\RaidStyle.lua`, `Frames\RaidFrames.lua`, `Frames\RaidPreview.lua` after `Frames\UnitFrames.lua`, before ClickCast; `Options\RaidPane.lua` after `Options\Panes.lua`. (Owner must restart the game.)
- Core.lua: DEFAULTS.raid, Normalize in buildDB; secret-safe helpers `ns.InRaid()` (secret → true), `ns.GroupSize()` (secret → 40), `ns.InstanceType()` (secret → "none").
- UnitFrames.lua (party must be byte-for-byte identical when party is active): `UF:SetSuspended(bool)` out of combat (unwatch + hide party/pet buttons + anchor; un-suspend runs today's Layout); export locals `UF.LayoutDashes`, `UF.SetPercentText`, `UF.SetDeficit`, `UF.ClassColorFor`, `UF.ComputeState`; ShowTooltip appends `button.tooltipExtra(button)` when present; DebugClick also looks in `ns.RaidFrames.byUnit`; CONFIG_CHANGED early-returns for group "raid".
- Auras.lua: `Auras.CreateDebuffContainer(button, zone, geom, hooks)` reusing createContainer/initializeFrame/configureFrame/applyMouse (raw CreateFrame allow-list stays 1); `hooks.onInit(frame, index)` for the glow; `Auras.SetContainerUnit(st, unit)` with the same no-combat rule as applyUnits. Party path untouched.
- ClickCast.lua: ApplyNow applies to UF.buttons (unchanged) + `RF:ActiveButtons()`; when raid inactive, raid buttons cleared (clearButton, ClearOverrideBindings, UnregisterStateDriver hfmeta/hfdead). Listen to RAID_FRAMES_CREATED / RAID_LAYOUT_CHANGED. `CC:ApplyToButtons(list)`.
- BuffButtons.lua: `evaluate(unit, cache, percentOverride)` (party passes nil); export `BB.EvaluateUnit`, `BB.Gather`; smart buff includes the raid pending list while raid is active; MissingCount adds `RF:MissingCount()` when raid active.
- Slash.lua: `/hf raid`, `/hf raid preview [10|20|25|40|off]`, `/hf debug raid`, `/hf debug click raidN`. Report.lua: raid summary line + active layout and reason.
- Docs: CHANGELOG "Unreleased", architecture.md, settings.md, decisions.md, in-game-testing.md (commands + checklist), tests/README.md.

## 3. Phases
Phase 0 (tester, BEFORE builder changes): party golden snapshot `tests/test_party_golden.lua` (`snapshotParty(ns)`: every party/pet button's hfAttrs (macros), unit, snippets, size, points, shown, scale, health text output, bar colours, aura container filter/max/geometry, BB attrs/state, smart/tank attrs) for (a) solo defaults, (b) 3-member party with the Paladin example, (c) a synthetic 0.10.1-shaped save fixture. Store as `tests/fixtures/party-golden-0.10.1.lua`. After the feature it must be identical with default raid settings and with layoutMode="party" in a 25-man raid.

Phase 1: core secure raid frames, switching, settings, click-casting.
- RF:Create on FRAMES_CREATED via AfterCombat("rf-create"): anchor (plain, movable, clamped), handle/outline like party, 40 buttons template `SecureUnitButtonTemplate,SecureHandlerEnterLeaveTemplate,SecureHandlerStateTemplate,BackdropTemplate`, RegisterForClicks("AnyUp") only, SetAttribute("unit", token), ns.SecureHook for OnShow/OnEnter/OnLeave. Fire RAID_FRAMES_CREATED.
- RF:Evaluate on PLAYER_ENTERING_WORLD, GROUP_ROSTER_UPDATE, CONFIG_CHANGED raid/all, ZONE_CHANGED_NEW_AREA: mode party→party; raid→raid; auto: pvp→raid; not in raid→party; in raid: onlyAbove5 and size≤5 and all in my subgroup→party else raid; arena→party. If different: in combat AfterCombat("raid-switch") + one chat line; else apply.
- RF:Apply (out of combat): raid = UF:SetSuspended(true), tokens, Layout, unit watch on 40, CC:ApplyToButtons, container units, show anchor; party = reverse + containers "none" + clear raid click attrs + UF:SetSuspended(false). Fire RAID_LAYOUT_CHANGED.
- RF:Layout (out of combat, else queue "rf-layout"): GetRaidRosterInfo pcall'd + secret-guarded (subgroup fallback ceil(i/5)); sort role (ns.Roles.Get) / class, unknowns last, ties by index; AssignCells; SetPoint; anchor size + SetScale(scale/100); group labels; point + lock; UpdateEverything. In combat GROUP_ROSTER_UPDATE refreshes visuals only and queues layout.
- Alias map player/party1-4 → raid button with same unit (UnitIsUnit, skip secret) for event routing.

Phase 2: style D visuals.
- Health SetMinMaxValues/SetValue (secret-safe). Muting: per-class Step colour curve (0 → full colour, 1 → muted = class*0.38 + #2a2a2a*0.62), `pcall(bar:SetStatusBarColor(UnitHealthPercent(unit,false,curve):GetRGB()))`; fallbacks: readable hp==max → muted; secret/no API → full colour. Dead/ghost/offline/not visible grey.
- Deficit: UnitHealthMissing → UF.SetDeficit; "only when hurt" via text colour from a Step alpha curve (alpha 1 at 0, 0 at 1). Fallbacks: readable max-hp >0; else percent via UF.SetPercentText; else "". Percent mode similar.
- Centre text bold outlined, size from TextLayout. Name GameFontNormalSmall at nameSize, no word wrap, width from TextLayout (never string.sub), hidden if showNames off or width <6; side-by-side anchors name TOPRIGHT to number TOPLEFT -3. Own name gold.
- State text DEAD/GHOST/OFFLINE/"?"/CAN'T RES. Outlines: target white (SetAlphaFromBoolean if secret), aggro red (UnitThreatSituation>=2, keep last known if secret), out of range dashed 4/3 via UF.LayoutDashes, not visible dotted 2/3; range dims button to rangeAlpha (SetAlphaFromBoolean when secret). No badge. Prediction bar, no text.
- Throttle: event-driven health/target; one OnUpdate on the raid anchor (idle when hidden): 0.2 s tick, round-robin 10 buttons UpdateState/UpdateRange; raid tooltip refresh 0.5 s. No region creation per update.

Phase 3: my buffs + debuffs.
- Markers non-secure, EnableMouse(false) once at Build. 0.5 s ticker out of combat while raid active, ≤8 units/tick (dirty by UNIT_AURA/roster/combat end/config + nextCheck due). BB.EvaluateUnit(unit, cache, rebuffPercent) → RaidLayout.BuffMarkers. Icon BB.IconFor; gold (1,0.82,0) missing, orange (1,0.54,0.1) ending; endingLook pulse (AnimationGroup BOUNCE alpha, Play/Stop only on state change) / sweep (Cooldown, SetHideCountdownNumbers) / border; count badge >1; top-right growing left. Combat: hide, or dim (alpha 0.45 + desaturate); regen marks all dirty. Tooltip extra lines out of combat; in combat "My buffs are re-checked after combat".
- Debuffs: per button Auras.CreateDebuffContainer filter `HARMFUL|RAID_PLAYER_DISPELLABLE`, maxFrameCount = max, size DebuffIconSize capped at height-2, BOTTOMRIGHT growing left, dispel border on, mouse off via applyMouse. Glow (glowIcons/glow): bar-sized `button.dispelGlow` above the health bar, outset 2; in onInit for frame 1 only: `frame:AddDispelTypeTexture(button.dispelGlow, { style = Enum.CustomAuraButtonDispelTypeTextureStyle.Border, showWhenHarmful = false })`; display "glow" = icon alpha 0. On error: log once, RF.glowSupported=false, fall back to icons, reported in /hf debug raid. Container units: token only out of combat; "none" in party mode; GUID change mid-combat queued.

Phase 4: options tab + preview.
- RaidPane sections: Layout switching (+ live status label), Preview (ON/OFF button, size, message label, note), Groups, "What each corner means" legend, Size, Bar, My buffs, Debuffs (disable glow choices with a note when glowSupported==false), Range, "Reset raid defaults" (keeps point). Setters `ns.db.raid.k = v; ns:Changed("raid")`. RF re-layout (queued in combat) + preview re-render on CONFIG_CHANGED raid.
- RaidPreview: SetOn refused in combat / in a raid; lazy 40 frames; fake privacy-safe names; same RS.Apply/GridCells/TextLayout at raid.point; player's class dispels (Classes.DATA[class].dispels) and catalog buffs (Classes.CatalogBuffs) with BB.IconFor; debuff icons as textures with Classes.DISPEL_COLORS borders; glow vertex-coloured; mouse only for a fake tooltip, OnClick nothing; drag handle (unlocked) moves raid.point; auto-off on PLAYER_REGEN_DISABLED and GROUP_ROSTER_UPDATE with InRaid (chat line); live update.

Phase 5: tests + docs (see §6).

## 4. Events
PLAYER_LOGIN create; PLAYER_ENTERING_WORLD / ZONE_CHANGED_NEW_AREA / GROUP_ROSTER_UPDATE evaluate + layout; PLAYER_REGEN_DISABLED preview off + markers hide/dim; PLAYER_REGEN_ENABLED AfterCombat + markers dirty; UNIT_HEALTH, UNIT_MAXHEALTH, UNIT_HEAL_PREDICTION, UNIT_NAME_UPDATE, UNIT_CONNECTION, UNIT_FLAGS, UNIT_IN_RANGE_UPDATE, UNIT_THREAT_SITUATION_UPDATE via RF.byUnit + RF.alias (only when shown); PLAYER_TARGET_CHANGED; UNIT_AURA marks buffs dirty (out of combat); PLAYER_ROLES_ASSIGNED re-sort; SPELLS_CHANGED buffs dirty. Internal: RAID_FRAMES_CREATED, RAID_LAYOUT_CHANGED.

## 5. Combat/taint pitfalls
All protected ops on the 40 buttons/anchor via AfterCombat keys rf-create, raid-switch, rf-layout, clickcast. No group header. Raid code never calls a mouse setter in combat. ns.SecureHook only on raid buttons. Aura reads out of combat only; debuffs game-drawn. Container SetUnit never in combat. Secrets: widget setters only, no truth tests (secret_scan.lua must cover new files). Idle in party mode: anchor hidden, containers "none", raid drivers unregistered, ticker idle. Don't hide Blizzard raid frames (taint). Silent AfterCombat + own single message.

## 6. Tests
Mock (tests/wow_mock.lua): `M.setRaid(n, opts)` (raid1..N, class/role/hp/subgroup/name, playerIndex alias; S.inRaid/inGroup/raidSize); UnitExists raidN; GetNumGroupMembers; GetRaidRosterInfo 12 returns (S.secretRoster → secret subgroup/role); UnitIsUnit alias; IsInInstance → S.instanceType; Register/UnregisterUnitWatch recorded + violation in combat, `M.applyUnitWatch()`; Register/UnregisterStateDriver recorded per frame + violation in combat; protected-parent IsProtected; CreateColor:GetRGBA; Step curves opt-in; UnitHealthPercent(unit,p,curve); UnitHealthMissing; removable via M.setGlobal(name, nil).
New files: test_raid_layout.lua (pure: DesiredLayout table, GridCells, AssignCells bijection incl. secret roster, hideEmpty, TextLayout sweep 40–120 × 14–40 × 6–10 never cuts number, DebuffIconSize, BuffMarkers, NextBuffCheck); test_raid_frames.lua (creation/templates/AnyUp, party mode idle, join raid out of combat and in combat (no violations, switch on regen), leave, battleground, Always raid tokens, mid-combat roster change, secret roster, alias routing); test_raid_clickcast.lua (strict @raidN macros ≤255, hfdead token, Cmd swap, hover snippets, no restricted closure in xpcall, cleared after switching to party); test_raid_visuals.lua (muting, deficit + alpha, all-secret combat, API fallbacks, states, outlines, range, geometry no-overlap via aura_geo.lua); test_raid_buffs.lua (modes, pulse only while ending, combat hide/dim, regen recheck, throttle ≤8/tick, none in party mode, not clickable); test_raid_debuffs.lua (filter/max/size, unit token vs none, glow registered once, error fallback logged once, lazy pool in combat no blocked mouse calls); test_raid_preview.lua (off by default/after reload, refused in combat/raid, auto-off, only non-secure frames, live update, sizes); test_raid_settings.lua (defaults, sanitize, sparse save: unchanged raid → no `raid` key, single change saves only that leaf, round trip, reset keeps point); test_raid_upgrade.lua (HARD REQUIREMENT): a SYNTHETIC schema-4 / 0.10.1-shaped save fixture (no real names, no personal data — do NOT copy the owner's real SavedVariables into tests) → every saved key keeps its value, BuildSaveTable deep-equals (no `raid` key, version unchanged), golden party snapshot identical (solo, party, 25-man with layoutMode="party"), /reload twice stable. Extend test_profiles (drive raid pane), test_errors (CreateFrame allow-list unchanged), test_toc, test_shipping, test_privacy (fixture names), test_mutation (DesiredLayout >5, bijection fill, deficit alpha point, name-before-number, 0.45 icon width, BuffMarkers state max 2, raid-switch InCombat guard, CC clearing raid attrs).

## 6b. Queued after raid Phase 1: `/hf perf` (owner approved 2026-11-18)
Why: a user reported the game got slow with many addons and Questie's minimap quest circles disappeared after enabling Healer Forever. Our errorLog only sees our own errors, so we need numbers.
- `/hf perf`: per-addon CPU/memory for Healer Forever vs. the other loaded addons, using the client's addon profiler (`C_AddOnProfiler.GetAddOnMetric` / `Enum.AddOnProfilerMetric` if present on Forever; fallback `UpdateAddOnMemoryUsage` + `GetAddOnMemoryUsage`, and `GetAddOnCPUUsage` only when the `scriptProfile` CVar is on — say so instead of showing zeros). Show top N addons + ours, readable lines; pcall every call; never secret-unsafe.
- Optional `/hf perf start` / `/hf perf stop`: sample ours over a window (e.g. 60 s) and print averages/peaks; also time our own hot paths (UF OnUpdate 0.25 s, MP:Update 0.15 s, BB ticker 0.5 s, raid ticker) with `debugprofilestop()` counters.
- Add the perf summary to `/hf report` and `/hf copy`; add to `ns.SLASH_COMMANDS` (Help & Contact tab picks it up).
- Also investigate the Questie report: confirm our minimap pins never touch Minimap state (zoom, mask, blips, children) and check frame-level overlap with HereBeDragons pins; consider pins only while grouped (already) and a lower frame level. Document findings in in-game-testing.md.
- Tests: mock the profiler APIs (present / absent / scriptProfile off), output format, no errors when APIs missing, report includes perf block. CHANGELOG entry.

## 7. Unverifiable without the real client
AddDispelTypeTexture on an outside bar-sized texture; UnitHealthMissing/UnitHealthPercent signatures, Step curves at 1.0, GetRGBA, SetFormattedText with secret AbbreviateNumbers; UNIT_* events for raidN of player/subgroup; raid index renumbering mid-combat and container following a token; GetRaidRosterInfo secrecy, IsInInstance "pvp"; CPU in a 40-man; font metrics; SetScale hit-rects for Cmd hover route; hfmeta driver on 40 buttons; CAN'T RES reliability.
