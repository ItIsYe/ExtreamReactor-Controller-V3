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
mux.metric_card = function(mon, x, y, w, h) bounds(x, y, w, h, 'metric_card') end
mux.kpi_strip = function(mon, x, y, w) bounds(x, y, w, 1, 'kpi_strip') end
mux.section = function(mon, x, y, w) bounds(x, y, w, 1, 'section') end
mux.card = function(mon, x, y, w, h) bounds(x, y, w, h, 'card') end
mux.data_row = function(mon, x, y, w, item)
  bounds(x, y, w, 1, 'data_row')
  rows[#rows + 1] = { label = tostring(item and item.label or ''), value = tostring(item and item.value or '') }
end
mux.footer_nav = function(mon, h, w, opts)
  bounds(1, h, w, 1, 'footer')
  return {
    left = { x1 = 1, x2 = math.min(8, w), y = h },
    right = { x1 = math.max(1, w - 7), x2 = w, y = h },
    center = opts and opts.center,
  }
end
package.loaded['core.mockup_ui'] = mux
package.loaded['nodes.fuel.ui_pages'] = nil
package.loaded['nodes.fuel.ui_completion'] = nil

local ui_pages = require('nodes.fuel.ui_pages')
local completion = require('nodes.fuel.ui_completion')

local ui_stub = { getSize = function(mon) return mon.getSize() end }
local support = {
  common_diagnostic_rows = function() return { { text = 'diag', status = 'text' } } end,
  append_local_alert_rows = function() end,
  render_log_mode_button = function() end,
  handle_log_mode_touch = function() return false end,
  format_age = function() return '0s' end,
}
local devices = { last_scan_ts = 1, storage_name = 'tank_0', discovery_failed = false }
local config = { logistics = { reactors = {} } }
local pages = ui_pages.new({ ui = ui_stub, support_ui_pages = support, devices = devices, config = config })
completion.attach(pages, { devices = devices })
local mon = { getSize = function() return width, height end }

local reactors = {
  {
    label = 'R1', reactor_id = 'rid-1', inlet = 'inlet_1', configured_inlet = 'inlet_1', connected = true,
    item = 'bigreactors:yellorium_ingot', request_below = 0.25, fill_amount = 64, min_in_me = 32,
    fuel_pct = 60, fuel_data_state = 'FRESH', fuel_age_s = 2, fuel_source = 'MASTER',
    route_state = 'ROUTE_READY', operational_state = 'READY', delivery_state = 'READY',
  },
  {
    label = 'R2', reactor_id = 'rid-2', inlet = 'inlet_2', configured_inlet = 'inlet_2', connected = true,
    item = 'bigreactors:yellorium_ingot', request_below = 0.30, fill_amount = 32, min_in_me = 16,
    fuel_pct = 20, fuel_data_state = 'FRESH', fuel_age_s = 3, fuel_source = 'DIRECT',
    route_state = 'ROUTE_READY', operational_state = 'READY', delivery_state = 'REQUESTING',
  },
}
local payload = {
  reserve = 4000,
  minimum_reserve = 2000,
  master_connected = true,
  bindings = { storage = 1 },
  routing_load_status = { ok = true },
  valve_summary = { total = 2, offline = 0, stale = 0 },
  logistics = {
    enabled = true,
    bridge = 'meBridge_0',
    reactors = reactors,
    fuel_data_summary = { fresh = 2, stale = 0, missing = 0 },
    operational_counts = { configured = 2, ready = 2, blocked = 0, stale = 0, missing = 0 },
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
    model_builds = 4, last_render_ms = 1, render_errors = 0, error_count = 0,
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

-- Overview must expose reactor demand on a normal 20-line monitor, not only
-- on very tall displays, and infrastructure components must remain distinct.
width, height = 80, 20
rows = {}
pages.render_overview(mon, model, true)
local overview_text = {}
for _, row in ipairs(rows) do overview_text[#overview_text + 1] = row.label .. ' ' .. row.value end
overview_text = table.concat(overview_text, '\n')
assert(overview_text:find('R1', 1, true), '20-line overview must show reactor rows')
assert(overview_text:find('R2', 1, true), '20-line overview must show requesting reactor')
assert(overview_text:find('REQUESTING', 1, true), 'overview must show current reactor demand')
assert(overview_text:find('ME BRIDGE', 1, true), 'overview must show ME Bridge')
assert(overview_text:find('RESERVE STORAGE', 1, true), 'overview must show reserve storage separately')
assert(overview_text:find('MASTER', 1, true) and overview_text:find('RT DATA', 1, true), 'overview must show MASTER and RT data separately')
assert(overview_text:find('VALVES', 1, true) and overview_text:find('LOGISTICS', 1, true), 'overview must show VALVES and logistics state')

-- Large Details must expose every field required by the uploaded document.
width, height = 100, 30
rows = {}
pages.render_details(mon, model, true)
local detail_text = {}
for _, row in ipairs(rows) do detail_text[#detail_text + 1] = row.label .. ' ' .. row.value end
detail_text = table.concat(detail_text, '\n')
assert(detail_text:find('rid-1', 1, true), 'details must include reactor_id')
assert(detail_text:find('DATA AGE', 1, true) and detail_text:find('2s', 1, true), 'details must include fuel data age')
assert(detail_text:find('ROUTING', 1, true) and detail_text:find('ROUTE_READY', 1, true), 'details must include routing state')
assert(detail_text:find('inlet_1', 1, true), 'details must include inlet')
assert(detail_text:find('yellorium_ingot', 1, true), 'details must include fuel item')
assert(detail_text:find('25%', 1, true), 'details must include request threshold')
assert(detail_text:find('64', 1, true) and detail_text:find('32', 1, true), 'details must include fill/min-ME policy')

-- Every reactor must be reachable from the Details page without leaving it,
-- and its pager touch zones must stay inside the visible monitor.
local completion_state = pages.get_completion_state()
assert(completion_state.details_next, 'first reactor must expose next-reactor touch zone')
assert(completion_state.details_next.x1 >= 1 and completion_state.details_next.x2 <= width)
assert(completion_state.details_next.y >= 1 and completion_state.details_next.y <= height)
assert(pages.handle_details_touch(completion_state.details_next.x1, completion_state.details_next.y) == true)
rows = {}
pages.render_details(mon, model, false)
local second_text = {}
for _, row in ipairs(rows) do second_text[#second_text + 1] = row.label .. ' ' .. row.value end
second_text = table.concat(second_text, '\n')
assert(second_text:find('rid-2', 1, true), 'details paging must reach the second reactor')
assert(second_text:find('REQUESTING', 1, true), 'details must expose current delivery/request state')

-- Diagnostics must expose every lifecycle counter requested by the document,
-- including render_errors even when it is zero.
rows = {}
pages.render_diagnostics(mon, model, true)
local diagnostic_text = {}
for _, row in ipairs(rows) do diagnostic_text[#diagnostic_text + 1] = row.label .. ' ' .. row.value end
diagnostic_text = table.concat(diagnostic_text, '\n')
assert(diagnostic_text:find('REQ5', 1, true), 'diagnostics must expose frames_requested')
assert(diagnostic_text:find('COM2', 1, true), 'diagnostics must expose frames_committed')
assert(diagnostic_text:find('SKIP3', 1, true), 'diagnostics must expose frames_skipped')
assert(diagnostic_text:find('CLR1', 1, true), 'diagnostics must expose full_clears')
assert(diagnostic_text:find('TR1', 1, true), 'diagnostics must expose transition_count')
assert(diagnostic_text:find('ERR0', 1, true), 'diagnostics must expose render_errors even at zero')
assert(diagnostic_text:find('1ms', 1, true), 'diagnostics must expose last_render_ms')
assert(diagnostic_text:find('PTR0', 1, true), 'diagnostics must expose pointer_events')
assert(diagnostic_text:find('MOD4', 1, true), 'diagnostics must expose model_builds')

print('fuel_ui_responsive_sizes_test.lua: ok')
