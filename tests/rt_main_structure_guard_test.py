#!/usr/bin/env python3
import re
from pathlib import Path

path = Path('xreactor/nodes/rt/main.lua')
text = path.read_text(encoding='utf-8')

# Guard against file bloat and monster functions in orchestrator file.
max_lines = 2400
line_count = text.count('\n') + 1
if line_count > max_lines:
    raise SystemExit(f'rt main too large: {line_count} lines > {max_lines}')

fn_starts = []
for i, line in enumerate(text.splitlines(), start=1):
    if re.match(r'^local function ', line) or re.match(r'^function ', line):
        fn_starts.append(i)

fn_starts.append(line_count + 1)
max_fn_lines = 0
for idx in range(len(fn_starts) - 1):
    span = fn_starts[idx + 1] - fn_starts[idx]
    if span > max_fn_lines:
        max_fn_lines = span

if max_fn_lines > 250:
    raise SystemExit(f'rt main has oversized function scope: {max_fn_lines} lines > 250')

print('rt_main_structure_guard_test.py: ok')
