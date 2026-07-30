#!/usr/bin/env bash
# tools/run_python_tests.sh
#
# TEST-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md):
# fuehrt jede tests/*.py-Datei einzeln aus. Tests aus
# tests/known_failing_python_tests.txt werden explizit uebersprungen (mit
# Begruendung dort) -- alles andere MUSS gruen sein, sonst schlaegt dieses
# Skript fehl.
#
# Usage: tools/run_python_tests.sh [python-interpreter]

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

PY_BIN="${1:-python3}"
if ! command -v "$PY_BIN" >/dev/null 2>&1; then
  echo "FEHLER: Python-Interpreter '$PY_BIN' nicht gefunden." >&2
  exit 1
fi

EXCLUDE_FILE="tests/known_failing_python_tests.txt"
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

for test_file in tests/*.py; do
  if [ -n "${EXCLUDED[$test_file]+x}" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  if "$PY_BIN" "$test_file" > /tmp/run_python_tests_out.$$ 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_files+=("$test_file")
    echo "FAIL: $test_file"
    sed 's/^/    /' /tmp/run_python_tests_out.$$
  fi
  rm -f /tmp/run_python_tests_out.$$
done

echo ""
echo "Python-Tests: $pass bestanden, $fail fehlgeschlagen, $skipped explizit ausgeschlossen (siehe $EXCLUDE_FILE)."

if [ "$fail" -gt 0 ]; then
  echo ""
  echo "Fehlgeschlagene, NICHT ausgeschlossene Tests:"
  for f in "${failed_files[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

exit 0
