package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.preload['shared.colors'] = function()
  return { get = function(name) return name end }
end
package.preload['shared.constants'] = function()
  return { roles = { VALVE_NODE = 'VALVE' } }
end

local drawn_buttons = {}
local drawn_text = {}
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
  M.data_row, M.outlined_progress, M.section = noop, noop, noop
  M.card, M.warning_box, M.status_dot, M.table_header = noop, noop, noop, noop
  M.text = function(_, x, y, text)
    drawn_text[#drawn_text + 1] = { x=x, y=y, text=tostring(text or '') }
  end
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

-- Fixed scale monitor and smaller shared footer.
do
  local scale = 0.5
  local physical = {
    getTextScale=function() return scale end,
    setTextScale=function(v) scale=v end,
    getSize=function() if scale == 1.0 then return 82,40 end return 164,81 end,
    setBackgroundColor=function() end,
    clear=function() end,
  }
  local ms = require('nodes.fuel.monitor_scada')
  local ready,w,h = ms.ensure(physical,0.5)
  assert(ready and w==82 and h==40 and scale==1.0)
  drawn_buttons = {}
  local footer = ms.footer(mon(82, 40), 'FUEL OVERVIEW')
  assert(height(footer.left) == 2 and height(footer.right) == 2)
  assert(footer.left.x1 == 3 and footer.left.x2 == 17 and footer.left.y == 38 and footer.left.y2 == 39)
  assert(footer.right.x1 == 65 and footer.right.x2 == 79 and footer.right.y == 38 and footer.right.y2 == 39)
end

-- Overview/Details/Diagnostics.
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

  drawn_buttons, drawn_text = {}, {}
  ui.render_overview(mon(82, 40), model, true)
  local s = ui.get_completion_state()
  assert(s.fixed_width == 82 and s.fixed_height == 40)
  assert(s.scada_overview_page == 1)
  assert(ui.handle_overview_touch(70, 34) == true, 'overview next button must consume visible 2-row rectangle')
  assert(ui.get_completion_state().scada_overview_page == 2)

  -- With only two configured reactors, all remaining slots must still be visible.
  model.payload.logistics.reactors = reactors(2)
  drawn_text = {}
  ui.render_overview(mon(82, 40), model, true)
  local missing = false
  for _, t in ipairs(drawn_text) do
    if t.text:find('NICHT KONFIGURIERT', 1, true) then missing = true; break end
  end
  assert(missing, 'Overview must visibly keep unconfigured reactor slots')

  model.payload.logistics.reactors = reactors(20)
  drawn_buttons = {}
  ui.render_details(mon(82, 40), model, true)
  s = ui.get_completion_state()
  assert_inside(s.details_next)
  assert(height(s.details_next) == 2)
  assert(ui.handle_details_touch(s.details_next.x1, s.details_next.y2) == true)

  drawn_buttons = {}
  ui.render_diagnostics(mon(82, 40), model, true)
  assert(ui.handle_diagnostics_touch(10, 10) == false)
  assert(ui.render_overview(mon(60, 25), model, true) == false)
end

-- Router geometry.
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

  router:_render_list(mon(82, 40), 82, 40)
  assert(#router._ui.reactor_btns == 8)
  assert(height(router._ui.reactor_btns[1]) == 2)
  assert(height(router._ui.logistics_btn) == 2 and height(router._ui.export_chest_btn) == 2 and height(router._ui.learn_btn) == 2)
  assert(height(router._ui.save_btn) == 2 and height(router._ui.reset_btn) == 2)
  assert_inside(router._ui.list_scroll_down)
  assert(height(router._ui.list_scroll_down) == 2)

  router._ui.editing = rs[1]
  router:_render_edit(mon(82, 40), 82, 40)
  assert(height(router._ui.path_row) == 2)
  assert(height(router._ui.request_below_minus) == 2 and height(router._ui.request_below_plus) == 2)
  assert(height(router._ui.cooldown_minus) == 2 and height(router._ui.cooldown_plus) == 2)
  assert(height(router._ui.edit_done_btn) == 2 and height(router._ui.edit_delete_btn) == 2 and height(router._ui.edit_cancel_btn) == 2)

  router:_render_learn(mon(82, 40), 82, 40)
  assert(#router._ui.learn_btns == 1 and height(router._ui.learn_btns[1]) == 2)
  assert(height(router._ui.learn_cancel_btn) == 2)

  router:_render_chest_pick(mon(82, 40), 82, 40)
  assert(#router._ui.chest_btns == 1 and height(router._ui.chest_btns[1]) == 2)
  assert(height(router._ui.chest_cancel_btn) == 2)

  router._ui.editing = rs[1]
  router:_render_path(mon(82, 40), 82, 40)
  assert(height(router._ui.teach_btn) == 2)
  assert(#router._ui.step_btns > 0 and height(router._ui.step_btns[1]) == 2)
  assert(#router._ui.integrator_btns > 0 and height(router._ui.integrator_btns[1]) == 2)
  assert(height(router._ui.path_done_btn) == 2 and height(router._ui.path_clear_btn) == 2 and height(router._ui.path_cancel_btn) == 2)

  router:_render_list(mon(60, 25), 60, 25)
  assert(router._ui.logistics_btn == nil and #router._ui.reactor_btns == 0)
end

print('fuel_scada_render_harness.lua: ok')
