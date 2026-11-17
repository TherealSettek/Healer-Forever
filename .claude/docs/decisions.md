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
