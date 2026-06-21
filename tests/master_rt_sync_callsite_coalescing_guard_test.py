#!/usr/bin/env python3
from pathlib import Path
import re

# apply_profile and set_rt_global_hold are implemented in runtime_ops_profile.lua
# (called via runtime_loop.lua -> profile_ops.apply_profile / profile_ops.set_rt_global_hold)
profile_ops_src = Path('xreactor/master/runtime_ops_profile.lua').read_text(encoding='utf-8')
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
if 'mark_rt_sync_dirty(node, "profile_change")' not in profile_ops_src:
    errors.append('apply_profile must mark RT nodes dirty')
if 'mark_rt_sync_dirty(node, "global_hold_toggle")' not in profile_ops_src:
    errors.append('set_rt_global_hold must mark RT nodes dirty')
if 'flush_rt_sync_queue({ force = true })' not in profile_ops_src:
    errors.append('profile control paths should force-flush coalesced RT sync queue after bulk marks')

profile_block = re.search(r'function M\.apply_profile\(runtime, name\)(.*?)\nend', profile_ops_src, re.S)
if profile_block and 'sync_rt_node(node)' in profile_block.group(1):
    errors.append('apply_profile must not call sync_rt_node(node) directly')

hold_block = re.search(r'function M\.set_rt_global_hold\(runtime, enabled\)(.*?)\nend', profile_ops_src, re.S)
if hold_block and 'sync_rt_node(node)' in hold_block.group(1):
    errors.append('set_rt_global_hold must not call sync_rt_node(node) directly')

if errors:
    print('master_rt_sync_callsite_coalescing_guard_test.py: FAIL')
    for err in errors:
        print(f' - {err}')
    raise SystemExit(1)

print('master_rt_sync_callsite_coalescing_guard_test.py: ok')
