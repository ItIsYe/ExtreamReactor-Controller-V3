package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['nodes.fuel.monitor_ui'] = nil
package.loaded['optional.ampel'] = nil
package.loaded['nodes.fuel.ui_completion'] = { attach = function(value) return value end }

local width, height, scale = 82, 40, 1.0
local physical = {
  id = 'monitor_0',
  getSize = function() return width, height end,
  getTextScale = function() return scale end,
  setTextScale = function(value) scale = value end,
  setCursorPos = function() end, write = function() end,
  setBackgroundColor = function() end, setTextColor = function() end,
}
local current_parent = physical
local created = {}
_G.window = {
  create = function(parent, x, y, w, h, visible)
    assert(parent == current_parent)
    assert(x == 1 and y == 1 and w == 82 and h == 40)
    local target = { id = #created + 1, width = w, height = h, visible = visible, visibility = {} }
    target.setVisible = function(value) target.visible = value == true; target.visibility[#target.visibility + 1] = target.visible end
    target.getSize = function() return target.width, target.height end
    target.getTextScale = function() return scale end
    target.setCursorPos = function() end; target.write = function() end
    target.setBackgroundColor = function() end; target.setTextColor = function() end
    created[#created + 1] = target
    return target
  end,
}

local rendered = {}
local fake_router = {
  dirty = true, monitor_names = {},
  set_monitor_name = function(self, name) self.monitor_names[#self.monitor_names + 1] = name end,
  invalidate_layout = function(self) self.dirty = true end,
  needs_render = function(self) return self.dirty end,
  render = function(self, target) rendered[#rendered + 1] = target; self.dirty = false; return true end,
  get_diagnostics = function() return { error_count = 0 } end,
  handle_input = function() return false end,
  current = function() return nil end,
}
local ui_router = { new = function(opts) assert(#opts.pages == 4); return fake_router end }

local module = require('nodes.fuel.monitor_ui')
local ctx = {
  devices = { monitor = physical, monitor_name = 'monitor_0' },
  ui_router = ui_router,
  fuel_ui = {
    render_overview = function() end, render_details = function() end, render_diagnostics = function() end,
    handle_diagnostics_touch = function() return false end,
  },
  get_router_ui = function() return { render = function() end, handle_touch = function() return false end } end,
  ui = {}, colors = {}, keys = { left = 1, pageUp = 2, right = 3, pageDown = 4 },
}

module.render_monitor(ctx, {})
assert(scale == 1.0, 'fixed monitor contract must enforce scale 1.0')
assert(#created == 1 and created[1].visible == true)
module.render_monitor(ctx, {})
assert(#created == 1 and #rendered == 1, 'stable fixed monitor must reuse one backbuffer')

-- Wrong geometry is a hard UI configuration error: no hidden legacy rendering.
width, height = 60, 25
fake_router.dirty = true
local before = #rendered
module.render_monitor(ctx, {})
assert(#rendered == before, 'wrong-size monitor must not render the page router')
assert(module.handle_input({ 'monitor_touch', 'monitor_0', 10, 10 }) == false,
  'wrong-size monitor must not accept stale touch targets')

_G.window = nil
print('fuel_monitor_backbuffer_test.lua: ok')
