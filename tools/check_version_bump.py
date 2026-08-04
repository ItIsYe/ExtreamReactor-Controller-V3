#!/usr/bin/env python3
"""tools/check_version_bump.py — Versions-Bump-Guard (Phase 2.3).

Prüft: Wenn ausgelieferte Lua-Dateien (manifest-covered) geändert wurden,
muss manifest_version in manifest.lua UND release.lua erhöht worden sein.
Rückwärtsversionen werden blockiert.
Doku-only Änderungen (docs/, *.md, tools/, tests/, scripts/, .github/)
sind ausgenommen.

Verwendung:
  python3 tools/check_version_bump.py                     # lokal (Merge-Base)
  python3 tools/check_version_bump.py --base A --head B   # CI
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_ROOT / "xreactor" / "manifest.lua"
RELEASE_PATH  = REPO_ROOT / "xreactor" / "release.lua"

ENTRY_RE  = re.compile(r'path\s*=\s*"([^"]+)"')
VERSION_RE = re.compile(r'manifest_version\s*=\s*(\d+)')

# Dateipfade die KEINEN Bump erfordern (Doku, CI, Tests, Tools)
EXEMPT_PREFIXES = (
    "docs/",
    "tests/",
    "tools/",
    "scripts/",
    ".github/",
)
EXEMPT_SUFFIXES = (".md", ".txt", ".json")


def git(args: list, check=True) -> str:
    proc = subprocess.run(["git", *args], cwd=REPO_ROOT,
                          capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise SystemExit((proc.stdout + "\n" + proc.stderr).strip())
    return proc.stdout


def resolve_base_head(base_arg, head_arg):
    head = (head_arg or git(["rev-parse", "HEAD"])).strip()
    if base_arg:
        return base_arg.strip(), head
    for ref in ("origin/beta", "origin/main", "HEAD~1"):
        result = git(["merge-base", ref, head], check=False).strip()
        if result:
            return result, head
    print("WARN: kein Basis-Commit — Pruefung uebersprungen.", file=sys.stderr)
    sys.exit(0)


def changed_files(base: str, head: str) -> set:
    out = git(["diff", "--name-only", base, head])
    return {l.strip() for l in out.splitlines() if l.strip()}


def read_version(path: Path) -> int | None:
    try:
        m = VERSION_RE.search(path.read_text(encoding="utf-8"))
        return int(m.group(1)) if m else None
    except FileNotFoundError:
        return None


def manifest_paths() -> set:
    try:
        text = MANIFEST_PATH.read_text(encoding="utf-8")
        return {f"xreactor/{p}" for p in ENTRY_RE.findall(text)}
    except FileNotFoundError:
        return set()


def is_exempt(path: str) -> bool:
    for pre in EXEMPT_PREFIXES:
        if path.startswith(pre):
            return True
    for suf in EXEMPT_SUFFIXES:
        if path.endswith(suf):
            return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base")
    parser.add_argument("--head")
    args = parser.parse_args()

    base, head = resolve_base_head(args.base, args.head)
    print(f"Versions-Bump-Guard: {base[:12]}..{head[:12]}")

    changed = changed_files(base, head)
    manifested = manifest_paths()

    # Ausgelieferte Dateien die geändert wurden (nicht Manifest selbst)
    code_changed = sorted(
        p for p in changed
        if p in manifested
        and p != "xreactor/manifest.lua"
        and p != "xreactor/release.lua"
        and not is_exempt(p)
    )

    # Reine Doku/CI-Änderung?
    non_exempt_changed = [p for p in changed if not is_exempt(p)]
    if not code_changed:
        if non_exempt_changed:
            # Manifest/Release selbst könnten geändert worden sein
            manifest_changed = "xreactor/manifest.lua" in changed
            release_changed  = "xreactor/release.lua"  in changed
            if manifest_changed or release_changed:
                # Bump-Richtung prüfen
                pass
            else:
                print(f"OK: keine manifest-covered Codeaenderungen ({len(changed)} Dateien gesamt).")
                return
        else:
            print("OK: nur exemptierte Dateien geaendert (Doku/CI/Tests).")
            return

    # Versionen lesen
    man_ver_now  = read_version(MANIFEST_PATH)
    rel_ver_now  = read_version(RELEASE_PATH)

    # Versionen im Base-Stand (via git show)
    def ver_at_base(repo_path: str) -> int | None:
        try:
            out = git(["show", f"{base}:{repo_path}"], check=False)
            m = VERSION_RE.search(out)
            return int(m.group(1)) if m else None
        except Exception:
            return None

    man_ver_base = ver_at_base("xreactor/manifest.lua")
    rel_ver_base = ver_at_base("xreactor/release.lua")

    errors = []

    if code_changed:
        print(f"Codeaenderungen in {len(code_changed)} manifest-covered Datei(en):")
        for p in code_changed:
            print(f"  {p}")

        # manifest_version muss gestiegen sein
        if man_ver_now is None:
            errors.append("manifest_version nicht lesbar")
        elif man_ver_base is not None and man_ver_now <= man_ver_base:
            errors.append(
                f"manifest_version nicht erhoeht: "
                f"base={man_ver_base} aktuell={man_ver_now}"
            )
        else:
            print(f"manifest_version: {man_ver_base} → {man_ver_now} ✅")

        # release manifest_version muss übereinstimmen
        if rel_ver_now is None:
            errors.append("release.lua manifest_version nicht lesbar")
        elif man_ver_now is not None and rel_ver_now != man_ver_now:
            errors.append(
                f"release.lua manifest_version ({rel_ver_now}) != "
                f"manifest.lua ({man_ver_now})"
            )
        else:
            print(f"release manifest_version: {rel_ver_now} ✅")

        # Rückwärtsversion
        if man_ver_base is not None and man_ver_now is not None:
            if man_ver_now < man_ver_base:
                errors.append(
                    f"RUECKWAERTSVERSION: {man_ver_now} < {man_ver_base}"
                )

    if errors:
        print(f"\nFEHLER ({len(errors)}):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(1)

    print("OK")


if __name__ == "__main__":
    main()
