#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[1]

PARSE_FILES = [
    'xreactor/nodes/rt/main.lua',
    'xreactor/master/ui/multiview.lua',
    'xreactor/master/ui/overview.lua',
    'xreactor/master/ui/rt_dashboard.lua',
    'xreactor/master/ui/energy.lua',
    'xreactor/master/ui_controller.lua',
    'xreactor/master/main.lua',
    'xreactor/master/init_runtime.lua',
    'xreactor/master/runtime_loop.lua',
    'xreactor/master/message_handlers.lua',
    'xreactor/nodes/energy/main.lua',
]

cmd = [
    sys.executable,
    str(repo / 'scripts' / 'cc_parse_guard.py'),
    '--chunk-limit',
    '160',
    '--function-limit',
    '120',
    '--require-real-parse',
    '--upvalue-estimate-limit',
    '80',
]
for file_path in PARSE_FILES:
    cmd.extend(['--file', file_path])
subprocess.run(cmd, cwd=repo, check=True)

print('cc_parse_guard_test.py: ok')
