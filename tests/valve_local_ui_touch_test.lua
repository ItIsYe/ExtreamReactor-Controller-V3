package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local draw = { buttons = {}, rows = {} }
local mux = {}
mux.fit = function(text, width)
  return tostring(text or ''):sub(1, math.max(0, tonumber(width) or 0))
end
mux.clear = function() end
mux.header = function() end
mux.status_dot = function() end
mux.card = function() end
mux.banner = function() end
mux.data_row = function(_target, x, y, w, opts)
  draw.rows[#draw.rows + 1] = {
    x = x, y = y, w = w,
    label = tostring(opts and opts.label or ''),
    value = tostring(opts and opts.value or ''),
    status = tostring(opts and opts.status or ''),
  }
end
mux.button = function(_target, x, y, w, label, status, h)
  local r = {
    x1 = x, x2 = x + w - 1,
    y = y, y2 = y + h - 1,
    label = label, status = status
  }
  draw.buttons[#draw.buttons + 1] = r
  return r
end
package.loaded['core.mockup_ui'] = mux
package.loaded['shared.colors'] = { get = function() return 1 end }
package.loaded['nodes.valve.local_ui'] = nil

local state = {
  current_high = false,
  initialized = true,
  last_write_error = nil,
  last_command_ts = 1000,
  sorter_name = 'sorter_0',
  actuator_mode = 'sorter',
  redstone_side = nil,
  trusted_source = 'FUEL-1',
  pairing_persisted = true,
  pairing_error = nil,
}

local writes = {}
local controller = {
  get_state = function() return state end,
  apply_valve = function(_self, high, force)
    writes[#writes + 1] = { high = high, force = force }
    assert(high == true, 'local UI must never request OPEN/high=false')
    assert(force == true, 'safe action must force physical write/readback')
    state.current_high = true
    state.initialized = true
    state.last_write_error = nil
    return true
  end,
}

local width, height = 51, 19
local target = {
  getSize = function() return width, height end,
  clear = function() end,
  setBackgroundColor = function() end,
}

local now = 11000
local os_api = { epoch = function() return now end }

local hop = {
  configured = true,
  enabled = true,
  chest = 'minecraft:chest_5',
  interval_s = 4,
  last_scan_ms = 9000,
  modem_ready = true,
}

local ui = require('nodes.valve.local_ui').new({
  controller = controller,
  node_id = 'VALVE-7',
  label = 'Reaktor A Einlass',
  modem_name = 'right',
  target = target,
  os_api = os_api,
  is_master_reachable = function() return true end,
  get_comms_diagnostics = function() return { queue_depth = 0 } end,
  get_hop_status = function() return hop end,
})

assert(ui:render(true) == true)
assert(#draw.buttons == 1, 'exactly one interactive local button is expected')
local b = draw.buttons[1]
assert(b.x1 == 2 and b.x2 == 49, 'button visual width must be x=2..49')
assert(b.y == 14 and b.y2 == 16, 'button visual height must be y=14..16')
local geo = ui:get_touch_geometry()
assert(geo.safe_button.x1 == b.x1 and geo.safe_button.x2 == b.x2)
assert(geo.safe_button.y == b.y and geo.safe_button.y2 == b.y2,
  'touch rectangle must exactly equal the displayed button rectangle')

-- HOP row is display-only and must fit above the button.
local hop_row_found = false
for _, row in ipairs(draw.rows) do
  if row.y == 13 and row.label:find('HOP', 1, true) then
    hop_row_found = true
    assert(row.x == 2 and row.w == 48)
  end
end
assert(hop_row_found, 'HOP summary must be rendered on row 13')

-- Outside the visible button: never consumed, never writes.
assert(ui:handle_event({ 'mouse_click', 1, 1, 14 }) == false)
assert(ui:handle_event({ 'mouse_click', 1, 50, 14 }) == false)
assert(ui:handle_event({ 'mouse_click', 1, 2, 13 }) == false)
assert(ui:handle_event({ 'mouse_click', 1, 2, 17 }) == false)
assert(#writes == 0)

-- Right click is ignored even inside the visible button.
assert(ui:handle_event({ 'mouse_click', 2, 10, 15 }) == false)
assert(#writes == 0)

-- Four corners + centre of the rendered rectangle must trigger.
local points = { {2,14}, {49,14}, {2,16}, {49,16}, {25,15} }
for _, p in ipairs(points) do
  state.current_high = false
  assert(ui:handle_event({ 'mouse_click', 1, p[1], p[2] }) == true)
end
assert(#writes == #points)
for _, call in ipairs(writes) do
  assert(call.high == true and call.force == true)
end

-- A wrong terminal size disables the button and local action.
width, height = 50, 19
ui.force_redraw = true
ui:render(true)
assert(ui:get_touch_geometry().safe_button == nil,
  'size mismatch must clear stale touch geometry')
local before = #writes
assert(ui:handle_event({ 'mouse_click', 1, 25, 15 }) == false)
assert(#writes == before)

print('valve_local_ui_touch_test.lua: ok')
