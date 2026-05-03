#!/usr/bin/env python3
"""Block local/release drift: modified manifest-covered files require manifest update."""

import pathlib
import re
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "xreactor" / "manifest.lua"
ENTRY_RE = re.compile(r'\{\s*path\s*=\s*"([^"]+)"\s*,\s*size_bytes\s*=\s*\d+\s*,\s*hash\s*=\s*"[0-9a-fA-F]+"')


def git(args: list[str]) -> str:
    proc = subprocess.run(["git", *args], cwd=REPO_ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit((proc.stdout + "\n" + proc.stderr).strip())
    return proc.stdout


manifest_text = MANIFEST_PATH.read_text(encoding="utf-8")
manifest_paths = {f"xreactor/{rel}" for rel in ENTRY_RE.findall(manifest_text)}
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

if changed_manifested and not manifest_changed:
    print("manifest_changed_files_guard_test.py: FAIL")
    print("manifest-covered files changed without manifest update:")
    for path in changed_manifested:
        print(f" - {path}")
    sys.exit(1)

print("manifest_changed_files_guard_test.py: ok")
