#!/usr/bin/env python3
import subprocess
from pathlib import Path

RT_MAIN = Path("xreactor/nodes/rt/main.lua")
CC_PARSE_GUARD = Path("scripts/cc_parse_guard.py")

if not RT_MAIN.exists():
    raise SystemExit(f"missing file: {RT_MAIN}")
if not CC_PARSE_GUARD.exists():
    raise SystemExit(f"missing guard script: {CC_PARSE_GUARD}")

# LuaJ rejects chunks/functions with >200 locals.
# Enforce a conservative chunk budget to catch regressions before installer runs.
proc = subprocess.run(
    [
        "python3",
        str(CC_PARSE_GUARD),
        "--file",
        str(RT_MAIN),
        "--chunk-limit",
        "145",
        "--function-limit",
        "170",
    ],
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    output = (proc.stdout + "\n" + proc.stderr).strip()
    raise SystemExit(f"rt_locals_budget_guard_test.py failed:\n{output}")

print("rt_locals_budget_guard_test.py: ok")
