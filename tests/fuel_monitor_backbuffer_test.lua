package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['nodes.fuel.monitor_ui'] = nil
package.loaded['optional.ampel'] = nil
package.loaded['nodes.fuel.router_ui_responsive'] = { attach = function(value) return value end }
package.loaded['nodes.fuel.ui_completion'] = { attach = function(value) return value end }

local width, height, scale = 60, 20, 0.5
local physical = {
  id = 'monitor_0',
  getSize = function() return width, height end,
  getTextScale = function() return scale end,
}
local current_parent = physical

local created = {}
_G.window = {
  create = function(parent, x, y, w, h, visible)
    assert(parent == current_parent)
    assert(x == 1 and y == 1)
    assert(visible == false)
    local target = { id = #created + 1, width = w, height = h, visible = visible, visibility = {} }
    target.setVisible = function(value)
      target.visible = value == true
      target.visibility[#target.visibility + 1] = target.visible
    end
    created[#created + 1] = target
    return target
  end,
}

local rendered = {}
local fake_router = {
  render = function(self, target, model)
    assert(target.visible == false, 'window must stay hidden while a frame is rendered')
    rendered[#rendered + 1] = target
  end,
  get_diagnostics = function() return { error_count = 0 } end,
  handle_input = function() return false end,
  current = function() return nil end,
}

local ui_router = {
  new = function(opts)
    assert(#opts.pages == 4)
    return fake_router
  end,
}

local module = require('nodes.fuel.monitor_ui')
local ctx = {
  devices = { monitor = physical, monitor_name = 'monitor_0' },
  ui_router = ui_router,
  fuel_ui = {
    render_overview = function() end,
    render_details = function() end,
    render_diagnostics = function() end,
    handle_diagnostics_touch = function() return false end,
  },
  get_router_ui = function() return { render = function() end, handle_touch = function() return false end } end,
  ui = {},
  colors = {},
  keys = { left = 1, pageUp = 2, right = 3, pageDown = 4 },
}

module.render_monitor(ctx, {})
assert(created[1].visible == true, 'completed first frame must be made visible')
assert(created[1].visibility[1] == false and created[1].visibility[2] == true,
  'first frame must follow hidden -> visible lifecycle')

module.render_monitor(ctx, {})
assert(#created == 1, 'stable monitor, size and scale must reuse one window backbuffer')
assert(rendered[1] == created[1] and rendered[2] == created[1], 'router must render into the window backbuffer')
assert(created[1].visibility[3] == false and created[1].visibility[4] == true,
  'reused buffer must be hidden while rendering and shown only after completion')

width = 70
module.render_monitor(ctx, {})
assert(#created == 2, 'monitor resize must recreate the backbuffer')
assert(rendered[3] == created[2])
assert(created[2].visible == true, 'replacement backbuffer must be shown after its first complete frame')

-- A text-scale transition must recreate the buffer even if a mock reports
-- unchanged character dimensions. This explicitly covers the document's
-- scale-change lifecycle requirement.
scale = 1
module.render_monitor(ctx, {})
assert(#created == 3, 'text-scale change must recreate the backbuffer')
assert(rendered[4] == created[3])

-- A physically different monitor must also create a new buffer and publish
-- a complete first frame.
local physical2 = {
  id = 'monitor_1',
  getSize = function() return width, height end,
  getTextScale = function() return scale end,
}
current_parent = physical2
ctx.devices.monitor = physical2
ctx.devices.monitor_name = 'monitor_1'
module.render_monitor(ctx, {})
assert(#created == 4, 'physical monitor change must create a new backbuffer')
assert(rendered[5] == created[4])
assert(created[4].visible == true, 'new monitor buffer must be visible only after its first complete frame')

_G.window = nil
print('fuel_monitor_backbuffer_test.lua: ok')
