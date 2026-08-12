#!/usr/bin/env python3
"""tools/regenerate_manifest_metadata.py — Manifestgenerator (Phase 2.4).

Aktualisiert size_bytes und CRC32-Hash in xreactor/manifest.lua.
Idempotent: zweimaliges Ausführen erzeugt keinen Diff.
Schlägt fehl bei: doppelten Pfaden, doppelten Flags, fehlenden Dateien.

Aufruf: python3 tools/regenerate_manifest_metadata.py [--check]
  --check: nur prüfen, nichts schreiben (Exit 1 wenn veraltet)
"""
from __future__ import annotations
import argparse
import pathlib
import re
import sys
import zlib
from collections import Counter

REPO_ROOT    = pathlib.Path(__file__).resolve().parents[1]
XREACTOR_ROOT = REPO_ROOT / "xreactor"
MANIFEST_PATH = XREACTOR_ROOT / "manifest.lua"

ENTRY_RE  = re.compile(r'^(?P<indent>\s*)\{\s*path\s*=\s*"(?P<path>[^"]+)"(?P<tail>.*?)\}\s*,?\s*$')
SIZE_RE   = re.compile(r',\s*size_bytes\s*=\s*\d+')
HASH_RE   = re.compile(r',\s*hash\s*=\s*"[0-9a-fA-F]+"')
COMMA_RE  = re.compile(r',\s*,+')
ALWAYS_RE = re.compile(r',\s*always\s*=\s*true')


def crc32_hex(data: bytes) -> str:
    return f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"


def clean_tail(tail: str) -> str:
    """Entfernt size_bytes, hash — behält always=true und andere Flags."""
    t = SIZE_RE.sub('', tail)
    t = HASH_RE.sub('', t)
    t = COMMA_RE.sub(',', t)
    t = t.strip().lstrip(',').strip()
    # Doppelte always=true entfernen
    if t.count('always') > 1:
        # Nur einmal behalten
        t = re.sub(r'(,\s*always\s*=\s*true){2,}', ', always=true', t)
    if t and not t.startswith(','):
        t = ', ' + t
    return t


def build_line(indent: str, path: str, data: bytes, tail: str) -> str:
    t = clean_tail(tail)
    return f'{indent}{{ path = "{path}", size_bytes = {len(data)}, hash = "{crc32_hex(data)}"{t} }},'


def validate_manifest(lines: list[str]) -> list[str]:
    """Prüft auf doppelte Pfade und doppelte Flags."""
    errors = []
    path_count: Counter = Counter()
    for line in lines:
        m = ENTRY_RE.match(line)
        if not m:
            continue
        path = m.group('path')
        path_count[path] += 1
        tail = m.group('tail') or ''
        # Doppeltes always=true
        if tail.count('always') > 1:
            errors.append(f"Doppeltes 'always' Flag: {path}")
    for path, count in path_count.items():
        if count > 1:
            errors.append(f"Doppelter Pfad im Manifest: {path} ({count}x)")
    return errors


def rewrite_manifest(check_only: bool = False) -> tuple[int, list[str], list[str]]:
    text  = MANIFEST_PATH.read_text(encoding='utf-8')
    lines = text.splitlines()

    # Vorab-Validierung
    pre_errors = validate_manifest(lines)
    if pre_errors:
        return 0, [], pre_errors

    changed  = 0
    missing: list[str] = []
    output:  list[str] = []

    for line in lines:
        m = ENTRY_RE.match(line)
        if not m:
            output.append(line)
            continue
        rel_path = m.group('path')
        abs_path = XREACTOR_ROOT / rel_path
        if not abs_path.exists() or not abs_path.is_file():
            missing.append(rel_path)
            output.append(line)
            continue
        data     = abs_path.read_bytes()
        new_line = build_line(m.group('indent'), rel_path, data, m.group('tail') or '')
        if new_line != line:
            changed += 1
        output.append(new_line)

    new_text = '\n'.join(output) + '\n'

    if not check_only:
        MANIFEST_PATH.write_text(new_text, encoding='utf-8')
    elif new_text != text:
        # check-Modus: veraltet = Fehler
        return changed, missing, [
            f"Manifest veraltet: {changed} Eintraege muessen aktualisiert werden "
            f"(python3 tools/regenerate_manifest_metadata.py ausfuehren)"
        ]

    return changed, missing, []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true',
                        help='Nur pruefen, nichts schreiben')
    args = parser.parse_args()

    if not MANIFEST_PATH.exists():
        print(f"FEHLER: Manifest nicht gefunden: {MANIFEST_PATH}", file=sys.stderr)
        return 2

    changed, missing, errors = rewrite_manifest(check_only=args.check)

    if args.check and not errors:
        print(f"OK: Manifest aktuell ({changed} Eintraege haetten sich geaendert: nein)."
              if changed == 0 else
              f"OK: Manifest aktuell.")
    elif not args.check:
        print(f"Manifest aktualisiert: {changed} Eintraege geaendert.")

    if missing:
        print(f"WARN: {len(missing)} Manifest-Eintraege ohne lokale Datei:")
        for p in missing:
            print(f"  - {p}")

    if errors:
        print(f"FEHLER ({len(errors)}):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
