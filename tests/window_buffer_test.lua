package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local window_buffer = require('core.window_buffer')

local width, height, scale = 40, 16, 0.5
local parent = {
  getSize = function() return width, height end,
  getTextScale = function() return scale end,
}

local created = {}
local fake_window = {
  create = function(actual_parent, x, y, w, h, visible)
    assert(actual_parent == parent)
    assert(x == 1 and y == 1 and w == width and h == height)
    assert(visible == false, 'new frame buffers must start hidden')
    local target = {
      visible = false,
      visibility = {},
      getSize = function() return w, h end,
    }
    target.setVisible = function(value)
      target.visible = value == true
      target.visibility[#target.visibility + 1] = target.visible
    end
    created[#created + 1] = target
    return target
  end,
}

local surface = window_buffer.new({ window_api = fake_window })
local target, changed = surface:bind(parent, 'monitor_0')
assert(changed == true and target == created[1])
assert(target.visible == false)

local result = surface:render(function(render_target)
  assert(render_target == target and render_target.visible == false)
  return 'first-frame'
end)
assert(result == 'first-frame')
assert(target.visible == true, 'a complete first frame must be published')

local stable_target, stable_changed = surface:bind(parent, 'monitor_0')
assert(stable_target == target and stable_changed == false, 'stable geometry must reuse the active buffer')

width = 48
local replacement, resize_changed = surface:bind(parent, 'monitor_0')
assert(resize_changed == true and replacement ~= target)
assert(target.visible == true, 'the previous frame must remain visible while its replacement is rendered')
surface:render(function(render_target)
  assert(render_target == replacement and render_target.visible == false)
  assert(target.visible == true)
end)
assert(target.visible == false and replacement.visible == true,
  'a completed replacement must atomically become the active frame')

scale = 1
local failed_replacement = surface:bind(parent, 'monitor_0')
local ok = pcall(function()
  surface:render(function(render_target)
    assert(render_target == failed_replacement)
    error('synthetic render failure')
  end)
end)
assert(ok == false, 'render failures must propagate')
assert(replacement.visible == true, 'a failed replacement must preserve the previous visible frame')
assert(failed_replacement.visible == false, 'a failed replacement must never be published')

local fallback_surface = window_buffer.new({ window_api = {} })
local fallback_target, fallback_changed = fallback_surface:bind(parent, 'monitor_0')
assert(fallback_target == parent and fallback_changed == true)
local fallback_calls = 0
fallback_surface:render(function(render_target)
  assert(render_target == parent)
  fallback_calls = fallback_calls + 1
end)
assert(fallback_calls == 1, 'physical-monitor fallback must remain functional without window.create')

print('window_buffer_test.lua: ok')
