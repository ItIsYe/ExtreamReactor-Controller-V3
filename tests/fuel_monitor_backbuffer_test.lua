package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['nodes.fuel.monitor_ui'] = nil
package.loaded['optional.ampel'] = nil

local width, height = 60, 20
local physical = {
  getSize = function() return width, height end,
}

local created = {}
_G.window = {
  create = function(parent, x, y, w, h, visible)
    assert(parent == physical)
    assert(x == 1 and y == 1)
    assert(visible == false)
    local target = { id = #created + 1, width = w, height = h }
    created[#created + 1] = target
    return target
  end,
}

local rendered = {}
local fake_router = {
  render = function(self, target, model)
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
module.render_monitor(ctx, {})
assert(#created == 1, 'stable monitor and size must reuse one window backbuffer')
assert(rendered[1] == created[1] and rendered[2] == created[1], 'router must render into the window backbuffer')

width = 70
module.render_monitor(ctx, {})
assert(#created == 2, 'monitor resize must recreate the backbuffer')
assert(rendered[3] == created[2])

_G.window = nil
print('fuel_monitor_backbuffer_test.lua: ok')
