#!/usr/bin/env bash
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.9.0
# Runs the tests, then builds dist/HealerForever-v<version>.zip with the HealerForever folder at the zip root.
set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 <semver, e.g. 0.9.0>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== running tests =="
if [ "${HF_RELEASE_SKIP_TESTS:-}" = "1" ]; then
  echo "WARNING: HF_RELEASE_SKIP_TESTS=1 set: tests skipped (packaging check only, never for a real release)" >&2
else
  ./run-tests.sh || { echo "tests failed: aborting release" >&2; exit 1; }
fi

DIST="$ROOT/dist"
STAGE="$DIST/HealerForever"
ZIP="$DIST/HealerForever-v$VERSION.zip"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$DIST"
cp -R HealerForever "$STAGE"
find "$STAGE" -name '.DS_Store' -delete
find "$STAGE" -mindepth 1 -name '.*' -exec rm -rf {} + 2>/dev/null || true

# stamp the version into the copied TOC only
sed "s/@project-version@/$VERSION/g" "$STAGE/HealerForever.toc" > "$STAGE/HealerForever.toc.tmp"
mv "$STAGE/HealerForever.toc.tmp" "$STAGE/HealerForever.toc"
grep -q "^## Version: $VERSION\$" "$STAGE/HealerForever.toc" || { echo "version stamp failed" >&2; exit 1; }

(cd "$DIST" && zip -r -X -q "HealerForever-v$VERSION.zip" HealerForever -x '*.DS_Store' '*/.*')

echo "== $ZIP =="
unzip -l "$ZIP"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$ZIP"; else shasum -a 256 "$ZIP"; fi
