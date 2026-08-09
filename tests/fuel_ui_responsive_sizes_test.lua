package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local width, height = 30, 12
local rows = {}
local function bounds(x, y, w, h, op)
  x, y, w, h = tonumber(x) or 1, tonumber(y) or 1, tonumber(w) or 1, tonumber(h) or 1
  assert(x >= 1 and y >= 1, op .. ' wrote before monitor origin')
  assert(w >= 1 and h >= 1, op .. ' used non-positive geometry')
  assert(x + w - 1 <= width, string.format('%s overflow x=%d w=%d monitor=%d', op, x, w, width))
  assert(y + h - 1 <= height, string.format('%s overflow y=%d h=%d monitor=%d', op, y, h, height))
end

local mux = {}
mux.clear = function() end
mux.fit = function(text, limit)
  text, limit = tostring(text or ''), math.max(0, tonumber(limit) or 0)
  return text:sub(1, limit)
end
mux.header = function(mon) bounds(1, 1, width, math.min(3, height), 'header') end
mux.status_dot = function(mon, x, y, label, status, w) bounds(x, y, math.max(1, math.min(tonumber(w) or #tostring(label), width - x + 1)), 1, 'status_dot') end
mux.banner = function(mon, x, y, w) bounds(x, y, w, 1, 'banner') end
mux.metric_card = function(mon, x, y, w, h, item) bounds(x, y, w, h, 'metric_card') end
mux.kpi_strip = function(mon, x, y, w) bounds(x, y, w, 1, 'kpi_strip') end
mux.section = function(mon, x, y, w) bounds(x, y, w, 1, 'section') end
mux.card = function(mon, x, y, w, h) bounds(x, y, w, h, 'card') end
mux.data_row = function(mon, x, y, w, item)
  bounds(x, y, w, 1, 'data_row')
  rows[#rows + 1] = { label = tostring(item and item.label or ''), value = tostring(item and item.value or '') }
end
mux.footer_nav = function(mon, h, w, opts)
  bounds(1, h, w, 1, 'footer')
  return { center = opts and opts.center }
end
package.loaded['core.mockup_ui'] = mux
package.loaded['nodes.fuel.ui_pages'] = nil

local ui_pages = require('nodes.fuel.ui_pages')

local ui_stub = { getSize = function(mon) return mon.getSize() end }
local support = {
  common_diagnostic_rows = function() return { { text = 'diag', status = 'text' } } end,
  append_local_alert_rows = function() end,
  render_log_mode_button = function() end,
  handle_log_mode_touch = function() return false end,
  format_age = function() return '0s' end,
}
local devices = { last_scan_ts = 1, storage_name = 'tank_0', discovery_failed = false }
local config = {
  logistics = {
    reactors = {
      { name = 'R1', reactor_id = 'rid-1', inlet = 'inlet_1', item = 'bigreactors:yellorium_ingot', request_below = 0.25, fill_amount = 64, min_in_me = 32 },
      { name = 'R2', reactor_id = 'rid-2', inlet = 'inlet_2', item = 'bigreactors:yellorium_ingot', request_below = 0.30, fill_amount = 32, min_in_me = 16 },
    }
  }
}
local pages = ui_pages.new({ ui = ui_stub, support_ui_pages = support, devices = devices, config = config })
local mon = { getSize = function() return width, height end }

local payload = {
  reserve = 4000,
  minimum_reserve = 2000,
  master_connected = true,
  bindings = { storage = 1 },
  routing_load_status = { ok = true },
  valve_summary = { total = 0, offline = 0 },
  logistics = {
    enabled = true,
    bridge = 'meBridge_0',
    reactors = {
      { label = 'R1', reactor_id = 'rid-1', inlet = 'inlet_1', connected = true, fuel_pct = 60 },
      { label = 'R2', reactor_id = 'rid-2', inlet = 'inlet_2', connected = true, fuel_pct = 20 },
    },
  },
}
local model = {
  payload = payload,
  view_state = { code = 'READY', severity = 'OK', title = 'Bereit' },
  node_id = 'FUEL-TEST',
  master_state = 'OK',
  status = 'OK',
  summary = { total = 3, bound = 3, missing = 0 },
  local_alerts = {},
  last_scan = 'now',
  last_command = 'none',
  ui_diagnostics = {
    frames_committed = 2, frames_skipped = 3, frames_requested = 5,
    full_clears = 1, transition_count = 1, pointer_events_received = 0,
    model_builds = 4, last_render_ms = 1, error_count = 0,
  },
}

local sizes = { {30, 12}, {40, 16}, {51, 19}, {80, 20}, {100, 30} }
for _, size in ipairs(sizes) do
  width, height = size[1], size[2]
  rows = {}
  local ok, err = pcall(function()
    assert(pages.render_overview(mon, model, true))
    assert(pages.render_details(mon, model, true))
    assert(pages.render_diagnostics(mon, model, true))
  end)
  if not ok then error(string.format('%dx%d: %s', width, height, tostring(err))) end
end

-- On a sufficiently large monitor the details page must expose real reactor
-- delivery configuration rather than generic route counters.
width, height = 100, 30
rows = {}
pages.render_details(mon, model, true)
local combined = {}
for _, row in ipairs(rows) do combined[#combined + 1] = row.label .. ' ' .. row.value end
local text = table.concat(combined, '\n')
assert(text:find('inlet_1', 1, true), 'reactor details must include configured inlet')
assert(text:find('yellorium_ingot', 1, true), 'reactor details must include configured fuel item')
assert(text:find('REQ<25%', 1, true), 'reactor details must include request threshold')
assert(text:find('F64', 1, true) and text:find('ME32', 1, true), 'reactor details must include fill/min-ME policy')

print('fuel_ui_responsive_sizes_test.lua: ok')
