#!/usr/bin/env python3
"""Struktur-Waechter fuer nodes/rt/main.lua.

main.lua ist die Orchestrierungsschicht der RT-Node: Boot, Services,
Event-Loop. Sie darf nicht wieder zur Fachlogik-Halde werden, und sie darf
vor allem keinen zweiten Regler mehr beherbergen -- mit v769 ist v1
vollstaendig entfernt, die Regelung liegt hinter genau einem Aufruf
(rt2_engine.tick).
"""
import re
from pathlib import Path

p = Path('xreactor/nodes/rt/main.lua')
text = p.read_text(encoding='utf-8')
lines = text.splitlines()
line_count = len(lines)

# Nach dem v1-Ausbau ist main.lua deutlich kleiner. Die Grenze wandert mit,
# damit ein Rueckfall in die alte Groesse auffaellt statt durchzurutschen.
if line_count > 1200:
    raise SystemExit(f'rt main too large: {line_count} > 1200')
if '_G.turbine_ctrl =' in text:
    raise SystemExit('rt main must not mutate _G.turbine_ctrl directly')

starts = []
for i, line in enumerate(lines, 1):
    if re.match(r'^local function ', line) or re.match(r'^function ', line):
        starts.append((i, line))
starts.append((line_count + 1, '<EOF>'))
for (i, name), (j, _) in zip(starts, starts[1:]):
    if j - i > 250:
        raise SystemExit(f'rt main oversized function {name.strip()}: {j - i} > 250')

# Kein v1-Modul darf wieder geladen werden.
forbidden_requires = [
    'nodes.rt.module_lifecycle', 'nodes.rt.state_handlers',
    'nodes.rt.command_handler', 'nodes.rt.capacity_learning',
    'nodes.rt.capacity_cache', 'nodes.rt.startup_diagnostics',
    'nodes.rt.flow_apply_helpers', 'nodes.rt.reactor_steam_guard',
    'core.turbine_regulator', 'core.control_rails',
]
for mod in forbidden_requires:
    if mod in text:
        raise SystemExit(f'rt main references removed v1 module: {mod}')

# Und die Regelung bleibt ein einziger Aufruf hinter der Quiesce-Sperre.
cs = text.index('local function control_tick()')
ce = text.index('-- ── Command-Handler', cs)
block = text[cs:ce]
for t in ['if rt_update_quiescing then', 'rt2_engine.tick(ctx)']:
    if t not in block:
        raise SystemExit(f'control_tick missing delegation {t}')
for t in ['node_state_machine', 'module_lifecycle']:
    if t in block:
        raise SystemExit(f'control_tick regained a v1 path: {t}')

print('rt_main_structure_guard_test.py: ok')
