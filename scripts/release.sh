#!/usr/bin/env bash
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.9.0
# Builds dist/HealerForever-v<version>.zip with the HealerForever folder at the zip root.
# It does NOT run the tests (owner decision 2026-11-19): use scripts/release-tests.sh <version> to run the full
# suite first and then build, or run the test suite yourself right before this script.
set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 <semver, e.g. 0.9.0>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== building HealerForever $VERSION (tests are not run here; scripts/release-tests.sh runs them first) =="

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
