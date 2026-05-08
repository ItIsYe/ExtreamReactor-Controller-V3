#!/usr/bin/env python3
"""Block local/release drift: modified manifest-covered files require manifest update."""

import pathlib
import re
import subprocess
import sys
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "xreactor" / "manifest.lua"
ENTRY_RE = re.compile(r'\{\s*path\s*=\s*"(?P<path>[^"]+)"\s*,\s*size_bytes\s*=\s*(?P<size>\d+)\s*,\s*hash\s*=\s*"(?P<hash>[0-9a-fA-F]+)"')


def git(args: list[str]) -> str:
    proc = subprocess.run(["git", *args], cwd=REPO_ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit((proc.stdout + "\n" + proc.stderr).strip())
    return proc.stdout


manifest_text = MANIFEST_PATH.read_text(encoding="utf-8")
manifest_entries = {m.group("path"):(int(m.group("size")), m.group("hash").lower()) for m in ENTRY_RE.finditer(manifest_text)}
manifest_paths = {f"xreactor/{rel}" for rel in manifest_entries}
if "xreactor/master/main.lua" not in manifest_paths:
    raise SystemExit("manifest_changed_files_guard_test.py: FAIL\nmanifest missing xreactor/master/main.lua")

changed = set()
status_lines = git(["status", "--porcelain"]).splitlines()
for line in status_lines:
    if not line:
        continue
    path = line[3:]
    if " -> " in path:
        path = path.split(" -> ", 1)[1]
    changed.add(path)

changed_manifested = sorted(path for path in changed if path in manifest_paths and path != "xreactor/manifest.lua")
manifest_changed = "xreactor/manifest.lua" in changed


if changed_manifested:
    stale = []
    for repo_path in changed_manifested:
        rel = repo_path.removeprefix("xreactor/")
        expected_size, expected_hash = manifest_entries[rel]
        data = (REPO_ROOT / repo_path).read_bytes()
        actual_size = len(data)
        actual_hash = f"{zlib.crc32(data) & 0xffffffff:08x}"
        if expected_size != actual_size or expected_hash != actual_hash:
            stale.append((repo_path, expected_size, actual_size, expected_hash, actual_hash))
    if stale:
        print("manifest_changed_files_guard_test.py: FAIL")
        print("manifest metadata stale for changed manifest-covered files:")
        for repo_path, expected_size, actual_size, expected_hash, actual_hash in stale:
            print(f" - {repo_path}: size expected={expected_size} actual={actual_size}; hash expected={expected_hash} actual={actual_hash}")
        sys.exit(1)

if changed_manifested and not manifest_changed:
    print("manifest_changed_files_guard_test.py: FAIL")
    print("manifest-covered files changed without manifest update:")
    for path in changed_manifested:
        print(f" - {path}")
    sys.exit(1)

print("manifest_changed_files_guard_test.py: ok")
