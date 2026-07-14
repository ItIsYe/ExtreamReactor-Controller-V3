#!/usr/bin/env bash
# tools/run_lua_tests.sh
#
# TEST-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md):
# fuehrt jede tests/*.lua-Datei einzeln aus (eigener lua-Prozess pro Datei,
# damit sich Tests nicht gegenseitig ueber globalen State beeinflussen),
# mit tests/cc_env_shim.lua vorab geladen (os.epoch/colors/package.path,
# da Host-Lua kein CC:Tweaked ist). Tests aus tests/known_failing_lua_tests.txt
# werden explizit uebersprungen (mit Begruendung dort) -- alles andere MUSS
# gruen sein, sonst schlaegt dieses Skript fehl.
#
# Usage: tools/run_lua_tests.sh [lua-interpreter]
# Default-Interpreter: lua5.2 (identisch zur GitHub-Actions-Umgebung).

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

LUA_BIN="${1:-lua5.2}"
if ! command -v "$LUA_BIN" >/dev/null 2>&1; then
  echo "FEHLER: Lua-Interpreter '$LUA_BIN' nicht gefunden." >&2
  exit 1
fi

EXCLUDE_FILE="tests/known_failing_lua_tests.txt"
declare -A EXCLUDED
if [ -f "$EXCLUDE_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -n "$line" ] && EXCLUDED["tests/$line"]=1
  done < "$EXCLUDE_FILE"
fi

pass=0
fail=0
skipped=0
failed_files=()

for test_file in tests/*.lua; do
  [ "$test_file" = "tests/cc_env_shim.lua" ] && continue
  if [ -n "${EXCLUDED[$test_file]+x}" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  if REPO_ROOT="$REPO_ROOT" "$LUA_BIN" -e "dofile('tests/cc_env_shim.lua')" "$test_file" > /tmp/run_lua_tests_out.$$ 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_files+=("$test_file")
    echo "FAIL: $test_file"
    sed 's/^/    /' /tmp/run_lua_tests_out.$$
  fi
  rm -f /tmp/run_lua_tests_out.$$
done

echo ""
echo "Lua-Tests: $pass bestanden, $fail fehlgeschlagen, $skipped explizit ausgeschlossen (siehe $EXCLUDE_FILE)."

if [ "$fail" -gt 0 ]; then
  echo ""
  echo "Fehlgeschlagene, NICHT ausgeschlossene Tests:"
  for f in "${failed_files[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

exit 0
