package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.ui_router'] = nil
package.loaded['core.ui'] = {
  begin_frame = function() end,
  getSize = function(mon) return mon.getSize() end,
  rightText = function() end,
  clear = function() end,
  text = function() end,
}
package.loaded['shared.colors'] = { get = function() return 1 end }

local ui_router = require('core.ui_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

do
  local router = ui_router.new({
    pages = { { name = 'A' }, { name = 'B' }, { name = 'C' } },
    key_next = { [1] = true },
    key_prev = { [2] = true },
  })

  assert_eq(router:handle_input({ 'key', 1, false }), true)
  assert_eq(router.index, 2, 'an initial key event must navigate immediately')

  assert_eq(router:handle_input({ 'key', 1, true }), true)
  assert_eq(router.index, 2, 'CC:Tweaked key-repeat events must not navigate again')

  assert_eq(router:handle_input({ 'key', 1, false }), true)
  assert_eq(router.index, 3, 'a distinct key press must not be delayed by a timer debounce')
end

do
  local router = ui_router.new({ pages = { { name = 'A' }, { name = 'B' }, { name = 'C' } } })
  router:set_monitor_name('monitor_0')
  router.footer.next = { x1 = 10, x2 = 15, y = 20 }

  assert_eq(router:handle_input({ 'monitor_touch', 'monitor_0', 12, 20 }), true)
  assert_eq(router.index, 2, 'first monitor touch must navigate')

  router.footer.next = { x1 = 10, x2 = 15, y = 20 }
  assert_eq(router:handle_input({ 'monitor_touch', 'monitor_0', 12, 20 }), true)
  assert_eq(router.index, 3, 'a second distinct monitor touch must navigate without a global delay')

  router.footer.next = { x1 = 10, x2 = 15, y = 20 }
  assert_eq(router:handle_input({ 'monitor_touch', 'monitor_1', 12, 20 }), true)
  assert_eq(router.index, 3, 'touches from another physical monitor must not control this router')
  assert_eq(router:get_diagnostics().ignored_monitor_events, 1)
end

print('ui_router_page_nav_debounce_test.lua: ok')
