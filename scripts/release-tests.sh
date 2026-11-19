#!/usr/bin/env bash
# Usage: scripts/release-tests.sh <version>   e.g. scripts/release-tests.sh 0.11.0
# Runs the full test suite (lint + tests + mutation tests), then builds the zip with scripts/release.sh.
# Nothing is built when a test fails.
set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 <semver, e.g. 0.9.0>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== running tests =="
./run-tests.sh || { echo "tests failed: aborting release" >&2; exit 1; }

exec "$ROOT/scripts/release.sh" "$VERSION"
