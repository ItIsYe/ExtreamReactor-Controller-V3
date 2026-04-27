#!/usr/bin/env python3
import shutil
import subprocess
from pathlib import Path

RT_MAIN = Path("xreactor/nodes/rt/main.lua")
CC_PARSE_GUARD = Path("scripts/cc_parse_guard.py")


def fail(msg: str) -> None:
    raise SystemExit(msg)


if not RT_MAIN.exists():
    fail(f"missing file: {RT_MAIN}")
if not CC_PARSE_GUARD.exists():
    fail(f"missing guard script: {CC_PARSE_GUARD}")

luac = shutil.which("luac") or shutil.which("luac5.1") or shutil.which("luac5.2") or shutil.which("luac5.3")
if luac:
    proc = subprocess.run([luac, "-p", str(RT_MAIN)], capture_output=True, text=True)
    if proc.returncode != 0:
        output = (proc.stderr or proc.stdout or "").strip()
        fail(f"luac parse failed for {RT_MAIN}: {output}")
else:
    text = RT_MAIN.read_text(encoding="utf-8")
    if "local function apply_turbine_flow(" not in text:
        fail("apply_turbine_flow not found in rt main")

guard = subprocess.run(
    [
        "python3",
        str(CC_PARSE_GUARD),
        "--file",
        str(RT_MAIN),
        "--chunk-limit",
        "170",
        "--function-limit",
        "170",
    ],
    capture_output=True,
    text=True,
)
if guard.returncode != 0:
    output = (guard.stdout + "\n" + guard.stderr).strip()
    fail(f"cc_parse_guard failed for {RT_MAIN}: {output}")

print("rt_main_parse_guard_test.py: ok")
