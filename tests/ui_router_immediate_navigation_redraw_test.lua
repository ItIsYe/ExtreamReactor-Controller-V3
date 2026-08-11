package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.ui_router'] = nil
package.loaded['core.ui'] = {
  begin_frame = function() end,
  getSize = function(mon) return mon.getSize() end,
  rightText = function() end,
  clear = function() end,
  text = function() end,
  invalidate = function() end,
}
package.loaded['shared.colors'] = { get = function() return 1 end }
_G.textutils = { serialize = function(value) return tostring(value.page) end }

local ui_router = require('core.ui_router')
local visibility = {}
local mon = {
  getSize = function() return 51, 18 end,
  getTextScale = function() return 0.5 end,
  setVisible = function(value) visibility[#visibility + 1] = value end,
  redraw = function() end,
}

local rendered = {}
local function page(name)
  return {
    name = name,
    render = function()
      rendered[#rendered + 1] = name
      return {
        left = { x1 = 1, x2 = 17, y = 18 },
        right = { x1 = 35, x2 = 51, y = 18 },
      }
    end,
  }
end

local router = ui_router.new({ pages = { page('A'), page('B'), page('C') } })
local model = { snapshot = 'stable', marker = 'cached-model' }
router:render(mon, model)
assert(rendered[#rendered] == 'A', 'initial page must render')

local handled, result = router:handle_input({ 'monitor_touch', 'monitor_0', 51, 18 })
assert(handled == true and result == 'page_navigation_redrawn',
  'navigation must report a completed immediate redraw')
assert(router.index == 2 and rendered[#rendered] == 'B',
  'new page must be visible before the input handler returns')
assert(router.last_render_model == model, 'immediate redraw must reuse the last committed model')
assert(visibility[#visibility - 1] == false and visibility[#visibility] == true,
  'window target must be hidden and republished around the immediate redraw')

handled, result = router:handle_input({ 'monitor_touch', 'monitor_0', 1, 18 })
assert(handled == true and result == 'page_navigation_redrawn')
assert(router.index == 1 and rendered[#rendered] == 'A',
  'immediate direction changes must redraw synchronously')

_G.textutils = nil
print('ui_router_immediate_navigation_redraw_test.lua: ok')
