package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rows = {}
local mux = {
  fit = function(text, width) return tostring(text or ''):sub(1, math.max(0, tonumber(width) or 0)) end,
  clear = function() end,
  header = function() end,
  status_dot = function() end,
  card = function() end,
  banner = function() end,
  button = function(_target, x, y, w, label, status, h)
    return { x1=x, x2=x+w-1, y=y, y2=y+h-1, label=label, status=status }
  end,
  data_row = function(_target, x, y, w, opts)
    rows[#rows + 1] = { x=x, y=y, w=w, label=tostring(opts.label or ''), value=tostring(opts.value or ''), status=opts.status }
  end,
}
package.loaded['core.mockup_ui'] = mux
package.loaded['shared.colors'] = { get = function() return 1 end }
package.loaded['nodes.valve.local_ui'] = nil

local state = {
  current_high=true, initialized=true, last_write_error=nil, last_command_ts=1000,
  sorter_name='sorter_0', actuator_mode='sorter',
  trusted_source='FUEL-1', pairing_persisted=true, pairing_error=nil,
}
local controller = {
  get_state=function() return state end,
  apply_valve=function() error('HOP display test must never actuate') end,
}
local target = {
  getSize=function() return 51,19 end,
  clear=function() end,
  setBackgroundColor=function() end,
}
local now = 20000
local hop = {}
local ui = require('nodes.valve.local_ui').new({
  controller=controller, target=target,
  os_api={ epoch=function() return now end },
  is_master_reachable=function() return true end,
  get_comms_diagnostics=function() return { queue_depth=0 } end,
  get_hop_status=function() return hop end,
})

local function render_and_find(expected)
  rows = {}
  ui.force_redraw = true
  assert(ui:render(true) == true)
  for _, row in ipairs(rows) do
    if row.y == 11 and row.label == 'HOP' then
      assert(row.value == expected, 'expected HOP ' .. expected .. ', got ' .. row.value)
      return
    end
  end
  error('HOP status row not found')
end

hop = { configured=false, enabled=false, interval_s=4, last_scan_ms=0, modem_ready=true }
render_and_find('AUS')

hop = { configured=true, enabled=false, chest='chest_5', interval_s=4, last_scan_ms=0, modem_ready=true }
render_and_find('FEHLER')

hop = { configured=true, enabled=true, chest='chest_5', interval_s=4, last_scan_ms=0, modem_ready=true }
render_and_find('WARTE')

hop = { configured=true, enabled=true, chest='chest_5', interval_s=4, last_scan_ms=18000, modem_ready=true }
render_and_find('AKTIV')

hop = { configured=true, enabled=true, chest='chest_5', interval_s=4, last_scan_ms=9000, modem_ready=true }
render_and_find('STALE')

hop = { configured=true, enabled=true, chest='chest_5', interval_s=4, last_scan_ms=18000, modem_ready=false }
render_and_find('KEIN MODEM')

print('valve_local_ui_hop_test.lua: ok')
