#!/usr/bin/env python3
import subprocess

proc = subprocess.run(
    ["python3", "scripts/manifest_sync.py"],
    capture_output=True,
    text=True,
)

if proc.returncode != 0:
    output = (proc.stdout + "\n" + proc.stderr).strip()
    raise SystemExit(f"manifest_hash_size_guard_test.py failed:\n{output}")

print("manifest_hash_size_guard_test.py: ok")
