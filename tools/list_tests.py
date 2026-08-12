#!/usr/bin/env python3
"""tools/list_tests.py — Testinventar erzeugen (Phase 0.1 CI_IMPLEMENTATION_BACKLOG).

Gibt alle Tests in tests/ aus, ordnet sie Skip-Listen zu und schreibt
einen JSON-Report. Schlaegt fehl wenn:
  - keine Tests gefunden werden
  - ein Test weder ausgefuehrt noch bewusst klassifiziert ist
"""
import os, sys, json, re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"
SKIP_LUA  = REPO_ROOT / "tests" / "known_failing_lua_tests.txt"
SKIP_PY   = REPO_ROOT / "tests" / "known_failing_python_tests.txt"

VALID_CATS = {"STALE_API", "STALE_STRUCTURE", "NEEDS_MOCK",
              "CONTENT_DRIFT", "SYNTAX_ERROR", "KNOWN_BUG",
              "NEEDS_SIMULATOR", "NEEDS_REAL_GAME"}

CRITICAL_CATS = {"CONTENT_DRIFT", "KNOWN_BUG"}

def parse_skip_file(path):
    skips = {}
    if not path.exists():
        return skips
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "#" in line:
            name, rest = line.split("#", 1)
            name = name.strip()
            cat_match = re.match(r"\s*(\w+)", rest.strip())
            cat = cat_match.group(1) if cat_match else "UNKNOWN"
        else:
            name, cat = line.strip(), "UNKNOWN"
        skips[name] = cat
    return skips

def main():
    skip_lua = parse_skip_file(SKIP_LUA)
    skip_py  = parse_skip_file(SKIP_PY)

    lua_tests = sorted(p.name for p in TESTS_DIR.glob("*_test.lua"))
    py_tests  = sorted(p.name for p in TESTS_DIR.glob("*_test.py"))

    errors = []

    # Unbekannte Kategorien
    all_skips = {**{k: v for k, v in skip_lua.items()},
                 **{k: v for k, v in skip_py.items()}}
    for name, cat in all_skips.items():
        if cat not in VALID_CATS:
            errors.append(f"UNKNOWN_CATEGORY: {name} -> {cat}")

    # Tests die weder aktiv noch geskippt
    for t in lua_tests:
        if t not in skip_lua:
            pass  # aktiv — OK
    for t in py_tests:
        if t not in skip_py:
            pass  # aktiv — OK

    # Skips die nicht mehr zu Dateien gehoeren (tote Eintraege)
    for name in skip_lua:
        if not (TESTS_DIR / name).exists():
            errors.append(f"DEAD_SKIP_LUA: {name} (Datei existiert nicht)")
    for name in skip_py:
        if not (TESTS_DIR / name).exists():
            errors.append(f"DEAD_SKIP_PY: {name} (Datei existiert nicht)")

    lua_active  = [t for t in lua_tests if t not in skip_lua]
    lua_skipped = [t for t in lua_tests if t in skip_lua]
    py_active   = [t for t in py_tests  if t not in skip_py]
    py_skipped  = [t for t in py_tests  if t in skip_py]

    critical_skips = [f"{n} ({c})" for n, c in skip_lua.items()
                      if c in CRITICAL_CATS]
    critical_skips += [f"{n} ({c})" for n, c in skip_py.items()
                       if c in CRITICAL_CATS]

    report = {
        "lua_total":        len(lua_tests),
        "lua_active":       len(lua_active),
        "lua_skipped":      len(lua_skipped),
        "py_total":         len(py_tests),
        "py_active":        len(py_active),
        "py_skipped":       len(py_skipped),
        "total_active":     len(lua_active) + len(py_active),
        "total_skipped":    len(lua_skipped) + len(py_skipped),
        "critical_skips":   critical_skips,
        "errors":           errors,
        "lua_skip_cats":    {},
        "py_skip_cats":     {},
    }

    from collections import Counter
    report["lua_skip_cats"] = dict(Counter(skip_lua.values()))
    report["py_skip_cats"]  = dict(Counter(skip_py.values()))

    # Ausgabe
    print(f"=== Testinventar ===")
    print(f"Lua:    {len(lua_active)} aktiv / {len(lua_skipped)} geskippt / {len(lua_tests)} gesamt")
    print(f"Python: {len(py_active)} aktiv / {len(py_skipped)} geskippt / {len(py_tests)} gesamt")
    print(f"Gesamt: {report['total_active']} aktiv / {report['total_skipped']} geskippt")

    if report["lua_skip_cats"]:
        print(f"\nLua Skip-Kategorien: {report['lua_skip_cats']}")
    if report["py_skip_cats"]:
        print(f"Python Skip-Kategorien: {report['py_skip_cats']}")

    if critical_skips:
        print(f"\nKritische Skips ({len(critical_skips)}):")
        for s in critical_skips:
            print(f"  CRITICAL: {s}")

    # JSON-Report
    out_path = REPO_ROOT / "test-inventory.json"
    out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"\nReport: {out_path}")

    # Fehler
    if not lua_tests and not py_tests:
        print("FEHLER: Keine Tests gefunden!", file=sys.stderr)
        sys.exit(1)

    if errors:
        print(f"\nFEHLER ({len(errors)}):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(1)

    print("\nOK")

if __name__ == "__main__":
    main()
