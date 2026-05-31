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

if '_G.turbine_ctrl =' in text:
    raise SystemExit('rt main must not mutate _G.turbine_ctrl directly; use core.turbine_ctrl helper path')

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

lines = text.splitlines()
apply_start = None
for i, line in enumerate(lines, start=1):
    if line.startswith('local function apply_turbine_flow('):
        apply_start = i
        break

if apply_start is None:
    raise SystemExit('apply_turbine_flow not found in rt main')

next_function_start = line_count + 1
for i, line in enumerate(lines[apply_start:], start=apply_start + 1):
    if line.startswith('local function ') or line.startswith('function '):
        next_function_start = i
        break

apply_span = next_function_start - apply_start
if apply_span > 180:
    raise SystemExit(f'apply_turbine_flow too large: {apply_span} lines > 180')

apply_block = '\n'.join(lines[apply_start - 1:next_function_start - 1])
required_delegations = [
    'sample_turbine_runtime_metrics(',
    'capture_turbine_flow_readback(',
    'update_turbine_flow_tracking(',
    'log_turbine_control_metrics('
]
for marker in required_delegations:
    if marker not in apply_block:
        raise SystemExit(f'apply_turbine_flow missing structural delegation: {marker}')

print('rt_main_structure_guard_test.py: ok')
