#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[1]

cmd = [
    sys.executable,
    str(repo / 'scripts' / 'cc_parse_guard.py'),
    '--file',
    'xreactor/master/main.lua',
    '--chunk-limit',
    '160',
    '--function-limit',
    '120',
    '--upvalue-estimate-limit',
    '55',
    '--require-real-parse',
    '--parser-mode',
    'any',
]
subprocess.run(cmd, cwd=repo, check=True)

print('master_main_upvalue_guard_test.py: ok')
