-- nodes/fuel/monitor_ui.lua
--
-- Buendelt alles rund um den Haupt-Monitor und die Ampel an einer Stelle,
-- analog zu nodes/rt/monitor_ui.lua. Das Modul haelt seinen eigenen
-- Lebenszyklus-State (monitor_router, ampel_instance) -- main.lua ruft nur
-- M.render_monitor(ctx) / M.render_ampel(ctx) mit einer frischen
-- ctx-Tabelle pro Aufruf auf. render_ampel() ist eine eigenstaendige
-- Funktion, unabhaengig vom Hauptmonitor-Status.

local M = {}
local ui_completion = require("nodes.fuel.ui_completion")
local window_buffer = require("core.window_buffer")
local mux = require("core.mockup_ui")

local ok_ampel_mod, ampel_mod = pcall(require, "optional.ampel")
local ampel_instance = ok_ampel_mod and type(ampel_mod) == "table" and type(ampel_mod.new) == "function" and ampel_mod.new() or nil

local monitor_router = nil
local current_mon = nil
local render_surface = window_buffer.new()

-- FUEL is primarily operated from the local touch monitor, so readability
-- wins over maximum information density. CC:Tweaked only supports 0.5 scale
-- steps: prefer 1.0 on sufficiently large monitors, but fall back to the old
-- 0.5 layout when 1.0 would leave too little logical screen space.
local PREFERRED_UI_SCALE = 1.0
local FALLBACK_UI_SCALE = 0.5
local MIN_LARGE_WIDTH = 40
local MIN_LARGE_HEIGHT = 18
local scale_state = setmetatable({}, { __mode = "k" })

local function normalized_scale(value)
  local n = tonumber(value) or PREFERRED_UI_SCALE
  n = math.floor(n * 2 + 0.5) / 2
  if n < 0.5 then n = 0.5 end
  if n > 5 then n = 5 end
  return n
end

local function ensure_readable_scale(ctx, mon)
  if not mon or (ctx and ctx.devices and ctx.devices.monitor_is_term) then return end
  if type(mon.setTextScale) ~= "function" or type(mon.getSize) ~= "function" then return end

  local requested = normalized_scale(ctx and ctx.config and ctx.config.fuel_ui_scale)
  local cached = scale_state[mon]
  if cached and cached.requested == requested then
    -- Discovery still applies the historical 0.5 scale in nodes/fuel/main.lua.
    -- Detect that external scale drift instead of trusting our cache forever.
    local ok_current, current = pcall(mon.getTextScale)
    if ok_current and tonumber(current) == cached.applied then return end
  end

  local applied = requested
  local ok_set = pcall(mon.setTextScale, requested)
  if not ok_set then
    scale_state[mon] = { requested = requested, applied = nil }
    return
  end

  local ok_size, w, h = pcall(mon.getSize)
  if ok_size and requested > FALLBACK_UI_SCALE
      and ((tonumber(w) or 0) < MIN_LARGE_WIDTH
        or (tonumber(h) or 0) < MIN_LARGE_HEIGHT) then
    if pcall(mon.setTextScale, FALLBACK_UI_SCALE) then
      applied = FALLBACK_UI_SCALE
    end
  end

  scale_state[mon] = { requested = requested, applied = applied }
end

local function ensure_completion(ctx)
  if ctx and ctx.fuel_ui then
    ui_completion.attach(ctx.fuel_ui, { devices = ctx.devices })
  end
end

-- Zaehler, die ausserhalb des Routers entstehen, werden in
-- M.get_diagnostics() mit dem Router-eigenen Zustand zusammengefuehrt.
local ui_diag_extra = { pointer_events_received = 0, page_handler_calls = 0, model_builds = 0 }

local VIEW_STATE_TO_AMPEL = {
  ERROR = "EMERGENCY", CONFIG_REQUIRED = "WARNING", NO_CONFIG = "WARNING",
  ROUTING_INVALID = "WARNING", VALVE_OFFLINE = "WARNING", NO_STORAGE = "WARNING",
  NO_FRESH_RT_DATA = "WARNING", DATA_STALE = "WARNING", DATA_MISSING = "WARNING",
  LOGISTICS_DISABLED = "muted", NO_ME_BRIDGE = "WARNING", LOGISTICS_BLOCKED = "WARNING",
  RESERVE_LOW = "WARNING", DELIVERING = "LIMITED", READY = "OK", LOADING = "LIMITED",
}
local function fuel_ampel_status(view_state, logistics)
  for _, r in ipairs((logistics or {}).reactors or {}) do
    if type(r.fuel_pct) == "number" and r.fuel_pct < 10 then return "EMERGENCY" end
  end
  return VIEW_STATE_TO_AMPEL[view_state.code] or "WARNING"
end

function M.render_ampel(ctx)
  if not ampel_instance then return end
  ensure_completion(ctx)
  pcall(function()
    local payload = ctx.build_status_payload()
    local view_state = ctx.fuel_ui.compute_view_state({ payload = payload }, ctx.devices, payload.reserve, payload.minimum_reserve)
    ampel_instance.render(ctx.devices.monitor_name, fuel_ampel_status(view_state, payload.logistics))
  end)
end

function M.build_model(ctx)
  ensure_completion(ctx)
  ui_diag_extra.model_builds = ui_diag_extra.model_builds + 1
  local devices = ctx.devices
  local payload = ctx.build_status_payload()
  local comms_diag = ctx.comms and ctx.comms:get_diagnostics() or {}
  local peer = ctx.master_peer_state()
  local summary = payload.registry and payload.registry.summary or ctx.registry:get_summary()
  local now = os.epoch("utc")
  local current_node_id = ctx.comms and ctx.comms.network and ctx.comms.network.id or ctx.config.node_id
  local alert_payload = ctx.master_alerts and ctx.master_alerts.by_node and ctx.master_alerts.by_node[current_node_id] or nil
  local model = ctx.support_ui_pages.build_common_model({
    payload = payload, summary = summary, comms_diag = comms_diag, master_peer = peer, now = now,
    last_scan_ts = devices.last_scan_ts, last_command = devices.last_command, last_command_ts = devices.last_command_ts,
    local_alerts = alert_payload and alert_payload.top or {}, local_alerts_critical = alert_payload and alert_payload.critical or 0,
    node_id = current_node_id
  })
  model.ui_diagnostics = M.get_diagnostics()
  model.view_state = ctx.fuel_ui.compute_view_state(model, devices, payload.reserve, payload.minimum_reserve)
  if type(model.snapshot) == "table" then
    model.snapshot.ui_error_count = model.ui_diagnostics.error_count
    model.snapshot.view_state_code = model.view_state.code
  end
  return model
end

-- All four FUEL pages share the same page-navigation controls. The old
-- labels were short and their touch zones were exactly the text width.
-- Longer, bracketed labels make the controls visually obvious and enlarge
-- the physical touch target without consuming an additional content row.
local function large_footer(target, center)
  local ok, w, h = pcall(function() return target.getSize() end)
  if not ok or not w or not h then return nil end
  local left = w >= 42 and "[ << ZURUECK ]" or "[ < ZUR ]"
  local right = w >= 42 and "[ WEITER >> ]" or "[ WEITER ]"
  return mux.footer_nav(target, h, w, {
    left = left,
    center = center,
    right = right,
    inset = 2,
  })
end

local function page_with_large_footer(render_fn, center)
  return function(target, model, should_clear)
    render_fn(target, model, should_clear)
    return large_footer(target, center)
  end
end

function M.render_monitor(ctx, model)
  local devices = ctx.devices
  if not devices.monitor then
    current_mon = nil
    render_surface:bind(nil, nil)
    if monitor_router then
      if monitor_router.set_monitor_name then monitor_router:set_monitor_name(nil) end
      monitor_router:render(nil, model)
    end
    return false
  end
  ensure_completion(ctx)
  local mon = devices.monitor
  ensure_readable_scale(ctx, mon)
  current_mon = mon
  if not monitor_router then
    local fuel_ui = ctx.fuel_ui
    monitor_router = ctx.ui_router.new({
      error_title = "FUEL UI ERROR",
      on_render_error = ctx.on_render_error,
      pages = {
        { name = "Overview", render = page_with_large_footer(fuel_ui.render_overview, "FUEL OVERVIEW") },
        { name = "Details", render = page_with_large_footer(fuel_ui.render_details, "FUEL DETAILS"),
          handle_touch = function(x, y) return fuel_ui.handle_details_touch and fuel_ui.handle_details_touch(x, y) or false end },
        { name = "Diagnostics", render = page_with_large_footer(fuel_ui.render_diagnostics, "FUEL DIAGNOSTICS"),
          handle_touch = function(x, y) return fuel_ui.handle_diagnostics_touch(current_mon, x, y) end },
        { name = "Router", render = function(target, page_model, should_clear)
            ctx.get_router_ui():render(target, ctx.ui, ctx.colors, should_clear)
            return large_footer(target, "ROUTER")
          end,
          handle_touch = function(x, y) return ctx.get_router_ui():handle_touch(x, y) end }
      },
      key_prev = { [ctx.keys.left] = true, [ctx.keys.pageUp] = true },
      key_next = { [ctx.keys.right] = true, [ctx.keys.pageDown] = true }
    })
  end
  if monitor_router.set_monitor_name then
    monitor_router:set_monitor_name(devices.monitor_name)
  end
  local render_target, binding_changed = render_surface:bind(mon, devices.monitor_name)
  if binding_changed and monitor_router.invalidate_layout then
    monitor_router:invalidate_layout()
  end
  if monitor_router.needs_render and not monitor_router:needs_render(render_target, model) then
    return false
  end
  local ok, result = pcall(render_surface.render, render_surface, function(target)
    return monitor_router:render(target, model)
  end)
  if not ok then
    if monitor_router.invalidate_layout then monitor_router:invalidate_layout() end
    error(result, 0)
  end
  return result
end

function M.handle_input(event)
  local kind = event and event[1]
  if kind == "monitor_touch" or kind == "mouse_click" or kind == "key" or kind == "char" then
    ui_diag_extra.pointer_events_received = ui_diag_extra.pointer_events_received + 1
  end
  if monitor_router and monitor_router:handle_input(event) then
    return true
  end
  if kind ~= "monitor_touch" and kind ~= "mouse_click" then
    return false
  end
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then
    local x, y = event and event[3], event and event[4]
    ui_diag_extra.page_handler_calls = ui_diag_extra.page_handler_calls + 1
    local consumed = page.handle_touch(x, y) == true
    if consumed and monitor_router then
      -- Page-local state (details pagination / router editor) is not part of
      -- the telemetry model snapshot. Force exactly one following redraw so
      -- the visible UI follows the consumed touch.
      if monitor_router.invalidate_content then
        monitor_router:invalidate_content()
      else
        monitor_router.last_snapshot = nil
      end
    end
    return consumed
  end
  return false
end

function M.handle_touch(x, y)
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then
    local consumed = page.handle_touch(x, y) == true
    if consumed and monitor_router then
      if monitor_router.invalidate_content then monitor_router:invalidate_content() else monitor_router.last_snapshot = nil end
    end
    return consumed
  end
  return false
end

function M.get_diagnostics()
  local base = monitor_router and monitor_router.get_diagnostics and monitor_router:get_diagnostics() or { error_count = 0, last_error = nil }
  base.pointer_events_received = ui_diag_extra.pointer_events_received
  base.page_handler_calls = ui_diag_extra.page_handler_calls
  base.model_builds = ui_diag_extra.model_builds
  return base
end

return M
