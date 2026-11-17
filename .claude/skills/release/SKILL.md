---
name: release
description: Cut a HealerForever release (version, changelog, full tests, local zip, manual CurseForge upload, git tag). Use when the owner asks to release, ship, publish or tag a version.
---

# Releasing HealerForever

There is **no GitHub release workflow**. The owner is on the free plan and chose manual releases. Uploads go to CurseForge by hand.

1. **Confirm the version** with the owner. Numbering: patch for fixes (0.9.1), minor for features (0.10.0), 1.0.0 when stable.
2. **Changelog:** add `## <version>` at the top of `CHANGELOG.md`. List the user-facing changes, and settings changes such as moved or removed options.
3. **Settings schema:** if saved data changed shape, check that `ns.migrations` has a step, `DEFAULTS.version` was bumped, and there's an old-format
   fixture test (see `.claude/docs/settings.md`).
4. **Full local test run, with the mutation tests:** `./run-tests.sh` must be green with lint clean. CI skips the mutation tests, so this run is the only time they're checked.
5. **Build the zip:** `./scripts/release.sh <version>`. This produces `dist/HealerForever-v<version>.zip`. Check that it has `HealerForever/` at its root,
   the TOC says `## Version: <version>`, and it contains no tests, mockup, `.settings-backup`, dotfiles or `.DS_Store`. Optionally install it and smoke-test in WoW.
6. **CurseForge, done by the owner by hand.** In the author console, upload the zip as a new file:
   - Game version: **WoW Forever (1.60.1)**. The TOC's `## Interface: 16001` matches it.
   - Release type: Beta for 0.x, Release for 1.0+.
   - Changelog: paste the section from `CHANGELOG.md`.
   Claude must not log in or upload for the owner, because that involves credentials and publishing.
7. **Git** (only with the owner's OK): commit on a branch, merge to `main`, push, then `git tag v<version> && git push origin v<version>`.
   Commit messages end with the session's attribution lines.

Never include `.settings-backup/` or `dist/` in commits. Never use `HF_RELEASE_SKIP_TESTS=1` for a real release.

Possible later step: automated CurseForge uploads via BigWigsMods/packager in GitHub Actions with a `CF_API_KEY` secret and `## X-Curse-Project-ID`
in the TOC. Only add this if the owner asks, because it uses Actions minutes.
