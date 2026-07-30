#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[1]

PARSE_FILES = [
    'xreactor/master/ui/multiview.lua',
    'xreactor/master/ui/overview.lua',
    'xreactor/master/ui/rt_dashboard.lua',
    'xreactor/master/ui/energy.lua',
    'xreactor/master/ui_controller.lua',
    'xreactor/master/main.lua',
    'xreactor/master/message_handlers.lua',
    'xreactor/installer/manifest.lua',
]

cmd = [
    sys.executable,
    str(repo / 'scripts' / 'cc_parse_guard.py'),
    '--chunk-limit',
    '160',
    '--function-limit',
    '120',
    '--require-real-parse',
]
for file_path in PARSE_FILES:
    cmd.extend(['--file', file_path])
subprocess.run(cmd, cwd=repo, check=True)

artifact_patterns = [
    'diff --git',
    '@@',
    '--- a/',
    '+++ b/',
    '*** Begin Patch',
    '*** End Patch',
]
for lua_file in sorted((repo / 'xreactor').rglob('*.lua')):
    content = lua_file.read_text(encoding='utf-8', errors='ignore')
    for marker in artifact_patterns:
        if marker in content:
            rel = lua_file.relative_to(repo)
            raise AssertionError(f"Patch marker '{marker}' found in shipped Lua file: {rel}")

print('master_shipped_lua_parse_guard_test.py: ok')
