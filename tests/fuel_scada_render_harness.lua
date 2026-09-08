package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Fixed 82x40 presentation/touch geometry harness.
package.preload['shared.colors'] = function()
  return { get = function(name) return name end }
end
package.preload['shared.constants'] = function()
  return { roles = { VALVE_NODE = 'VALVE' } }
end

local drawn_buttons = {}
package.preload['core.mockup_ui'] = function()
  local M = {}
  M.fit = function(text, width)
    local s = tostring(text or '')
    width = math.max(0, tonumber(width) or #s)
    if #s <= width then return s end
    if width <= 1 then return s:sub(1, width) end
    return s:sub(1, width - 1) .. '~'
  end
  local noop = function() end
  M.clear, M.header, M.banner, M.metric_card = noop, noop, noop, noop
  M.text, M.data_row, M.outlined_progress, M.section = noop, noop, noop, noop
  M.card, M.warning_box, M.status_dot, M.table_header = noop, noop, noop, noop
  M.button = function(_, x, y, w, label, _, h)
    h = math.max(1, tonumber(h) or 1)
    local r = { x1 = x, x2 = x + w - 1, y = y, y2 = y + h - 1, label = label }
    drawn_buttons[#drawn_buttons + 1] = r
    return r
  end
  return M
end

peripheral = {
  getNames = function() return { 'minecraft:chest_1', 'monitor_0', 'wireless_modem_0' } end,
  getType = function(name)
    if name == 'monitor_0' then return 'monitor' end
    if name == 'wireless_modem_0' then return 'modem' end
    return 'inventory'
  end,
}

local function mon(w, h)
  return { getSize = function() return w, h end }
end

local function reactors(n)
  local out = {}
  for i = 1, n do
    out[i] = {
      reactor_id = 'reactor-' .. i,
      label = 'Reaktor ' .. i,
      fuel_pct = (i * 7) % 100,
      fuel_data_state = 'FRESH', fuel_age_s = 2, fuel_source = 'MASTER',
      delivery_state = i == 3 and 'DELIVERING' or 'READY', operational_state = 'READY',
      route_state = 'ROUTE_READY', request_below = 0.25, fill_amount = 64,
      min_in_me = 32, resupply_cooldown_s = 30,
      path = { 'VALVE-1', 'VALVE-2' }, last_item = 'Uranium Block', last_element = 'Uranium',
    }
  end
  return out
end

local function height(r) return r and (r.y2 - r.y + 1) or 0 end
local function assert_inside(r)
  assert(r, 'touch rectangle missing')
  assert(r.x1 >= 1 and r.x2 <= 82 and r.y >= 1 and r.y2 <= 40, 'touch rectangle outside 82x40')
end


-- Global page footer: visible 3-row buttons must return the same 3-row touch rectangles.
do
  local ms = require('nodes.fuel.monitor_scada')
  drawn_buttons = {}
  local footer = ms.footer(mon(82, 40), 'FUEL OVERVIEW')
  assert(height(footer.left) == 3 and height(footer.right) == 3, 'global footer touch height must match visible 3-row buttons')
  assert(footer.left.y == 38 and footer.left.y2 == 40)
  assert(footer.right.y == 38 and footer.right.y2 == 40)
end

-- Overview/Details/Diagnostics: always fixed SCADA, no small-screen legacy path.
do
  local scada = require('nodes.fuel.scada_layout')
  local ui = {}
  scada.attach(ui, {})
  local model = {
    node_id = 'FUEL-1', status = 'OK', master_state = 'OK', summary = { total = 9, missing = 0 },
    local_alerts = {}, last_scan = 'now', last_command = 'none',
    ui_diagnostics = { error_count = 0, frames_committed = 2, frames_requested = 3, frames_skipped = 1, pointer_events_received = 5, model_builds = 4 },
    view_state = { code = 'READY', severity = 'OK', title = 'Bereit', detail = 'Alle bereit' },
    payload = {
      reserve = 18432, minimum_reserve = 2000,
      valve_summary = { total = 24, offline = 0, stale = 0 },
      logistics = {
        enabled = true, bridge = 'meBridge_0', export_chest = 'chest_3', reactors = reactors(20),
        fuel_data_summary = { fresh = 20, stale = 0, missing = 0 },
        fuel_families = { { element = 'uranium', ingot_amt = 64, block_amt = 32, total = 352 } },
      },
    },
  }

  drawn_buttons = {}
  ui.render_overview(mon(82, 40), model, true)
  local s = ui.get_completion_state()
  assert(s.fixed_width == 82 and s.fixed_height == 40, 'fixed contract must be 82x40')
  assert(s.scada_overview_page == 1)
  assert(ui.handle_overview_touch(65, 33) == true, 'overview page button must consume all three visible rows')
  assert(ui.get_completion_state().scada_overview_page == 2)

  drawn_buttons = {}
  ui.render_details(mon(82, 40), model, true)
  s = ui.get_completion_state()
  assert_inside(s.details_next)
  assert(height(s.details_next) == 3, 'details reactor navigation must be 3 rows high')
  assert(ui.handle_details_touch(s.details_next.x1, s.details_next.y2) == true,
    'bottom row of visible details button must be touchable')

  drawn_buttons = {}
  ui.render_diagnostics(mon(82, 40), model, true)
  assert(ui.handle_diagnostics_touch(10, 10) == false, 'diagnostics has no hidden touch action')

  -- Wrong size may show only the fixed-size error, never a legacy UI.
  assert(ui.render_overview(mon(60, 25), model, true) == false)
end

-- Every router mode uses only the fixed renderer and every operational touch
-- reference is the rectangle returned by a visible mux.button.
do
  local sr = require('nodes.fuel.router_scada')
  local rs = reactors(16)
  local router = {
    _ui = {
      mode = 'list', reactors = rs, export_chest = 'chest_3', logistics_enabled = true,
      dirty = true, list_scroll = 0, learn_scroll = 0, chest_scroll = 0,
      path_scroll = 0, picker_scroll = 0, teaching = false, save = { state = 'IDLE' },
    },
    routing_load_status = { ok = true },
    get_reactors = function() return { { id = 'reactor-17', label = 'Reaktor 17' } } end,
    redstone_router = { comms = { get_peers = function() return {
      ['VALVE-1'] = { role = 'VALVE', down = false, label = 'Valve 1' },
      ['VALVE-2'] = { role = 'VALVE', down = false, label = 'Valve 2' },
      ['VALVE-3'] = { role = 'VALVE', down = false, label = 'Valve 3' },
    } end } },
  }
  sr.attach(router)

  drawn_buttons = {}
  router:_render_list(mon(82, 40), 82, 40)
  assert(#router._ui.reactor_btns == 8, 'router list intentionally pages 8 reactors')
  assert(height(router._ui.reactor_btns[1]) == 2, 'visible BEARB button must be 2 rows high')
  assert(height(router._ui.logistics_btn) == 3 and height(router._ui.export_chest_btn) == 3 and height(router._ui.learn_btn) == 3)
  assert(height(router._ui.save_btn) == 3 and height(router._ui.reset_btn) == 3)
  assert_inside(router._ui.list_scroll_down)
  assert(height(router._ui.list_scroll_down) == 3)

  router._ui.editing = rs[1]
  drawn_buttons = {}
  router:_render_edit(mon(82, 40), 82, 40)
  assert(height(router._ui.path_row) == 3)
  assert(height(router._ui.request_below_minus) == 3 and height(router._ui.request_below_plus) == 3)
  assert(height(router._ui.cooldown_minus) == 3 and height(router._ui.cooldown_plus) == 3)
  assert(height(router._ui.edit_done_btn) == 3 and height(router._ui.edit_delete_btn) == 3 and height(router._ui.edit_cancel_btn) == 3)

  drawn_buttons = {}
  router:_render_learn(mon(82, 40), 82, 40)
  assert(#router._ui.learn_btns == 1 and height(router._ui.learn_btns[1]) == 2)
  assert(height(router._ui.learn_cancel_btn) == 3)

  drawn_buttons = {}
  router:_render_chest_pick(mon(82, 40), 82, 40)
  assert(#router._ui.chest_btns == 1 and height(router._ui.chest_btns[1]) == 2)
  assert(height(router._ui.chest_cancel_btn) == 3)

  router._ui.editing = rs[1]
  drawn_buttons = {}
  router:_render_path(mon(82, 40), 82, 40)
  assert(height(router._ui.teach_btn) == 3)
  assert(#router._ui.step_btns > 0 and height(router._ui.step_btns[1]) == 2)
  assert(#router._ui.integrator_btns > 0 and height(router._ui.integrator_btns[1]) == 2)
  assert(height(router._ui.path_done_btn) == 3 and height(router._ui.path_clear_btn) == 3 and height(router._ui.path_cancel_btn) == 3)

  -- Wrong size never calls a legacy renderer: it clears all operational touch refs.
  router:_render_list(mon(60, 25), 60, 25)
  assert(router._ui.logistics_btn == nil and #router._ui.reactor_btns == 0)
end

print('fuel_scada_render_harness.lua: ok')
