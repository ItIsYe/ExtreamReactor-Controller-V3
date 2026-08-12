#!/usr/bin/env python3
"""Block local/release drift: modified manifest-covered files require manifest update.

Phase 2.1 (CI_IMPLEMENTATION_BACKLOG): von git status --porcelain auf
echten Commit-Vergleich umgestellt.

Verwendung:
  python3 tests/manifest_changed_files_guard_test.py              # lokal: gegen Merge-Base
  python3 tests/manifest_changed_files_guard_test.py --base A --head B  # CI: explizit
"""
import argparse
import pathlib
import re
import subprocess
import sys
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "xreactor" / "manifest.lua"
ENTRY_RE = re.compile(
    r'\{\s*path\s*=\s*"(?P<path>[^"]+)"\s*,\s*size_bytes\s*=\s*(?P<size>\d+)\s*,\s*hash\s*=\s*"(?P<hash>[0-9a-fA-F]+)"'
)


def git(args: list, check=True) -> str:
    proc = subprocess.run(["git", *args], cwd=REPO_ROOT, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise SystemExit((proc.stdout + "\n" + proc.stderr).strip())
    return proc.stdout


def resolve_base_head(base_arg, head_arg):
    """Base und Head-SHA ermitteln."""
    if head_arg:
        head = head_arg.strip()
    else:
        head = git(["rev-parse", "HEAD"]).strip()

    if base_arg:
        base = base_arg.strip()
    else:
        # Merge-Base gegen origin/beta oder origin/main ermitteln
        for ref in ("origin/beta", "origin/main", "HEAD~1"):
            result = git(["merge-base", ref, head], check=False).strip()
            if result:
                base = result
                break
        else:
            print("WARN: Kein Basis-Commit ermittelbar — Pruefung uebersprungen.", file=sys.stderr)
            sys.exit(0)

    return base, head


def changed_files(base: str, head: str) -> set:
    """Geaenderte Dateien zwischen base und head."""
    out = git(["diff", "--name-only", base, head])
    return {line.strip() for line in out.splitlines() if line.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Basis-Commit-SHA")
    parser.add_argument("--head", help="Head-Commit-SHA")
    args = parser.parse_args()

    manifest_text = MANIFEST_PATH.read_text(encoding="utf-8")
    manifest_entries = {
        m.group("path"): (int(m.group("size")), m.group("hash").lower())
        for m in ENTRY_RE.finditer(manifest_text)
    }
    manifest_paths = {f"xreactor/{rel}" for rel in manifest_entries}

    if "xreactor/master/main.lua" not in manifest_paths:
        raise SystemExit(
            "manifest_changed_files_guard_test.py: FAIL\n"
            "manifest missing xreactor/master/main.lua"
        )

    base, head = resolve_base_head(args.base, args.head)
    print(f"Vergleiche: {base[:12]}..{head[:12]}")

    changed = changed_files(base, head)
    changed_manifested = sorted(
        path for path in changed
        if path in manifest_paths and path != "xreactor/manifest.lua"
    )
    manifest_changed = "xreactor/manifest.lua" in changed

    if changed_manifested:
        stale = []
        for repo_path in changed_manifested:
            rel = repo_path.removeprefix("xreactor/")
            expected_size, expected_hash = manifest_entries[rel]
            disk_path = REPO_ROOT / repo_path
            if not disk_path.exists():
                stale.append(f"{repo_path}: Datei geloescht aber noch im Manifest")
                continue
            data = disk_path.read_bytes()
            actual_size = len(data)
            actual_hash = f"{zlib.crc32(data) & 0xffffffff:08x}"
            if expected_size != actual_size or expected_hash != actual_hash:
                stale.append(
                    f"{repo_path}: "
                    f"manifest={expected_size}b/{expected_hash} "
                    f"aktuell={actual_size}b/{actual_hash}"
                )

        if stale and not manifest_changed:
            print("FAIL: manifest_changed_files_guard_test.py")
            print("Geaenderte manifestierte Dateien ohne Manifest-Update:")
            for s in stale:
                print(f"  {s}")
            sys.exit(1)
        elif stale and manifest_changed:
            # Manifest wurde geaendert — pruefen ob Eintrag korrekt aktualisiert
            still_stale = []
            updated_manifest = MANIFEST_PATH.read_text(encoding="utf-8")
            updated_entries = {
                m.group("path"): (int(m.group("size")), m.group("hash").lower())
                for m in ENTRY_RE.finditer(updated_manifest)
            }
            for repo_path in changed_manifested:
                rel = repo_path.removeprefix("xreactor/")
                disk_path = REPO_ROOT / repo_path
                if not disk_path.exists():
                    continue
                data = disk_path.read_bytes()
                actual_size = len(data)
                actual_hash = f"{zlib.crc32(data) & 0xffffffff:08x}"
                upd = updated_entries.get(rel)
                if upd and (upd[0] != actual_size or upd[1] != actual_hash):
                    still_stale.append(f"{repo_path}: Manifest-Eintrag noch nicht aktuell")
            if still_stale:
                print("FAIL: manifest_changed_files_guard_test.py")
                for s in still_stale:
                    print(f"  {s}")
                sys.exit(1)
            else:
                print(f"OK: {len(stale)} geaenderte Dateien im Manifest korrekt aktualisiert.")
        else:
            print(f"OK: {len(changed_manifested)} manifestierte Dateien — alle Hashes aktuell.")
    else:
        print(f"OK: keine manifestierten Dateien geaendert ({len(changed)} Dateien gesamt).")


if __name__ == "__main__":
    main()
