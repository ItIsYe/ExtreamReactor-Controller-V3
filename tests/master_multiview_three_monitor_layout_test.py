from pathlib import Path

multiview_text = Path('xreactor/master/ui/multiview.lua').read_text(encoding='utf-8')
sessions_text = Path('xreactor/master/monitor_sessions.lua').read_text(encoding='utf-8')

errors = []

# PRIMARY_ROLE_MAP lives in monitor_sessions
if 'PRIMARY_ROLE_MAP = { "overview", "rt", "energy" }' not in sessions_text:
    errors.append('monitor_sessions missing PRIMARY_ROLE_MAP declaration')

# Primary sessions are the first 3
if 'math.min(3,' not in sessions_text:
    errors.append('monitor_sessions missing 3-monitor primary cap')

# locked flag must be preserved across rebinds
if 'prior.locked == true' not in sessions_text:
    errors.append('monitor_sessions must preserve prior.locked on rebind')

# aux cycle: aux monitors cycle through view_order
if 'view_order' not in sessions_text:
    errors.append('monitor_sessions missing view_order for aux cycling')

# multiview delegates session management
if 'sessions_lib' not in multiview_text:
    errors.append('multiview must use sessions_lib for session management')

# multiview must not accept locked sessions for view cycling
if 'is_primary' not in multiview_text and 'is_primary' not in sessions_text:
    errors.append('missing is_primary guard for locked session cycling')

if errors:
    print('master_multiview_three_monitor_layout_test.py: FAIL')
    for err in errors:
        print(f' - {err}')
    raise SystemExit(1)

print('master_multiview_three_monitor_layout_test.py: ok')
