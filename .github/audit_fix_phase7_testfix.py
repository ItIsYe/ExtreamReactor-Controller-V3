from pathlib import Path
p = Path('tests/ui_router_shared_window_backbuffer_test.lua')
s = p.read_text(encoding='utf-8')
repls = [
    ("local last_window\n", "local last_window\nlocal expected_target\n"),
    ("  rightText = function(mon) assert(mon == last_window, 'footer must render into the Window') end,\n", "  rightText = function(mon) assert(mon == expected_target, 'footer must render into the active render target') end,\n"),
    ("    last_window = win\n    return win\n", "    last_window = win\n    expected_target = win\n    return win\n"),
    ("local r2 = router.new({ pages = { { name = 'B', render = function(mon) assert(mon == external) end } } })\nr2:render(external, { snapshot = 'fuel-window' })\n", "local r2 = router.new({ pages = { { name = 'B', render = function(mon) assert(mon == external) end } } })\nexpected_target = external\nr2:render(external, { snapshot = 'fuel-window' })\n"),
]
for old, new in repls:
    if s.count(old) != 1:
        raise SystemExit('phase7 fixture anchor drift: ' + repr(old))
    s = s.replace(old, new, 1)
p.write_text(s, encoding='utf-8')
print('phase7 test fixture corrected')
