-- nodes/fuel/ui_completion.lua
-- Active FUEL Overview/Details completion layer.
--
-- This module is presentation-only. Per-reactor freshness, routing readiness
-- and operational state come from operational_summary.lua in the status
-- payload; no delivery/safety decision is reimplemented here.

local M = {}
local mux = require("core.mockup_ui")

local function short(value, suffix)
  local n = tonumber(value)
  if not n then return "-" end
  if math.abs(n) >= 1000000 then return string.format("%.1fM%s", n / 1000000, suffix or "") end
  if math.abs(n) >= 1000 then return string.format("%.1fk%s", n / 1000, suffix or "") end
  return string.format("%.0f%s", n, suffix or "")
end

local function severity_for_reactor(reactor)
  local state = reactor.delivery_state or reactor.operational_state or "MISSING"
  if state == "READY" then return "OK" end
  if state == "DELIVERING" or state == "REQUESTING" then return "LIMITED" end
  return "WARNING"
end

local function route_severity(route_state)
  if route_state == "DIRECT" or route_state == "ROUTE_READY" then return "OK" end
  return "WARNING"
end

local function affected(reactors, predicate)
  local out = {}
  for _, reactor in ipairs(reactors or {}) do
    if type(reactor) == "table" and predicate(reactor) then
      out[#out + 1] = tostring(reactor.label or reactor.reactor_id or "?")
    end
  end
  return out
end

function M.compute_view_state(model, devices, reserve, minimum)
  local payload = model and model.payload or {}
  local logistics = payload.logistics or {}
  local reactors = logistics.reactors or {}
  local bindings = payload.bindings or {}
  local valve = payload.valve_summary or {}

  if payload.protocol_mismatch or (devices and devices.proto_mismatch) then
    return { code = "ERROR", severity = "ERROR", title = "Protokollfehler", detail = "MASTER/FUEL Protokoll passt nicht", action = "Versionen pruefen" }
  end
  if #reactors == 0 then
    return { code = "CONFIG_REQUIRED", severity = "WARNING", title = "Konfiguration erforderlich", detail = "Keine Reaktoren konfiguriert", action = "logistics.reactors konfigurieren" }
  end
  if payload.routing_load_status and payload.routing_load_status.ok == false then
    return { code = "ROUTING_INVALID", severity = "WARNING", title = "Routing ungueltig", detail = tostring(payload.routing_load_status.message or payload.routing_load_status.code or "Fehler"), action = "fuel_routes.lua pruefen" }
  end
  if (tonumber(valve.offline) or 0) > 0 or (tonumber(valve.stale) or 0) > 0 then
    return {
      code = "VALVE_OFFLINE", severity = "WARNING", title = "Ventil-Verbindung nicht bereit",
      detail = string.format("offline=%d stale=%d", tonumber(valve.offline) or 0, tonumber(valve.stale) or 0),
      action = "VALVE-Node(s) und Funk pruefen"
    }
  end
  if (tonumber(bindings.storage) or 0) == 0 then
    return { code = "NO_STORAGE", severity = "WARNING", title = "Kein Reserve-Storage", detail = "storage_bus nicht gefunden", action = "Wired Modem/Storage pruefen" }
  end
  if payload.master_connected == false then
    return { code = "NO_FRESH_RT_DATA", severity = "WARNING", title = "MASTER/RT-Daten fehlen", detail = "MASTER nicht aktuell erreichbar", action = "MASTER- und RT-Verbindung pruefen" }
  end
  if logistics.enabled ~= true then
    return { code = "LOGISTICS_DISABLED", severity = "LIMITED", title = "Logistik deaktiviert", detail = "logistics.enabled = false", action = "Nur aktivieren, wenn Hardware bereit ist" }
  end
  if logistics.bridge == nil then
    return { code = "NO_ME_BRIDGE", severity = "WARNING", title = "ME Bridge fehlt", detail = "Keine betriebsbereite ME Bridge erkannt", action = "ME Bridge/Wired Modem pruefen" }
  end

  local blocked = affected(reactors, function(r) return r.operational_state == "BLOCKED" end)
  if #blocked > 0 then
    return { code = "LOGISTICS_BLOCKED", severity = "WARNING", title = "Lieferweg blockiert", detail = table.concat(blocked, ", "), action = "Inlet/Routing/VALVE pruefen" }
  end
  local missing = affected(reactors, function(r) return r.fuel_data_state == "MISSING" end)
  if #missing > 0 then
    return { code = "DATA_MISSING", severity = "WARNING", title = "Reaktordaten fehlen", detail = table.concat(missing, ", "), action = "reactor_id und RT-Status pruefen" }
  end
  local stale = affected(reactors, function(r) return r.fuel_data_state == "STALE" end)
  if #stale > 0 then
    return { code = "DATA_STALE", severity = "WARNING", title = "Reaktordaten veraltet", detail = table.concat(stale, ", "), action = "MASTER-/RT-Verbindung pruefen" }
  end

  reserve = tonumber(reserve ~= nil and reserve or payload.reserve)
  minimum = tonumber(minimum ~= nil and minimum or payload.minimum_reserve)
  if reserve and minimum and reserve < minimum then
    return { code = "RESERVE_LOW", severity = "WARNING", title = "Reserve niedrig", detail = tostring(reserve) .. " < " .. tostring(minimum), action = "Nachschub sicherstellen" }
  end

  if logistics.current_request then
    local request = logistics.current_request
    local detail = type(request) == "table" and tostring(request.label or request.reactor_id or request.state or "aktiv") or tostring(request)
    return { code = "DELIVERING", severity = "LIMITED", title = "Lieferung aktiv", detail = detail, action = nil }
  end
  return { code = "READY", severity = "OK", title = "Bereit", detail = "Alle konfigurierten Reaktoren sind betriebsbereit", action = nil }
end

local function render_header(mon, model, title, page, should_clear)
  local w, h = mon.getSize()
  local state = model.view_state or M.compute_view_state(model, nil)
  if should_clear == true then mux.clear(mon) end
  mux.header(mon, { title = title, node_id = model.node_id or "FU-?", page = page, status = state.severity or "WARNING", icon = "fuel" })
  return w, h, state
end

local function data_row(mon, w, h, y, item)
  if y >= 1 and y < h then
    mux.data_row(mon, 2, y, math.max(1, w - 3), item)
    return y + 1
  end
  return y
end

local function fuel_text(reactor)
  local pct = type(reactor.fuel_pct) == "number" and (tostring(reactor.fuel_pct) .. "%") or "--"
  return pct .. " " .. tostring(reactor.fuel_data_state or "MISSING") .. " " .. tostring(reactor.delivery_state or reactor.operational_state or "?")
end

-- Uran vs. Blutonium und Ingot vs. Block werden pro Lieferung automatisch
-- entschieden (siehe logistics_router.lua's pick_fuel_family()/
-- pick_fuel_form()) -- es gibt kein statisch konfiguriertes "item" mehr.
-- Die Detailseite zeigt darum die zuletzt tatsaechlich gelieferte Sorte.
local function last_delivery_text(reactor)
  if not reactor.last_item then return "NOCH KEINE LIEFERUNG" end
  return tostring(reactor.last_item) .. " (" .. tostring(reactor.last_element or "?") .. ")"
end

local function footer(mon, h, w, center)
  return mux.footer_nav(mon, h, w, { center = center, inset = 3 })
end

function M.attach(instance, opts)
  if type(instance) ~= "table" then return instance end
  if instance._document_completion_attached then return instance end
  instance._document_completion_attached = true
  opts = opts or {}
  local devices = opts.devices or {}
  local state = { details_index = 1, details_prev = nil, details_next = nil }

  instance.compute_view_state = M.compute_view_state

  instance.render_overview = function(mon, model, should_clear)
    local w, h, view = render_header(mon, model, "FUEL NODE", "1/4", should_clear)
    local payload = model.payload or {}
    local logistics = payload.logistics or {}
    local reactors = logistics.reactors or {}
    local fuel_counts = logistics.fuel_data_summary or { fresh = 0, stale = 0, missing = 0 }
    local valve = payload.valve_summary or { total = 0, offline = 0, stale = 0 }

    if h >= 5 then
      local label = "> " .. tostring(view.title or view.code or "STATUS")
      if view.detail and w >= 48 then label = label .. ": " .. tostring(view.detail) end
      mux.banner(mon, 2, 5, math.max(1, w - 3), label, view.severity or "WARNING", nil)
    end

    local y = 7
    y = data_row(mon, w, h, y, { label = "ME BRIDGE", value = tostring(logistics.bridge or "MISSING"), status = logistics.bridge and "OK" or "WARNING", icon = "storage" })
    y = data_row(mon, w, h, y, { label = "RESERVE STORAGE", value = tostring(devices.storage_name or "MISSING"), status = devices.storage_name and "OK" or "WARNING", icon = "storage" })
    y = data_row(mon, w, h, y, { label = "MASTER", value = tostring(model.master_state or (payload.master_connected == false and "OFFLINE" or "ONLINE")), status = payload.master_connected == false and "WARNING" or "OK", icon = "master" })
    y = data_row(mon, w, h, y, {
      label = "RT DATA",
      value = string.format("F%d S%d M%d", tonumber(fuel_counts.fresh) or 0, tonumber(fuel_counts.stale) or 0, tonumber(fuel_counts.missing) or 0),
      status = ((tonumber(fuel_counts.stale) or 0) + (tonumber(fuel_counts.missing) or 0)) == 0 and "OK" or "WARNING", icon = "network"
    })
    y = data_row(mon, w, h, y, {
      label = "VALVES",
      value = string.format("%d total / %d off / %d stale", tonumber(valve.total) or 0, tonumber(valve.offline) or 0, tonumber(valve.stale) or 0),
      status = ((tonumber(valve.offline) or 0) + (tonumber(valve.stale) or 0)) == 0 and "OK" or "WARNING", icon = "network"
    })
    y = data_row(mon, w, h, y, { label = "LOGISTICS", value = logistics.enabled == true and "ACTIVE" or "DISABLED", status = logistics.enabled == true and "OK" or "LIMITED", icon = "config" })

    if y < h - 1 then
      local reserve = tonumber(payload.reserve) or 0
      local minimum = tonumber(payload.minimum_reserve) or 0
      local margin = reserve - minimum
      y = data_row(mon, w, h, y, {
        label = "RESERVE",
        value = string.format("%s / MIN %s / %s%s", short(reserve, "mB"), short(minimum, "mB"), margin >= 0 and "+" or "", short(margin, "mB")),
        status = margin >= 0 and "OK" or "WARNING", icon = "fuel"
      })
    end

    if #reactors == 0 and y < h - 1 then
      y = data_row(mon, w, h, y, {
        label = "NAECHSTER SCHRITT", value = "ROUTER > REAKTOR EINLERNEN",
        status = "LIMITED", icon = "config"
      })
    end

    if #reactors > 0 and y < h - 1 then
      local counts = logistics.operational_counts or {}
      y = data_row(mon, w, h, y, {
        label = "REAKTOREN",
        value = string.format("C%d R%d B%d S%d M%d",
          tonumber(counts.configured) or #reactors, tonumber(counts.ready) or 0,
          tonumber(counts.blocked) or 0, tonumber(counts.stale) or 0, tonumber(counts.missing) or 0),
        status = (tonumber(counts.ready) or 0) == #reactors and "OK" or "WARNING", icon = "reactor"
      })
      local shown = 0
      for _, reactor in ipairs(reactors) do
        if y >= h then break end
        y = data_row(mon, w, h, y, {
          label = tostring(reactor.label or reactor.reactor_id or "?"),
          value = fuel_text(reactor), status = severity_for_reactor(reactor), icon = "reactor"
        })
        shown = shown + 1
        if y >= h then break end
      end
      if shown < #reactors and y < h then
        data_row(mon, w, h, y, { label = "WEITERE", value = "+" .. tostring(#reactors - shown), status = "LIMITED", icon = "reactor" })
      end
    end

    return footer(mon, h, w, "FUEL OVERVIEW")
  end

  instance.render_details = function(mon, model, should_clear)
    local w, h = render_header(mon, model, "FUEL DETAILS", "2/4", should_clear)
    local logistics = (model.payload or {}).logistics or {}
    local reactors = logistics.reactors or {}
    if #reactors == 0 then
      if h >= 5 then mux.banner(mon, 2, 5, math.max(1, w - 3), "KEINE REAKTOREN KONFIGURIERT", "WARNING", nil) end
      if h >= 14 then
        mux.warning_box(mon, 2, 7, math.max(1, w - 3), {
          "Noch keine Reaktoren konfiguriert",
          "RT-Nodes online bringen, dann Seite 4 ROUTER oeffnen",
          "REAKTOR EINLERNEN antippen, gewuenschten Reaktor waehlen",
          "Danach Inlet, Pfad und Schwellwerte einstellen",
        }, "WARNING")
      elseif h >= 8 then
        mux.data_row(mon, 2, 7, math.max(1, w - 3), {
          label = "NAECHSTER SCHRITT", value = "ROUTER > EINLERNEN",
          status = "LIMITED", icon = "config"
        })
      end
      state.details_prev, state.details_next = nil, nil
      return footer(mon, h, w, "FUEL DETAILS")
    end

    state.details_index = math.max(1, math.min(state.details_index, #reactors))
    local reactor = reactors[state.details_index]
    if h >= 5 then
      mux.banner(mon, 2, 5, math.max(1, w - 3), string.format("REACTOR %d/%d · %s", state.details_index, #reactors, tostring(reactor.label or reactor.reactor_id or "?")), severity_for_reactor(reactor), nil)
    end

    if #reactors > 1 and h >= 6 then
      local prev_label = w >= 42 and "[ << REAKTOR ]" or "[ << ]"
      local next_label = w >= 42 and "[ REAKTOR >> ]" or "[ >> ]"
      mux.data_row(mon, 2, 6, math.max(1, w - 3), {
        label = state.details_index > 1 and prev_label or "",
        value = state.details_index < #reactors and next_label or "",
        status = "LIMITED", icon = "reactor"
      })
      state.details_prev = state.details_index > 1
        and { x1 = 2, x2 = math.min(w - 1, 3 + #prev_label), y = 6 } or nil
      state.details_next = state.details_index < #reactors
        and { x1 = math.max(2, w - #next_label - 2), x2 = w - 1, y = 6 } or nil
    else
      state.details_prev, state.details_next = nil, nil
    end

    local pct = type(reactor.fuel_pct) == "number" and (tostring(reactor.fuel_pct) .. "%") or "--"
    local age = reactor.fuel_age_s ~= nil and (tostring(reactor.fuel_age_s) .. "s") or "--"
    local inlet = tostring(reactor.inlet or reactor.configured_inlet or "MISSING")
    local last_item = last_delivery_text(reactor)
    local request = reactor.request_below and (tostring(math.floor(reactor.request_below * 100 + 0.5)) .. "%") or "?"
    local fill = reactor.fill_amount and tostring(reactor.fill_amount) or "?"
    local min_me = reactor.min_in_me and tostring(reactor.min_in_me) or "?"
    local delivery = tostring(reactor.delivery_state or reactor.operational_state or "?")
    local routing = tostring(reactor.route_state or "?")

    local y = 7
    if h <= 12 then
      y = data_row(mon, w, h, y, { label = "ID", value = tostring(reactor.reactor_id or "MISSING"), status = reactor.reactor_id and "text" or "WARNING", icon = "reactor" })
      y = data_row(mon, w, h, y, { label = "FUEL/DATA", value = pct .. " " .. tostring(reactor.fuel_data_state or "MISSING") .. " " .. age, status = reactor.fuel_data_state == "FRESH" and "OK" or "WARNING", icon = "fuel" })
      y = data_row(mon, w, h, y, { label = "STATE/ROUTE", value = delivery .. " / " .. routing, status = severity_for_reactor(reactor), icon = "network" })
      y = data_row(mon, w, h, y, { label = "IN/LETZTES", value = mux.fit(inlet .. " / " .. last_item, math.max(1, w - 12)), status = reactor.connected == true and "text" or "WARNING", icon = "storage" })
      data_row(mon, w, h, y, { label = "POLICY", value = "REQ<" .. request .. " F" .. fill .. " ME" .. min_me, status = "text", icon = "config" })
    elseif h < 19 then
      y = data_row(mon, w, h, y, { label = "ID", value = tostring(reactor.reactor_id or "MISSING"), status = reactor.reactor_id and "text" or "WARNING", icon = "reactor" })
      y = data_row(mon, w, h, y, { label = "FUEL", value = pct, status = reactor.fuel_data_state == "FRESH" and "OK" or "WARNING", icon = "fuel" })
      y = data_row(mon, w, h, y, { label = "DATA", value = tostring(reactor.fuel_data_state or "MISSING") .. " · " .. age .. " · " .. tostring(reactor.fuel_source or "-"), status = reactor.fuel_data_state == "FRESH" and "OK" or "WARNING", icon = "network" })
      y = data_row(mon, w, h, y, { label = "STATE/ROUTE", value = delivery .. " / " .. routing, status = severity_for_reactor(reactor), icon = "network" })
      y = data_row(mon, w, h, y, { label = "INLET", value = inlet, status = reactor.connected == true and "text" or "WARNING", icon = "storage" })
      y = data_row(mon, w, h, y, { label = "LETZTE LIEFERUNG", value = last_item, status = "text", icon = "fuel" })
      data_row(mon, w, h, y, { label = "POLICY", value = "REQ<" .. request .. " FILL " .. fill .. " ME " .. min_me, status = "text", icon = "config" })
    else
      y = data_row(mon, w, h, y, { label = "REACTOR ID", value = tostring(reactor.reactor_id or "MISSING"), status = reactor.reactor_id and "text" or "WARNING", icon = "reactor" })
      y = data_row(mon, w, h, y, { label = "FUEL", value = pct, status = reactor.fuel_data_state == "FRESH" and "OK" or "WARNING", icon = "fuel" })
      y = data_row(mon, w, h, y, { label = "FUEL DATA", value = tostring(reactor.fuel_data_state or "MISSING"), status = reactor.fuel_data_state == "FRESH" and "OK" or "WARNING", icon = "network" })
      y = data_row(mon, w, h, y, { label = "DATA AGE", value = age .. " / " .. tostring(reactor.fuel_source or "-"), status = reactor.fuel_data_state == "FRESH" and "OK" or "WARNING", icon = "network" })
      y = data_row(mon, w, h, y, { label = "STATE", value = delivery, status = severity_for_reactor(reactor), icon = "reactor" })
      y = data_row(mon, w, h, y, { label = "ROUTING", value = routing, status = route_severity(routing), icon = "network" })
      y = data_row(mon, w, h, y, { label = "INLET", value = inlet, status = reactor.connected == true and "text" or "WARNING", icon = "storage" })
      y = data_row(mon, w, h, y, { label = "LETZTE LIEFERUNG", value = last_item, status = "text", icon = "fuel" })
      y = data_row(mon, w, h, y, { label = "REQUEST BELOW", value = request, status = "text", icon = "config" })
      y = data_row(mon, w, h, y, { label = "FILL AMOUNT", value = fill, status = "text", icon = "config" })
      data_row(mon, w, h, y, { label = "ME MINIMUM", value = min_me, status = "text", icon = "config" })
    end

    return footer(mon, h, w, "FUEL DETAILS")
  end

  instance.handle_details_touch = function(x, y)
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return false end
    local function hit(button) return button and y == button.y and x >= button.x1 and x <= button.x2 end
    if hit(state.details_prev) then
      state.details_index = math.max(1, state.details_index - 1)
      return true
    end
    if hit(state.details_next) then
      state.details_index = state.details_index + 1
      return true
    end
    return false
  end

  instance.get_completion_state = function()
    return { details_index = state.details_index, details_prev = state.details_prev, details_next = state.details_next }
  end

  return instance
end

return M
