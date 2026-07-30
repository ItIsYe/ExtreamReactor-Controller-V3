#!/usr/bin/env python3
"""tools/validate_skip_lists.py — Skip-Listen validieren (Phase 0.2).

Prueft:
  - alle Eintraege haben bekannte Kategorie
  - keine toten Eintraege (Datei existiert nicht)
  - keine unbekannten/leeren Kategorien
  - Skip-Budget (Gesamtzahl darf nicht steigen ohne explizite Freigabe)
"""
import os, sys, re
from pathlib import Path
from collections import Counter

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"
SKIP_LUA  = TESTS_DIR / "known_failing_lua_tests.txt"
SKIP_PY   = TESTS_DIR / "known_failing_python_tests.txt"
BUDGET    = REPO_ROOT / "tests" / "skip_budget.txt"

VALID_CATS = {"STALE_API", "STALE_STRUCTURE", "NEEDS_MOCK",
              "CONTENT_DRIFT", "SYNTAX_ERROR", "KNOWN_BUG",
              "NEEDS_SIMULATOR", "NEEDS_REAL_GAME"}

RELEASE_BLOCKING_CATS = {"CONTENT_DRIFT", "KNOWN_BUG"}

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
            m = re.match(r"\s*(\w+)", rest.strip())
            cat = m.group(1) if m else "UNKNOWN"
        else:
            name, cat = line.strip(), "UNKNOWN"
        skips[name] = cat
    return skips

def main():
    skip_lua = parse_skip_file(SKIP_LUA)
    skip_py  = parse_skip_file(SKIP_PY)
    all_skips = dict(skip_lua)
    all_skips.update(skip_py)

    errors = []
    warnings = []

    # Unbekannte Kategorien
    for name, cat in all_skips.items():
        if cat not in VALID_CATS:
            errors.append(f"UNBEKANNTE_KATEGORIE: {name} -> '{cat}' (erlaubt: {sorted(VALID_CATS)})")

    # Tote Eintraege
    for name in skip_lua:
        if not (TESTS_DIR / name).exists():
            errors.append(f"TOTER_EINTRAG_LUA: {name}")
    for name in skip_py:
        if not (TESTS_DIR / name).exists():
            errors.append(f"TOTER_EINTRAG_PY: {name}")

    # Release-blockierende Skips
    blocking = {n: c for n, c in all_skips.items() if c in RELEASE_BLOCKING_CATS}
    if blocking:
        warnings.append(f"{len(blocking)} release-blockierende Skips ({RELEASE_BLOCKING_CATS}):")
        for n, c in sorted(blocking.items()):
            warnings.append(f"  RELEASE_BLOCKING: {n} ({c})")

    # Budget-Prüfung
    total = len(all_skips)
    if BUDGET.exists():
        try:
            budget = int(BUDGET.read_text().strip())
            if total > budget:
                errors.append(
                    f"SKIP_BUDGET_UEBERSCHRITTEN: {total} > {budget} "
                    f"(+{total-budget} neue Skips ohne Freigabe)"
                )
            else:
                print(f"Skip-Budget: {total}/{budget} OK")
        except ValueError:
            warnings.append("skip_budget.txt nicht lesbar")
    else:
        # Budget erstmalig anlegen
        BUDGET.write_text(str(total), encoding="utf-8")
        print(f"Skip-Budget angelegt: {total}")

    # Ausgabe
    total_lu = len(skip_lua)
    total_py = len(skip_py)
    print(f"Lua-Skips: {total_lu}  Python-Skips: {total_py}  Gesamt: {total}")
    cats = Counter(all_skips.values())
    print(f"Kategorien: {dict(sorted(cats.items()))}")

    for w in warnings:
        print(f"WARN: {w}")

    if errors:
        print(f"\nFEHLER ({len(errors)}):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(1)

    print("OK")

if __name__ == "__main__":
    main()
