#!/usr/bin/env python3
"""Regenerate size_bytes and CRC32 hash metadata in xreactor/manifest.lua.

Run from the repository root:

    python3 tools/regenerate_manifest_metadata.py

The script updates every single-line manifest entry whose target file exists under
xreactor/. It preserves extra flags such as always=true and required_for={...}.
"""

from __future__ import annotations

import pathlib
import re
import sys
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
XREACTOR_ROOT = REPO_ROOT / "xreactor"
MANIFEST_PATH = XREACTOR_ROOT / "manifest.lua"
ENTRY_RE = re.compile(r'^(?P<indent>\s*)\{\s*path\s*=\s*"(?P<path>[^"]+)"(?P<tail>.*?)\}\s*,?\s*$')
SIZE_RE = re.compile(r',\s*size_bytes\s*=\s*\d+')
HASH_RE = re.compile(r',\s*hash\s*=\s*"[0-9a-fA-F]+"')
COMMA_RE = re.compile(r',\s*,+')


def crc32_hex(data: bytes) -> str:
    return f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"


def clean_tail(tail: str) -> str:
    cleaned = SIZE_RE.sub('', tail)
    cleaned = HASH_RE.sub('', cleaned)
    cleaned = COMMA_RE.sub(',', cleaned)
    cleaned = cleaned.strip()
    if cleaned == ',':
        return ''
    if cleaned and not cleaned.startswith(','):
        cleaned = ', ' + cleaned
    if cleaned.startswith(',') and not cleaned.startswith(', '):
        cleaned = ', ' + cleaned[1:].lstrip()
    return cleaned


def rewrite_manifest() -> tuple[int, list[str]]:
    lines = MANIFEST_PATH.read_text(encoding='utf-8').splitlines()
    changed = 0
    missing: list[str] = []
    output: list[str] = []

    for line in lines:
        match = ENTRY_RE.match(line)
        if not match:
            output.append(line)
            continue

        rel_path = match.group('path')
        abs_path = XREACTOR_ROOT / rel_path
        if not abs_path.exists() or not abs_path.is_file():
            missing.append(rel_path)
            output.append(line)
            continue

        data = abs_path.read_bytes()
        tail = clean_tail(match.group('tail') or '')
        new_line = (
            f'{match.group("indent")}{{ path = "{rel_path}", '
            f'size_bytes = {len(data)}, hash = "{crc32_hex(data)}"{tail} }},'
        )
        if new_line != line:
            changed += 1
        output.append(new_line)

    MANIFEST_PATH.write_text('\n'.join(output) + '\n', encoding='utf-8')
    return changed, missing


def main() -> int:
    if not MANIFEST_PATH.exists():
        print(f"manifest not found: {MANIFEST_PATH}", file=sys.stderr)
        return 2
    changed, missing = rewrite_manifest()
    print(f"updated manifest metadata entries: {changed}")
    if missing:
        print("manifest entries without local files:")
        for path in missing:
            print(f" - {path}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
