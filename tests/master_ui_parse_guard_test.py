#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
files = [
    'xreactor/master/ui/multiview.lua',
    'xreactor/master/ui/overview.lua',
    'xreactor/master/ui/rt_dashboard.lua',
    'xreactor/master/ui/energy.lua',
    'xreactor/master/ui_controller.lua',
]

cmd = [
    sys.executable,
    str(repo / 'scripts' / 'cc_parse_guard.py'),
    '--require-real-parse',
]
for file_path in files:
    cmd.extend(['--file', file_path])

subprocess.run(cmd, cwd=repo, check=True)
print('master_ui_parse_guard_test.py: ok')
