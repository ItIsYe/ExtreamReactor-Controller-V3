local M = {}
local mux = require("core.mockup_ui")

-- Feature (2026-07-12): REST-P1.3 (siehe docs/CODING_AI_FUEL_UI_PRIORITY_
-- FIX_2026-07-12.md). Bisher entschieden Header, Hauptbanner, Ampel und
-- Diagnostics JEWEILS UNABHAENGIG voneinander, welcher Zustand gerade
-- vorliegt (z.B. fuel_state() kannte nur RESERVE-bezogene Zustaende,
-- die Ampel kannte "LIMITED" fuer eine aktive Lieferung, Diagnostics
-- kannte wieder andere Werte) -- die Anzeigen konnten sich dadurch
-- inhaltlich widersprechen. Ab jetzt EINE priorisierte Funktion, deren
-- Ergebnis alle vier Stellen gemeinsam nutzen.
--
-- Prioritaet (hoechste zuerst -- ein sicherheitsrelevanter Zustand darf
-- nie von einem niedrigeren verdeckt werden):
--   ERROR / NO_CONFIG / ROUTING_INVALID / VALVE_OFFLINE / NO_STORAGE /
--   NO_FRESH_RT_DATA / LOGISTICS_DISABLED / NO_ME_BRIDGE /
--   LOGISTICS_BLOCKED / RESERVE_LOW / DELIVERING / READY / LOADING
function M.compute_view_state(model, devices, reserve, minimum)
  local payload = model.payload or {}
  local logistics = payload.logistics or {}
  local bindings = payload.bindings or {}

  if not devices or devices.last_scan_ts == nil then
    return { code = "LOADING", severity = "LIMITED", title = "Lade...", detail = "Erste Discovery laeuft noch", action = nil }
  end
  if payload.protocol_mismatch then
    return { code = "ERROR", severity = "WARNING", title = "Protokoll-Fehler", detail = "Versions-Mismatch mit MASTER", action = "Alle Nodes auf dieselbe Version aktualisieren" }
  end
  local reactor_count = #(logistics.reactors or {})
  if reactor_count == 0 then
    return { code = "NO_CONFIG", severity = "LIMITED", title = "Keine Reaktoren konfiguriert", detail = "logistics.reactors ist leer", action = "Reaktoren in der Konfiguration eintragen" }
  end
  if payload.routing_load_status and payload.routing_load_status.ok == false then
    return { code = "ROUTING_INVALID", severity = "WARNING", title = "Routing ungueltig", detail = tostring(payload.routing_load_status.message or payload.routing_load_status.code or "?"), action = "fuel_routes.lua pruefen/neu speichern" }
  end
  if payload.valve_summary and (payload.valve_summary.offline or 0) > 0 then
    return { code = "VALVE_OFFLINE", severity = "WARNING", title = "Ventil offline", detail = payload.valve_summary.offline .. " von " .. payload.valve_summary.total .. " Ventilen nicht erreichbar", action = "VALVE-Node(s) pruefen" }
  end
  if (bindings.storage or 0) == 0 then
    return { code = "NO_STORAGE", severity = "WARNING", title = "Kein Speicher gebunden", detail = "storage_bus nicht gefunden", action = "Wired Modem/Storage pruefen" }
  end
  if payload.master_connected == false then
    return { code = "NO_FRESH_RT_DATA", severity = "WARNING", title = "Keine aktuellen Reaktordaten", detail = "Warte auf MASTER/RT-Status", action = "MASTER- und RT-Verbindung pruefen" }
  end
  if logistics.enabled == false then
    return { code = "LOGISTICS_DISABLED", severity = "LIMITED", title = "Logistik deaktiviert", detail = "logistics.enabled = false", action = "logistics.enabled auf true setzen, sobald bereit" }
  end
  if logistics.bridge == nil then
    return { code = "NO_ME_BRIDGE", severity = "WARNING", title = "ME Bridge fehlt", detail = "Keine betriebsbereite ME Bridge erkannt", action = "ME Bridge und Wired Modem pruefen" }
  end
  local blocked_reactors = {}
  for _, reactor in ipairs(logistics.reactors or {}) do
    if type(reactor) == "table" and reactor.connected ~= true then
      blocked_reactors[#blocked_reactors + 1] = tostring(reactor.label or reactor.reactor_id or "?")
    end
  end
  if #blocked_reactors > 0 then
    return {
      code = "LOGISTICS_BLOCKED", severity = "WARNING", title = "Lieferweg blockiert",
      detail = table.concat(blocked_reactors, ", "),
      action = "reactor_id und Inlet-Peripheral pruefen"
    }
  end
  local missing_fuel_data = {}
  for _, reactor in ipairs(logistics.reactors or {}) do
    if type(reactor) == "table" and type(reactor.fuel_pct) ~= "number" then
      missing_fuel_data[#missing_fuel_data + 1] = tostring(reactor.label or reactor.reactor_id or "?")
    end
  end
  if #missing_fuel_data > 0 then
    return {
      code = "NO_FRESH_RT_DATA", severity = "WARNING", title = "Reaktordaten fehlen",
      detail = table.concat(missing_fuel_data, ", "),
      action = "MASTER-/RT-Status und reactor_id pruefen"
    }
  end
  if reserve and minimum and reserve < minimum then
    return { code = "RESERVE_LOW", severity = "WARNING", title = "Reserve niedrig", detail = tostring(reserve) .. " < " .. tostring(minimum), action = "Nachschub sicherstellen" }
  end
  if logistics.current_request then
    local req = logistics.current_request
    local detail = type(req) == "table" and tostring(req.label or req.reactor_id or req.state or "aktiv") or tostring(req)
    return { code = "DELIVERING", severity = "LIMITED", title = "Lieferung aktiv", detail = detail, action = nil }
  end
  return { code = "READY", severity = "OK", title = "Bereit", detail = nil, action = nil }
end

local function short(value, suffix)
  local n = tonumber(value)
  if not n then return "n/a" end
  local a = math.abs(n)
  if a >= 1000000 then return string.format("%.1fM%s", n / 1000000, suffix or "") end
  if a >= 1000 then return string.format("%.1fk%s", n / 1000, suffix or "") end
  return string.format("%.0f%s", n, suffix or "")
end

local function logistics_counts(logistics)
  local total, ready, stale, blocked = 0, 0, 0, 0
  local bridge_ok = logistics and logistics.bridge ~= nil
  for _, reactor in ipairs((logistics or {}).reactors or {}) do
    total = total + 1
    if not bridge_ok or reactor.connected ~= true then
      blocked = blocked + 1
    elseif type(reactor.fuel_pct) ~= "number" then
      stale = stale + 1
    else
      ready = ready + 1
    end
  end
  return { total = total, ready = ready, stale = stale, blocked = blocked, bridge_ok = bridge_ok }
end

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local support_ui_pages = assert(opts.support_ui_pages, "support_ui_pages required")
  local utils = opts.utils
  local devices = opts.devices or {}
  local config = opts.config or {}

  local function header(mon, model, title, page, icon, should_clear)
    local view_state = model.view_state
    local status = view_state and view_state.severity or model.status or "OK"
    local status_label = view_state and view_state.code or model.status or "OK"
    if should_clear == true then mux.clear(mon) end
    mux.header(mon, { title = title, node_id = model.node_id or "FU-?", page = page, status = status, icon = icon or "fuel" })
    local w = ({ mon.getSize() })[1]
    if w >= 66 then
      local cell = math.floor((w - 3) / 3)
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING", cell)
      mux.status_dot(mon, 2 + cell, 3, tostring(status_label), status, cell)
      mux.status_dot(mon, 2 + cell * 2, 3, "FUEL LINK", status, math.max(1, w - (2 + cell * 2)))
    elseif w >= 42 then
      local cell = math.floor((w - 3) / 2)
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING", cell)
      mux.status_dot(mon, 2 + cell, 3, tostring(status_label), status, math.max(1, w - (2 + cell)))
    end
    return mon.getSize()
  end

  local function section_arrow(mon, x, y, w, title, status, icon)
    mux.section(mon, x, y, w, "> " .. title, status, icon)
  end

  local function fuel_state(model, reserve, minimum)
    local vs = model.view_state or M.compute_view_state(model, devices, reserve, minimum)
    local label = vs.title
    if vs.detail then label = label .. ": " .. vs.detail end
    return label, vs.severity
  end

  local function reactor_config_for(reactor)
    local lg = config.logistics or {}
    for _, entry in ipairs(lg.reactors or {}) do
      local rid = entry.reactor_id or entry.reactor_port
      local label = entry.name or entry.label
      if (rid and reactor.reactor_id and tostring(rid) == tostring(reactor.reactor_id))
          or (label and reactor.label and tostring(label) == tostring(reactor.label)) then
        return entry
      end
    end
    return {}
  end

  local function reactor_state(reactor, logistics)
    if reactor.connected ~= true then return "BLOCKED", "WARNING" end
    if type(reactor.fuel_pct) ~= "number" then return "STALE", "WARNING" end
    local req = logistics and logistics.current_request
    if type(req) == "table" then
      if (req.reactor_id and reactor.reactor_id and tostring(req.reactor_id) == tostring(reactor.reactor_id))
          or (req.label and reactor.label and tostring(req.label) == tostring(reactor.label)) then
        return "DELIVERING", "LIMITED"
      end
    end
    local rcfg = reactor_config_for(reactor)
    local threshold = tonumber(rcfg.request_below)
    if threshold and reactor.fuel_pct < threshold * 100 then return "REQUEST", "LIMITED" end
    return "READY", "OK"
  end

  local function reactor_value(reactor, logistics, detailed)
    local state = reactor_state(reactor, logistics)
    local fuel = type(reactor.fuel_pct) == "number" and (tostring(reactor.fuel_pct) .. "%") or "--"
    if not detailed then return fuel .. "  " .. state end
    local rcfg = reactor_config_for(reactor)
    local item = tostring(rcfg.item or "?")
    local inlet = tostring(reactor.inlet or rcfg.inlet or "no-inlet")
    local threshold = tonumber(rcfg.request_below)
    local fill = tonumber(rcfg.fill_amount)
    local min_me = tonumber(rcfg.min_in_me)
    local policy = string.format("REQ<%s F%s ME%s",
      threshold and tostring(math.floor(threshold * 100 + 0.5)) .. "%" or "?",
      fill and tostring(fill) or "?", min_me and tostring(min_me) or "?")
    return fuel .. " " .. state .. " | " .. inlet .. " | " .. item .. " | " .. policy
  end

  local function overview(mon, model, should_clear)
    local w, h = header(mon, model, "FUEL NODE", "1/4", "fuel", should_clear)
    local p = model.payload or {}
    local reserve = tonumber(p.reserve) or 0
    local minimum = tonumber(p.minimum_reserve) or 0
    local logistics = p.logistics or {}
    local counts = logistics_counts(logistics)
    local banner, key = fuel_state(model, reserve, minimum)

    mux.banner(mon, 2, 5, w - 3, "> " .. banner, key, nil)

    if w >= 54 then
      local gap = 1
      local cw = math.floor((w - 4 - gap * 2) / 3)
      mux.metric_card(mon, 2, 7, cw, 4, { label = "RESERVE", value = short(reserve, "mB"), status = key, icon = "fuel" })
      mux.metric_card(mon, 2 + cw + gap, 7, cw, 4, { label = "MINIMUM", value = short(minimum, "mB"), status = "LIMITED", icon = "storage" })
      mux.metric_card(mon, 2 + (cw + gap) * 2, 7, cw, 4, { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" })
    else
      mux.kpi_strip(mon, 2, 7, w - 3, {
        { label = "RESERVE", value = short(reserve), status = key, icon = "fuel" },
        { label = "MIN", value = short(minimum), status = "LIMITED", icon = "storage" },
        { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      })
    end

    -- Compact monitors keep the essential verdict/KPIs plus footer. Avoid
    -- writing fixed y=12..24 sections beyond the physical screen.
    if h < 17 then
      return mux.footer_nav(mon, h, w, { center = "FUEL OVERVIEW" })
    end

    section_arrow(mon, 2, 12, w - 3, "FUEL RESERVE", key, "fuel")
    local margin = reserve - minimum
    mux.data_row(mon, 2, 14, w - 3, { label = "RESERVE", value = short(reserve, "mB"), status = key, icon = "fuel" })
    mux.data_row(mon, 2, 15, w - 3, { label = "MINIMUM", value = short(minimum, "mB"), status = "LIMITED", icon = "storage" })
    mux.data_row(mon, 2, 16, w - 3, { label = "MARGIN", value = (margin >= 0 and "+" or "") .. short(margin, "mB"), status = margin >= 0 and "OK" or "WARNING", icon = "fuel" })

    if h >= 21 then
      local cw = math.max(5, math.floor((w - 8) / 4))
      local logistics_enabled = logistics.enabled == true
      local items = {
        { label = "READY", value = string.format("%d/%d", counts.ready, counts.total), status = counts.total > 0 and counts.ready == counts.total and "OK" or "WARNING", icon = "reactor" },
        { label = "ME BRIDGE", value = counts.bridge_ok and "ONLINE" or "MISSING", status = counts.bridge_ok and "OK" or "WARNING", icon = "storage" },
        { label = "LOGISTICS", value = logistics_enabled and "ACTIVE" or "DISABLED", status = logistics_enabled and "OK" or "LIMITED", icon = "config" },
        { label = "RT DATA", value = counts.stale == 0 and "FRESH" or (tostring(counts.stale) .. " STALE"), status = counts.stale == 0 and "OK" or "WARNING", icon = "network" },
      }
      if w >= 40 then
        for i, item in ipairs(items) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 17, cw, 4, item) end
      end
    end

    if h >= 25 then
      section_arrow(mon, 2, 22, w - 3, "REAKTOREN", counts.blocked + counts.stale > 0 and "WARNING" or "OK", "reactor")
      local y = 24
      for _, reactor in ipairs(logistics.reactors or {}) do
        if y >= h then break end
        local state, status = reactor_state(reactor, logistics)
        mux.data_row(mon, 2, y, w - 3, {
          label = tostring(reactor.label or reactor.reactor_id or "?"),
          value = reactor_value(reactor, logistics, false), status = status, icon = "reactor"
        })
        y = y + 1
      end
    end

    return mux.footer_nav(mon, h, w, { center = "FUEL OVERVIEW" })
  end

  local function details(mon, model, should_clear)
    local w, h = header(mon, model, "FUEL DETAILS", "2/4", "network", should_clear)
    local p = model.payload or {}
    local logistics = p.logistics or {}
    local summary = model.summary or {}
    local reserve = tonumber(p.reserve) or 0
    local minimum = tonumber(p.minimum_reserve) or 0
    local _, reserve_key = fuel_state(model, reserve, minimum)
    local counts = logistics_counts(logistics)

    local top = {
      { label = "RESERVE", value = short(reserve, "mB"), status = reserve_key, icon = "fuel" },
      { label = "MIN", value = short(minimum, "mB"), status = "LIMITED", icon = "storage" },
      { label = "BOUND", value = tostring(summary.bound or 0), status = "OK", icon = "network" },
      { label = "MISSING", value = tostring(summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "warning" },
    }

    if w >= 54 then
      local cw = math.max(5, math.floor((w - 8) / 4))
      for i, item in ipairs(top) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 5, cw, 4, item) end
    else
      mux.kpi_strip(mon, 2, 5, w - 3, top)
    end

    if h < 16 then
      mux.data_row(mon, 2, math.min(10, h - 2), w - 3, {
        label = "ME / LOGISTICS",
        value = tostring(logistics.bridge or "none") .. " / " .. (logistics.enabled == true and "ACTIVE" or "DISABLED"),
        status = counts.bridge_ok and logistics.enabled == true and "OK" or "WARNING", icon = "network"
      })
      return mux.footer_nav(mon, h, w, { center = "FUEL DETAILS" })
    end

    section_arrow(mon, 2, 10, w - 3, "LOGISTICS / REACTORS", "LIMITED", "network")

    if w >= 58 and h >= 18 then
      local left_w = math.floor((w - 5) / 2)
      local right_x = 3 + left_w
      local right_w = w - right_x - 1
      local card_h = math.max(5, h - 13)

      mux.card(mon, 2, 12, left_w, card_h, { title = "INFRASTRUCTURE", status = counts.bridge_ok and "OK" or "WARNING", icon = "storage" })
      if card_h >= 3 then mux.data_row(mon, 4, 14, left_w - 4, { label = "ME BRIDGE", value = tostring(logistics.bridge or "none"), status = counts.bridge_ok and "OK" or "WARNING", icon = "storage" }) end
      if card_h >= 4 then mux.data_row(mon, 4, 15, left_w - 4, { label = "STORAGE", value = tostring(devices.storage_name or "none"), status = devices.storage_name and "OK" or "WARNING", icon = "storage" }) end
      if card_h >= 5 then mux.data_row(mon, 4, 16, left_w - 4, { label = "RESERVE", value = short(reserve, "mB"), status = reserve_key, icon = "fuel" }) end
      if card_h >= 6 then mux.data_row(mon, 4, 17, left_w - 4, { label = "LAST SCAN", value = tostring(model.last_scan or "-"), status = "text", icon = "network" }) end

      mux.card(mon, right_x, 12, right_w, card_h, { title = "REAKTOREN", status = counts.blocked == 0 and counts.stale == 0 and "OK" or "WARNING", icon = "reactor" })
      local y = 14
      local max_y = 12 + card_h - 1
      for _, reactor in ipairs(logistics.reactors or {}) do
        if y > max_y then break end
        local _, status = reactor_state(reactor, logistics)
        mux.data_row(mon, right_x + 2, y, right_w - 4, {
          label = tostring(reactor.label or reactor.reactor_id or "?"),
          value = mux.fit(reactor_value(reactor, logistics, true), math.max(1, right_w - 8)),
          status = status, icon = "reactor"
        })
        y = y + 1
      end
    else
      mux.data_row(mon, 2, 12, w - 3, { label = "ME Bridge", value = tostring(logistics.bridge or "none"), status = counts.bridge_ok and "OK" or "WARNING", icon = "storage" })
      mux.data_row(mon, 2, 13, w - 3, { label = "Ready", value = string.format("%d/%d", counts.ready, counts.total), status = counts.ready == counts.total and counts.total > 0 and "OK" or "WARNING", icon = "reactor" })
      mux.data_row(mon, 2, 14, w - 3, { label = "Stale/Blocked", value = string.format("%d/%d", counts.stale, counts.blocked), status = (counts.stale + counts.blocked) > 0 and "WARNING" or "OK", icon = "warning" })
      mux.data_row(mon, 2, 15, w - 3, { label = "Logistics", value = logistics.enabled == true and "ACTIVE" or "DISABLED", status = logistics.enabled == true and "OK" or "LIMITED", icon = "config" })
    end

    return mux.footer_nav(mon, h, w, { center = "FUEL DETAILS" })
  end

  local function diagnostics(mon, model, should_clear)
    local w, h = header(mon, model, "FUEL DIAGNOSTICS", "3/4", "network", should_clear)
    local summary = model.summary or {}
    local alerts = model.local_alerts or {}
    local top = {
      { label = "HEALTH", value = tostring(model.status or "OK"), status = model.status or "OK", icon = "ok" },
      { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      { label = "MISSING", value = tostring(summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "warning" },
      { label = "ALARMS", value = tostring(#alerts), status = #alerts > 0 and "WARNING" or "OK", icon = "warning" },
    }

    if w >= 54 then
      local cw = math.max(5, math.floor((w - 8) / 4))
      for i, item in ipairs(top) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 5, cw, 4, item) end
    else
      mux.kpi_strip(mon, 2, 5, w - 3, top)
    end

    local rows = support_ui_pages.common_diagnostic_rows(model, devices.discovery_failed)
    support_ui_pages.append_local_alert_rows(rows, alerts)
    local uidiag = model.ui_diagnostics
    if model.view_state then
      rows[#rows + 1] = {
        text = "VIEW-STATE: " .. tostring(model.view_state.code) .. (model.view_state.action and (" -- " .. model.view_state.action) or ""),
        status = model.view_state.severity or "text",
      }
    end
    if uidiag then
      rows[#rows + 1] = {
        text = string.format("UI: frames %d/%d/%d clears=%d trans=%d ptr=%d model=%d %dms",
          uidiag.frames_committed or 0, uidiag.frames_skipped or 0, uidiag.frames_requested or 0,
          uidiag.full_clears or 0, uidiag.transition_count or 0, uidiag.pointer_events_received or 0,
          uidiag.model_builds or 0, uidiag.last_render_ms or 0),
        status = "text",
      }
    end
    if uidiag and (uidiag.error_count or 0) > 0 then
      local le = uidiag.last_error or {}
      local age_txt = le.ts and support_ui_pages.format_age(le.ts, os.epoch("utc")) or "?"
      rows[#rows + 1] = {
        text = string.format("UI-FEHLER x%d (zuletzt: %s/%s vor %s)", uidiag.error_count, tostring(le.page or "?"), tostring(le.code or "?"), age_txt),
        status = "WARNING",
      }
    end

    if w >= 58 and h >= 18 then
      local left_w = math.floor((w - 5) / 2)
      local right_x = 3 + left_w
      local right_w = w - right_x - 1
      local card_h = math.max(5, h - 11)

      mux.card(mon, 2, 10, left_w, card_h, { title = "SYSTEM INFO", status = "LIMITED", icon = "network" })
      if card_h >= 3 then mux.data_row(mon, 4, 12, left_w - 4, { label = "REGISTRY", value = string.format("%d/%d/%d", summary.total or 0, summary.bound or 0, summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "network" }) end
      if card_h >= 4 then mux.data_row(mon, 4, 13, left_w - 4, { label = "LAST SCAN", value = tostring(model.last_scan or "-"), status = "LIMITED", icon = "network" }) end
      if card_h >= 5 then mux.data_row(mon, 4, 14, left_w - 4, { label = "COMMAND", value = tostring(model.last_command or "none"), status = "text", icon = "config" }) end
      if card_h >= 6 then mux.data_row(mon, 4, 15, left_w - 4, { label = "DISCOVERY", value = devices.discovery_failed and "FAILED" or "OK", status = devices.discovery_failed and "WARNING" or "OK", icon = "network" }) end

      mux.card(mon, right_x, 10, right_w, card_h, { title = "DIAGNOSTIC EVENTS", status = #alerts > 0 and "WARNING" or "OK", icon = "warning" })
      local y = 12
      local max_y = 10 + card_h - 1
      for i = 1, #rows do
        if y > max_y then break end
        local r = rows[i]
        mux.data_row(mon, right_x + 2, y, right_w - 4, { label = tostring(r.text or ""), value = "", status = r.status or "text", icon = "network" })
        y = y + 1
      end
    else
      if h >= 11 then section_arrow(mon, 2, 10, w - 3, "SYSTEM DIAGNOSTICS", "LIMITED", "network") end
      local y = 12
      for i = 1, #rows do
        if y >= h - 1 then break end
        local r = rows[i]
        mux.data_row(mon, 2, y, w - 3, { label = tostring(r.text or ""), value = "", status = r.status or "text", icon = "network" })
        y = y + 1
      end
    end

    if utils and h >= 3 then support_ui_pages.render_log_mode_button(mon, utils, 1, h - 1, w - 2) end
    return mux.footer_nav(mon, h, w, { center = "FUEL DIAGNOSTICS" })
  end

  local function diagnostics_touch(mon, x, y)
    if not utils then return false end
    local _, h = ui.getSize(mon)
    return support_ui_pages.handle_log_mode_touch(x, y, (h or 20) - 1, utils, 1)
  end

  return {
    render_overview = overview,
    render_details = details,
    render_diagnostics = diagnostics,
    handle_diagnostics_touch = diagnostics_touch,
    compute_view_state = M.compute_view_state,
  }
end

return M
