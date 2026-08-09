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
_G.textutils = {
  serialize = function(payload)
    local fuel = payload.snapshot and payload.snapshot.fuel or ''
    return tostring(payload.page) .. ':' .. tostring(fuel)
  end,
}

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
local visibility_calls = 0
local mon = {
  getSize = function() return 30, 10 end,
  getTextScale = function() return 0.5 end,
  -- Physical CC:Tweaked monitors do not provide this method. The sentinel
  -- exists only to prove the shared router no longer contains the obsolete
  -- monitor-setVisible buffering hack.
  setVisible = function() visibility_calls = visibility_calls + 1 end,
}

router:render(mon, { snapshot = { fuel = 40 } })
local initial = router:get_diagnostics()
assert(initial.full_clears == 1 and initial.transition_count == 1)

for _ = 1, 10 do
  router:render(mon, { snapshot = { fuel = 40 } })
end
local stable = router:get_diagnostics()
assert(stable.full_clears == 1, '10 unchanged cycles must not increment full_clears')
assert(stable.transition_count == 1, '10 unchanged cycles must not create monitor transitions')
assert(stable.frames_skipped >= 10, 'unchanged cycles must be skipped by snapshot comparison')

router:render(mon, { snapshot = { fuel = 39 } })
local changed = router:get_diagnostics()
assert(#clears == 2, 'Fuel 40 -> 39 must commit exactly one additional frame')
assert(clears[1] == true, 'first render must be a transition/full-clear frame')
assert(clears[2] == false, 'normal Fuel data update must not request a full clear')
assert(changed.full_clears == 1, 'normal model update must not increment full_clears')
assert(changed.transition_count == 1, 'normal model update must not create a monitor transition')
assert(visibility_calls == 0, 'shared ui_router must never call setVisible on the render target')

_G.textutils = nil
print('ui_router_normal_update_no_full_clear_test.lua: ok')
