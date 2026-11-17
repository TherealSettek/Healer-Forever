#!/usr/bin/env bash
# HealerForever test runner: luacheck (if installed) + Lua test suite.
# Usage: ./run-tests.sh [test-file-filter]      e.g. ./run-tests.sh units
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 2
export PATH="$HOME/.luarocks/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

LUA=""
for c in luajit lua5.1 lua-5.1 lua; do
  if command -v "$c" >/dev/null 2>&1; then LUA="$c"; break; fi
done
if [ -z "$LUA" ]; then
  echo "ERROR: no Lua interpreter found. Install with: brew install luajit" >&2
  exit 2
fi

LINT_STATUS="skipped"
LINT_RC=0
echo "=== luacheck ==="
if [ ! -d HealerForever ]; then
  echo "WARNING: HealerForever/ does not exist yet; skipping lint."
elif ! command -v luacheck >/dev/null 2>&1; then
  echo "WARNING: luacheck not installed (brew install luarocks && luarocks --lua-dir=\$(brew --prefix luajit) --lua-version 5.1 install luacheck); skipping lint."
elif [ ! -f .luacheckrc ]; then
  echo "WARNING: .luacheckrc not found in repo root; skipping lint."
else
  luacheck HealerForever --config .luacheckrc
  LINT_RC=$?
  if [ $LINT_RC -eq 0 ]; then LINT_STATUS="clean"; else LINT_STATUS="FAILED (exit $LINT_RC; 1=warnings, 2=errors)"; fi
fi
echo

echo "=== tests ($LUA) ==="
"$LUA" tests/run.lua "$@"
TEST_RC=$?

echo
echo "================ OVERALL ================"
echo "lint : $LINT_STATUS"
if [ $TEST_RC -eq 0 ]; then echo "tests: PASS"; else echo "tests: FAIL (exit $TEST_RC)"; fi
if [ $TEST_RC -ne 0 ] || [ $LINT_RC -ne 0 ]; then exit 1; fi
exit 0
