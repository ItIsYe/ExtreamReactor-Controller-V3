#!/usr/bin/env python3
from pathlib import Path
import re

main_src = Path('xreactor/master/main.lua').read_text(encoding='utf-8')
handlers_src = Path('xreactor/master/message_handlers.lua').read_text(encoding='utf-8')

errors = []

# message handler must wire coalescing hook as required contract
if 'local mark_rt_sync_dirty = assert(opts.mark_rt_sync_dirty, "mark_rt_sync_dirty required")' not in handlers_src:
    errors.append('message_handlers must require mark_rt_sync_dirty hook')

# no direct sync_rt_node(...) dispatch in handler event branches
if re.search(r'\bsync_rt_node\s*\(\s*nodes\[id\]\s*\)', handlers_src):
    errors.append('message_handlers contains direct sync_rt_node(nodes[id]) call')

for reason in ('hello', 'heartbeat', 'status', 'ack_applied'):
    token = f'mark_rt_sync_dirty(nodes[id], "{reason}")'
    if token not in handlers_src:
        errors.append(f'missing dirty-marker reason in handlers: {reason}')

# profile / global hold must mark dirty (coalesced), not direct sync
if 'mark_rt_sync_dirty(node, "profile_change")' not in main_src:
    errors.append('main.apply_profile must mark RT nodes dirty')
if 'mark_rt_sync_dirty(node, "global_hold_toggle")' not in main_src:
    errors.append('main.set_rt_global_hold must mark RT nodes dirty')
if 'flush_rt_sync_queue({ force = true })' not in main_src:
    errors.append('main control paths should force-flush coalesced RT sync queue after bulk marks')

profile_block = re.search(r'local function apply_profile\(name\)(.*?)\nend', main_src, re.S)
if profile_block and 'sync_rt_node(node)' in profile_block.group(1):
    errors.append('apply_profile must not call sync_rt_node(node) directly')

hold_block = re.search(r'local function set_rt_global_hold\(enabled\)(.*?)\nend', main_src, re.S)
if hold_block and 'sync_rt_node(node)' in hold_block.group(1):
    errors.append('set_rt_global_hold must not call sync_rt_node(node) directly')

if errors:
    print('master_rt_sync_callsite_coalescing_guard_test.py: FAIL')
    for err in errors:
        print(' -', err)
    raise SystemExit(1)

print('master_rt_sync_callsite_coalescing_guard_test.py: ok')
