---
name: triage-ingame-error
description: Handle a Lua error, "addon blocked" popup or misbehaviour the owner reports from the real WoW Forever client — classify it, hotfix, harden the mock so tests catch it, and audit for the same pattern.
---

# Triage an in-game error

1. **Get the facts:** the pasted error (message, file:line, stack, label such as `PLAYER_LOGIN` or `OnHide`), whether it was in combat, and what the owner did.
   If nothing was pasted, read `errorLog` from the owner's SavedVariables (read only; see `.claude/docs/in-game-testing.md`). Ask for
   `/hf errors`, `/hf debug auras`, `/hf debug buffs` or `/hf debug click` as fits.
2. **Classify** it against `.claude/docs/wow-api-rules.md`:
   - "attempt to perform boolean test / compare / arithmetic on … (a secret …)": a secret-value misuse.
   - "Cannot call restricted closure from insecure code": a secure handler got wrapped (NewFrame/SetScript override).
   - "blocked from an action only available to the Blizzard UI": taint or a protected call in combat.
   - A spell landing on the player: a `type=spell` or non-strict macro.
   - A click doing nothing or doing it twice: click registration, overlapping frames, or a modifier/attribute problem.
3. **Hotfix** the exact line if it's small and obvious, so the owner is unblocked fast. Run luacheck. Then tell the owner to `/reload`.
4. **Harden:**
   - Have the `wow-addon-builder` agent audit the whole addon for the same pattern.
   - Have the `wow-addon-tester` agent make the mock reproduce the real behaviour, so the bug would have failed a test, and add a regression test.
5. Record any new rule in `.claude/docs/wow-api-rules.md`.
