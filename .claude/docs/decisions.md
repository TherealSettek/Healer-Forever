# Owner decisions (don't re-litigate without asking)

## Look
- Vanilla-WoW feel overall.
- **Party frames:** the *original* bar look plus a **border around the health bar and the power bar** (default: tooltip style, thickness 2, black).
  The owner rejected the A/B/C frame-style system and "frames around tiles", and asked for "only bars". The mockup is `mockup/frame-styles.html#orig-borders`.
- **Buffs and debuffs are separated:** buffs above the bar, debuffs below (larger, with dispel-colour borders). Timers sit on their own line under each icon,
  with a 4 px gap between zones and the bar. The positions are configurable.
- **Range:** style **B, "Range badge"** (`mockup/range-states.html`). Out of range: slightly dimmed, an "OUT OF RANGE" badge and a dashed grey outline.
  Healable: a subtle green edge. Not visible: a "NOT VISIBLE" badge, a blue-grey dotted outline and "?" health. Dead and out of reach: "CAN'T RESURRECT".
- **Minimap pins:** design **A, "Class orbs"** (`mockup/minimap-pins.html`), plus a **red X at the spot where a member died** (corpse marker,
  kept after release; the ghost shows as a separate grey orb).
- **Minimap button:** design **B, "Status badges"** (`mockup/minimap-button.html`). A heal icon, a red/green missing-buff dot, a lock badge and the preset
  initial. Left = options, Right = lock/unlock bars, Shift = next preset, drag = move.

## Behaviour
- **No casting on yourself by accident.** If the target is out of range or sight, nothing casts. This applies to every click-cast and buff button.
- Out-of-range buff buttons are disarmed and dimmed. The smart buff skips unreachable members.
- Tank-only role buffs (e.g. the Paladin talent oath): one target at a time, hidden when the tank already has the buff, shown again under 60 s remaining.
- Hover tooltip on a bar: only the bindings for the **currently held modifiers**, plus **all debuffs** with name, type, stacks and time.
- Hover tooltip on an aura icon: Blizzard's real aura tooltip (option, default on).
- Dead member: any click casts the class res spell.
- Buff presets are chosen from a **dropdown** (not buttons). Rules are per class × role (Tank/Healer/DPS) plus a "Self (you)" override.
- Settings are **per character** and must never override the owner's existing settings.
- **Shipping:** clean defaults (nothing preset), sparse save, and the version visible in options. Releases are a **manual CurseForge upload** of
  the `scripts/release.sh` zip, game version "Forever 1.60.1". **No GitHub Release workflow**, because the owner is on the free plan, and CI skips the mutation tests.
  The first version is 0.9.0 (beta).

## Removed on purpose
- "Hide Blizzard party frames" (taint).
- The A/B/C frame styles and appearance system.
- The mouse-over highlight (dropped with the restyle; the owner may ask for it back).

## Buff presets: class-aware, stacking groups (0.10.0)
- The addon is shared with players of other classes, so buffs come from a per-class **catalog** of groups. The owner's own Mage example: "AI and
  Dampen or Amplify or none". Same group = mutually
  exclusive (Paladin blessings, Mage Dampen/Amplify); different groups stack (Priest Fortitude + Spirit, Druid Mark + Thorns).
- A preset cell is a **set** of buff keys. One click or key press can only cast ONE spell (secure action rule), so the button shows the
  next missing buff with a count badge and re-arms after each cast. Right-click casts the group version (Greater / Prayer / Brilliance / Gift).
- Only spells the character knows are armed; unknown ones are greyed with "Not in your spellbook". Role buffs (extras) are unchanged.
- Schema v4 converts every single-key cell to a one-element set and "none" to an empty set; legacy and example presets convert the same way.

## License and contact (0.10.1)
- **All Rights Reserved**, copyright trtg. `HealerForever/LICENSE.txt` ships in the zip, with a copy at the repo root. The TOC has `## X-License: All Rights Reserved`.
  On CurseForge, pick "All Rights Reserved". Code stays readable (Blizzard policy); nothing obfuscated.
- Support email: **healer.forever.trtg@gmail.com**. It's shown in a read-only copy box in the "Help & Contact" tab (option B in `mockup/contact.html`),
  with "Report a problem" (copy window: versions, game build, locale, class, settings summary, other addons, errors, debug, `/hf mark` snapshots).
  Commands: `/hf report`, `/hf contact`, `/hf mark [note]`. Nothing is ever sent automatically.
- Other addons' code is only read for ideas, never copied (HealKit and Bagnon are all-rights-reserved).

## Branding
- Project logo: design **C, "Healing bar"** (a green plus over a stylised health bar), from `mockup/logo.html`. Original artwork with no game assets.
  The PNGs are in `media/` (`healer-forever-logo-1000.png`, `-400`, `-64`, `-32`). Use the 1000 px version for the CurseForge avatar.

## Publishing rules (Blizzard UI Add-On Policy + CurseForge moderation)
- The addon must be free: no paid or premium features. The code must stay readable (never obfuscated). No advertising inside the addon.
- **No donation requests in game.** A Ko-fi or Patreon link is allowed only on the CurseForge or GitHub page, at the bottom after the description, never in the addon UI.
- The support email in Help & Contact is fine (it is contact, not solicitation).
- CurseForge: the avatar must be exactly 400x400 (`media/healer-forever-logo-400.png`); every file needs a changelog; never delete and re-upload after a rejection.
  The name rule is "no game name": "Healer Forever" may get questioned, so explain that it is the addon brand.

## Raid layout (2026-11-18, mockups `mockup/raid-style-d.html` and `mockup/raid-frames.html`)
- **Separate Raid layout with its own settings** (`raid`). The party layout and every setting saved by earlier versions stay exactly as they
  were after an update (hard rule: updates keep user settings).
- **Switching:** Auto (default) / Always party / Always raid, plus "raid layout only above 5 players" (default on). **Battlegrounds use the raid
  layout.** A raid of 5 or fewer that is split across subgroups uses the raid layout too. The switch only happens out of combat; in combat it
  waits and says so once in chat.
- **Style D, "Hurt stands out":** muted bars at full health, full colour when hurt; missing HP big, bold and red in the centre and never cut;
  the name small in the top-left and cut first; DEAD / GHOST / OFFLINE / CAN'T RES / "?" in the centre.
- **Groups:** Columns or Rows, with 8, 4×2 or 2×4 groups per line. Group labels G1-G8 on by default. A "What each corner means" legend sits in
  the options tab.
- **Name length cap:** "Name length" (3-12 characters, default 7) caps the name's width. Names can be secret, so the FontString width is set
  and the game cuts the text; the addon never shortens a name with string functions.
- **My buffs only:** a small spell icon top-right. Gold border = missing; **orange border + pulse = ending** (under the rebuff %, default 5).
  With several buffs the default is **one icon per state** (first missing with a count badge, plus first ending; max 2). Checked out of combat
  only; hidden in combat (option: keep last known, dimmed). **Raid buff markers are not clickable**: casting stays on click-casting, the
  smart buff key (which covers the raid while the raid layout is active) and the party buff buttons.
- **Debuffs: only types my class can dispel**, shown as "Glow + icons" (bar edge glow in the dispel colour + game-drawn icons bottom-right,
  max 3, shrink to fit). The glow needs checking in game; if the game refuses it, icons only.
- **Dropped from the mockup, and why:** the "Letters" debuff modes (M/C/D/P) and "All dispellable types". Both need the debuff type in our own
  code, but in combat that value is secret and aura reads are locked for addons, and the game's container filter only offers "dispellable by
  me" (`RAID_PLAYER_DISPELLABLE`). We can't build them without breaking the secret-value rules.
- **Preview full raid** (10/20/25/40): fake, non-secure frames at the raid position, not clickable, off in combat or when a real raid starts,
  never saved.
- **Shared lock:** the raid frame uses the same "Lock frames" toggle as the party frames. Default raid position TOPLEFT 60,-330 (tune in game).
- **Leaving a raid in combat (review fix, 2026-11-19):** in Auto mode the party frames come back at once through secure visibility drivers
  (`[group:raid]`) on both anchors; the party buttons keep their unit watch while the raid layout is active. Chosen over "no frames until
  combat ends" because it is the standard secure pattern (the game calls Show/Hide; no addon code in the protected path) and changes nothing
  when no raid exists (no driver is registered then). The full switch (layout, click-casting) still happens after combat; party click-casting
  stays armed all along. "Always raid" keeps the old behaviour (party unwatched). Joining a raid in combat still waits for combat end
  (group size can't be expressed as a macro condition).
- **Deficit "only when hurt" (review fix):** constant red text, shown/hidden through its alpha from a float Step curve; full health counts from
  99.5 % (`RS.FULL_AT`), so a full bar that reports 0.99999 still mutes and hides the number. Same threshold for the muted bar colour.
- **Bar glow (review fix):** a dedicated one-button glow container per bar, so the glow never depends on which icon button the game recycles,
  and glow-only mode simply doesn't run the icon container. Glow outset is at most half the bar spacing (no overlap with neighbours).

## Performance check (2026-11-18)
- `/hf perf` was added after a user said the game got slow with many addons and Questie's minimap circles vanished after enabling Healer
  Forever. Our error log only sees our own errors, so the command shows numbers: CPU/memory per addon (ours vs the others) and, with
  `/hf perf start`/`stop`, timings of our own hot paths. It's also in `/hf report` and `/hf copy`. Nothing is sent anywhere.
