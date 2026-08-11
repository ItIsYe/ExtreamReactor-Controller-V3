package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Full FUEL monitor regression: physical monitor -> window backbuffer ->
-- monitor_ui -> real ui_router -> page footer -> input routing. It covers
-- rapid forward/backward navigation and a same-size text-scale rebuild.
package.loaded['nodes.fuel.monitor_ui'] = nil
package.loaded['core.ui_router'] = nil
package.loaded['optional.ampel'] = {}
package.loaded['nodes.fuel.router_ui_responsive'] = { attach = function(value) return value end }
package.loaded['nodes.fuel.ui_completion'] = { attach = function(value) return value end }
package.loaded['core.ui'] = {
  begin_frame = function() end,
  getSize = function(mon) return mon.getSize() end,
  rightText = function() end,
  clear = function() end,
  text = function() end,
  invalidate = function() end,
}
package.loaded['shared.colors'] = { get = function() return 1 end }

local mux = require('core.mockup_ui')
local ui_router = require('core.ui_router')
local monitor_ui = require('nodes.fuel.monitor_ui')

local width, height, scale = 51, 18, 0.5
local physical = {
  getSize = function() return width, height end,
  getTextScale = function() return scale end,
}

local created = {}
_G.window = {
  create = function(parent, x, y, w, h, visible)
    assert(parent == physical and x == 1 and y == 1 and visible == false)
    local target = {
      id = #created + 1,
      width = w,
      height = h,
      visible = visible,
      writes = 0,
      getSize = function() return w, h end,
      setCursorPos = function() end,
      setBackgroundColor = function() end,
      setTextColor = function() end,
    }
    target.write = function() target.writes = target.writes + 1 end
    target.setVisible = function(value) target.visible = value == true end
    created[#created + 1] = target
    return target
  end,
}

_G.textutils = {
  serialize = function(value)
    return tostring(value.page) .. ':' .. tostring(value.snapshot or value.model)
  end,
}

local page_renders = {}
local function render_page(label)
  return function(mon)
    page_renders[#page_renders + 1] = { label = label, target = mon.id }
    return mux.footer_nav(mon, height, width, {
      left = 'ZURUECK',
      center = label,
      right = 'WEITER',
    })
  end
end

local router_page = {
  render = function(self, mon)
    return render_page('ROUTER')(mon)
  end,
  handle_touch = function() return false end,
}

local ctx = {
  devices = { monitor = physical, monitor_name = 'monitor_0' },
  ui_router = ui_router,
  fuel_ui = {
    render_overview = render_page('OVERVIEW'),
    render_details = render_page('DETAILS'),
    render_diagnostics = render_page('DIAGNOSTICS'),
    handle_details_touch = function() return false end,
    handle_diagnostics_touch = function() return false end,
  },
  get_router_ui = function() return router_page end,
  ui = package.loaded['core.ui'],
  colors = package.loaded['shared.colors'],
  keys = { left = 203, pageUp = 201, right = 205, pageDown = 209 },
}

local model = { snapshot = 'stable' }
local function render(expected_index, expected_label)
  monitor_ui.render_monitor(ctx, model)
  assert(monitor_ui.current_page_index() == expected_index,
    'expected page index ' .. expected_index .. ', got ' .. monitor_ui.current_page_index())
  local frame = assert(page_renders[#page_renders], 'page must render')
  assert(frame.label == expected_label, 'expected page ' .. expected_label .. ', got ' .. frame.label)
  assert(created[#created].visible == true, 'completed backbuffer must be visible')
end

local function touch(x)
  local consumed = monitor_ui.handle_input({ 'monitor_touch', 'monitor_0', x, height })
  assert(consumed == true, 'footer touch must be consumed at x=' .. x)
end

render(1, 'OVERVIEW')
touch(width); render(2, 'DETAILS')
touch(width); render(3, 'DIAGNOSTICS')
touch(width); render(4, 'ROUTER')
touch(1); render(3, 'DIAGNOSTICS')
touch(1); render(2, 'DETAILS')
touch(width); render(3, 'DIAGNOSTICS')

-- Replacing the backbuffer at identical character dimensions used to leave
-- the new window blank: the stable snapshot caused the router to skip its
-- first frame. A scale change must always render into the replacement.
local renders_before_scale = #page_renders
scale = 1
render(3, 'DIAGNOSTICS')
assert(#created == 2, 'text-scale change must replace the monitor backbuffer')
assert(#page_renders == renders_before_scale + 1,
  'replacement backbuffer must receive a complete first frame')
assert(created[2].writes > 0, 'replacement backbuffer must contain rendered footer output')

-- Its freshly rebuilt full-width zones must immediately support both
-- directions as well.
touch(1); render(2, 'DETAILS')
touch(width); render(3, 'DIAGNOSTICS')

_G.window = nil
_G.textutils = nil
print('fuel_monitor_navigation_pipeline_test.lua: ok')
