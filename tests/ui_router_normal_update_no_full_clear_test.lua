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
local clears = {}
local page = {
  name = 'Fuel',
  render = function(mon, model, should_clear)
    clears[#clears + 1] = should_clear == true
    return { left = { x1 = 1, x2 = 3, y = 10 }, right = { x1 = 20, x2 = 22, y = 10 } }
  end,
}
local router = ui_router.new({ pages = { page } })
local mon = {
  getSize = function() return 30, 10 end,
  getTextScale = function() return 0.5 end,
}

router:render(mon, { snapshot = { fuel = 50 } })
router:render(mon, { snapshot = { fuel = 49 } })

assert(#clears == 2, 'changed Fuel model must commit a second frame')
assert(clears[1] == true, 'first render must be a transition/full-clear frame')
assert(clears[2] == false, 'normal Fuel data update must not request a full clear')
local diag = router:get_diagnostics()
assert(diag.full_clears == 1, 'normal model update must not increment full_clears')
assert(diag.transition_count == 1, 'normal model update must not create a monitor transition')

print('ui_router_normal_update_no_full_clear_test.lua: ok')
