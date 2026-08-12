#!/usr/bin/env python3
import re
from pathlib import Path
p=Path('xreactor/nodes/rt/main.lua'); text=p.read_text(encoding='utf-8'); lines=text.splitlines(); line_count=len(lines)
if line_count>2400: raise SystemExit(f'rt main too large: {line_count} > 2400')
if '_G.turbine_ctrl =' in text: raise SystemExit('rt main must not mutate _G.turbine_ctrl directly')
starts=[]
for i,line in enumerate(lines,1):
    if re.match(r'^local function ',line) or re.match(r'^function ',line): starts.append((i,line))
starts.append((line_count+1,'<EOF>'))
for (i,name),(j,_) in zip(starts,starts[1:]):
    if j-i>250: raise SystemExit(f'rt main oversized function {name.strip()}: {j-i} > 250')
for helper in ['local function configure_lifecycle_context()','local function configure_state_machine()','configure_lifecycle_context()','configure_state_machine()']:
    if helper not in text: raise SystemExit(f'rt init structural delegation missing: {helper}')
cs=text.index('local function control_tick()'); ce=text.index('-- ── Command-Handler',cs); block=text[cs:ce]
for t in ['module_lifecycle.update_module_states','module_lifecycle.process_startup','reactor_control.updateReactorControl','turbine_control.updateControl','writeback_ctx()']:
    if t not in block: raise SystemExit(f'control_tick missing delegation {t}')
print('rt_main_structure_guard_test.py: ok')
