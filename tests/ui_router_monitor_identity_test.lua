package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local ui_router = require('core.ui_router')
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local r = ui_router.new({
  monitor_name = 'monitor_main',
  pages = { { name = 'A' }, { name = 'B' } },
})
r.footer.next = { x1 = 10, x2 = 12, y = 5 }
r.footer.prev = { x1 = 1, x2 = 3, y = 5 }

local consumed = r:handle_input({ 'monitor_touch', 'monitor_status', 11, 5 })
assert_true(consumed == true, 'foreign monitor touch must be consumed so page handlers cannot receive it')
assert_true(r.index == 1, 'foreign monitor touch must not navigate the main UI')
assert_true(r:get_diagnostics().foreign_monitor_touches == 1,
  'diagnostics must count rejected foreign monitor touches')

consumed = r:handle_input({ 'monitor_touch', 'monitor_main', 11, 5 })
assert_true(consumed == true, 'main monitor touch should be handled')
assert_true(r.index == 2, 'main monitor touch should navigate normally')

print('ui_router_monitor_identity_test.lua: ok')
