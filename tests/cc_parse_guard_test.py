#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
subprocess.run([
    sys.executable,
    str(repo / 'scripts' / 'cc_parse_guard.py'),
    '--file',
    'xreactor/nodes/rt/main.lua',
], cwd=repo, check=True)
print('cc_parse_guard_test.py: ok')
