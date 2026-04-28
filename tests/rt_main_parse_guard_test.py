#!/usr/bin/env python3
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

guard = subprocess.run(
    [
        "python3",
        str(CC_PARSE_GUARD),
        "--file",
        str(RT_MAIN),
        "--chunk-limit",
        "165",
        "--function-limit",
        "170",
        "--require-real-parse",
    ],
    capture_output=True,
    text=True,
)
if guard.returncode != 0:
    output = (guard.stdout + "\n" + guard.stderr).strip()
    fail(f"cc_parse_guard failed for {RT_MAIN}: {output}")

# Verify the real parser path catches the exact local-variable hard limit.
synthetic = Path("/tmp/rt_locals_limit_repro.lua")
synthetic.write_text("local " + ", ".join(f"v{i}" for i in range(1, 206)) + "\nreturn true\n", encoding="utf-8")
probe = subprocess.run(
    [
        "python3",
        str(CC_PARSE_GUARD),
        "--file",
        str(synthetic),
        "--chunk-limit",
        "999",
        "--function-limit",
        "999",
        "--require-real-parse",
    ],
    capture_output=True,
    text=True,
)
if probe.returncode == 0:
    fail("synthetic >200-locals chunk unexpectedly parsed; real parser guard not effective")
probe_output = (probe.stdout + "\n" + probe.stderr).lower()
if "limit is 200" not in probe_output and "more than 200 local variables" not in probe_output and "too many local variables" not in probe_output:
    fail("synthetic >200-locals repro did not report Lua hard-limit error")

print("rt_main_parse_guard_test.py: ok")
