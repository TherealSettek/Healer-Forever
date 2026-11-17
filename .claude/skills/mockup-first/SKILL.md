---
name: mockup-first
description: For any visual HealerForever change (bars, auras, range, minimap, options look), build an HTML mockup with options, show it in Chrome, get the owner's pick, then implement with tests.
---

# Mockup first

1. Have the `mockup-designer` agent build `mockup/<topic>.html` with 3–4 options side by side, a live options panel, all relevant states
   (hover, target, out of range, not visible, dead, low HP), and captions on WoW API limits. Start from the approved look in
   `.claude/docs/decisions.md`.
2. Make sure the local server is running: `cd mockup && python3 -m http.server 8765`.
3. Open the page in Chrome, take a screenshot and check alignment yourself. Fix obvious layout bugs, such as misaligned bars or overlapping timers, before showing it.
4. Show the owner the URL plus a short table of the options and any API caveats. Ask which one they want, or a mix.
5. Record the choice in `.claude/docs/decisions.md`.
6. Implement with the `wow-addon-builder` agent. Each mockup control becomes a saved option (see the `add-setting` skill). Then test with the
   `wow-addon-tester` agent.
