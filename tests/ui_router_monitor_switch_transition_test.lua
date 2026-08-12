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
    return tostring(payload.page) .. ':' .. tostring(payload.model and payload.model.value or '')
  end,
}

local ui_router = require('core.ui_router')
local renders = {}
local function page(name)
  return {
    name = name,
    render = function(mon, model, should_clear)
      renders[#renders + 1] = { mon = mon, should_clear = should_clear == true, page = name }
      local w, h = mon.getSize()
      return {
        left = { x1 = 1, x2 = 4, y = h },
        right = { x1 = w - 3, x2 = w, y = h },
      }
    end,
  }
end

local router = ui_router.new({ pages = { page('A'), page('B') } })
local mon1 = { getSize = function() return 30, 10 end, getTextScale = function() return 0.5 end }
local mon2 = { getSize = function() return 30, 10 end, getTextScale = function() return 0.5 end }
local model = { value = 'same' }

router:render(mon1, model)
local d1 = router:get_diagnostics()
assert(d1.transition_count == 1 and d1.full_clears == 1, 'boot must create one transition/full clear')
assert(renders[#renders].should_clear == true)

router:render(mon1, model)
local d2 = router:get_diagnostics()
assert(d2.transition_count == 1 and d2.full_clears == 1, 'unchanged stable monitor must not create another transition')

router:render(mon2, model)
local d3 = router:get_diagnostics()
assert(d3.transition_count == 2, 'physical monitor replacement must increment transition_count exactly once')
assert(d3.full_clears == 2, 'physical monitor replacement must request exactly one new full frame')
assert(renders[#renders].mon == mon2 and renders[#renders].should_clear == true, 'new monitor must receive a complete transition frame')

local next_btn = router.footer.next
assert(next_btn and next_btn.y == 10, 'new monitor must own freshly rendered footer touch zones')
assert(router:handle_input({ 'monitor_touch', 'monitor_1', next_btn.x1, next_btn.y }) == true)
assert(router.index == 2, 'fresh next-page touch zone must work after monitor replacement')

_G.textutils = nil
print('ui_router_monitor_switch_transition_test.lua: ok')
