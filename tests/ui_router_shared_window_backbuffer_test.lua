package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local created = 0
local visible_calls = {}
local redraws = 0
local last_window
local expected_target

package.loaded['shared.colors'] = { get = function() return 1 end }
package.loaded['core.ui'] = {
  invalidate = function() end,
  begin_frame = function() end,
  getSize = function(mon) return mon.getSize() end,
  clear = function(mon) assert(mon == last_window, 'clear must target hidden Window, not physical monitor') end,
  text = function() end,
  rightText = function(mon) assert(mon == expected_target, 'footer must render into the active render target') end,
}
package.loaded['core.ui_router'] = nil
_G.window = {
  create = function(parent, x, y, w, h, visible)
    created = created + 1
    assert(visible == false, 'shared backbuffer must be created hidden')
    local win = {
      getSize = function() return w, h end,
      getTextScale = function() return 1 end,
      setVisible = function(value) visible_calls[#visible_calls + 1] = value end,
      redraw = function() redraws = redraws + 1 end,
    }
    last_window = win
    expected_target = win
    return win
  end,
}

local router = require('core.ui_router')
local physical = {
  getSize = function() return 30, 12 end,
  getTextScale = function() return 1 end,
}
local renders = 0
local r = router.new({ pages = { { name = 'A', render = function(mon, model, should_clear)
  renders = renders + 1
  assert(mon == last_window, 'page must render into shared hidden Window')
  if should_clear then package.loaded['core.ui'].clear(mon) end
end } } })

r:render(physical, { snapshot = 'one' })
assert(created == 1 and renders == 1, 'first frame must create one reusable Window')
assert(visible_calls[1] == false and visible_calls[2] == true, 'frame must hide then publish Window')
assert(redraws == 1, 'published Window should redraw once')

r:render(physical, { snapshot = 'two' })
assert(created == 1 and renders == 2, 'normal update must reuse existing Window')
assert(visible_calls[3] == false and visible_calls[4] == true, 'reused Window must still hide/publish atomically')
assert(redraws == 2, 'second committed frame should publish once')

-- Existing Window target (FUEL) must not be double-buffered or have its
-- visibility lifecycle touched by the shared router.
local external_visibility = 0
local external = {
  getSize = function() return 30, 12 end,
  getTextScale = function() return 1 end,
  setVisible = function() external_visibility = external_visibility + 1 end,
}
local r2 = router.new({ pages = { { name = 'B', render = function(mon) assert(mon == external) end } } })
expected_target = external
r2:render(external, { snapshot = 'fuel-window' })
assert(created == 1, 'existing Window must not be wrapped again')
assert(external_visibility == 0, 'shared router must not own visibility of an existing Window target')
print('ui_router_shared_window_backbuffer_test.lua: ok')
