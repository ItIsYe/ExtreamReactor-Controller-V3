#!/usr/bin/env python3
import re
from pathlib import Path

path = Path('xreactor/nodes/rt/main.lua')
text = path.read_text(encoding='utf-8')

# Defensive guard against the LuaJ 200-local compile limit in one chunk/function.
# We keep a margin below that hard cap because generated/inline locals can vary.
max_declared_locals = 160
count = 0
for match in re.finditer(r'(?m)^local\s+([^=\n]+)=', text):
    names = [part.strip() for part in match.group(1).split(',') if part.strip()]
    count += len(names)

if count > max_declared_locals:
    raise SystemExit(f'rt main local declaration budget exceeded: {count} > {max_declared_locals}')

print('rt_locals_budget_guard_test.py: ok')
