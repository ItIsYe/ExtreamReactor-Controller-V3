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
-- nie von einem niedrigeren verdeckt werden, wie vom Dokument gefordert):
--   1. ERROR              -- Protokoll-Fehlanpassung mit Master (Comms
--                            grundlegend kaputt)
--   2. NO_CONFIG           -- keine Reaktoren konfiguriert
--   3. ROUTING_INVALID     -- Start-Ladevorgang der Routen fehlgeschlagen
--   4. VALVE_OFFLINE       -- mindestens ein konfiguriertes Ventil offline
--   5. NO_STORAGE          -- kein Speicher-Bus gebunden
--   6. NO_FRESH_RT_DATA    -- keine Master-Verbindung (naeherungsweise:
--                            ohne Master gibt es auch keine relayten
--                            RT-Fuellstandsdaten, siehe fuel_status_
--                            network.lua)
--   7. LOGISTICS_DISABLED  -- logistics.enabled == false
--   8. DELIVERING          -- gerade eine aktive Anfrage in Bearbeitung
--   9. READY               -- normaler, gesunder Betrieb
--  10. LOADING             -- noch keine erste Discovery abgeschlossen
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
    return { code = "NO_STORAGE", severity = "WARNING", title = "Kein Speicher gebunden", detail = "storage_bus nicht gefunden", action = "Wired Modem/ME Bridge pruefen" }
  end
  if payload.master_connected == false then
    return { code = "NO_FRESH_RT_DATA", severity = "WARNING", title = "Keine aktuellen Reaktordaten", detail = "Warte auf MASTER/RT-Status", action = "MASTER- und RT-Verbindung pruefen" }
  end
  if logistics.enabled == false then
    return { code = "LOGISTICS_DISABLED", severity = "LIMITED", title = "Logistik deaktiviert", detail = "logistics.enabled = false", action = "logistics.enabled auf true setzen, sobald bereit" }
  end
  -- Feature (2026-07-12): im Dokument nicht explizit in der Prioritaetsliste
  -- genannt, aber operativ wichtig genug (war der urspruengliche
  -- Haupt-Check, bevor LOGISTICS_DISABLED ergaenzt wurde) -- rangiert
  -- unterhalb der Infrastruktur-Probleme, aber oberhalb von DELIVERING/
  -- READY, da eine niedrige Reserve aktives Handeln erfordert.
  if reserve and minimum and reserve < minimum then
    return { code = "RESERVE_LOW", severity = "WARNING", title = "Reserve niedrig", detail = tostring(reserve) .. " < " .. tostring(minimum), action = "Nachschub sicherstellen" }
  end
  if logistics.current_request then
    return { code = "DELIVERING", severity = "LIMITED", title = "Lieferung aktiv", detail = tostring(logistics.current_request), action = nil }
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

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local support_ui_pages = assert(opts.support_ui_pages, "support_ui_pages required")
  local utils = opts.utils
  local devices = opts.devices or {}

  local function header(mon, model, title, page, icon, should_clear)
    local status = model.status or "OK"
    -- Fix (2026-07-11): UI-P0.6 (siehe docs/CODING_AI_FUEL_UI_PRIORITY_
    -- FIX_2026-07-12.md). mux.clear() loescht den KOMPLETTEN Monitor und
    -- wurde bisher bei JEDEM Render aufgerufen, auch fuer eine reine
    -- Datenaenderung (z.B. neuer Reservewert) -- sichtbares Flackern durch
    -- kurzzeitig leeren Bildschirm bei jedem Redraw. Jetzt nur noch bei
    -- Erstrender/Seiten-/Monitor-/Groessenwechsel (should_clear von
    -- core/ui_router.lua). mux.header() selbst fuellt Zeile 1-3 ohnehin
    -- bei jedem Aufruf neu (Titelleiste bleibt dadurch immer aktuell),
    -- und status_dot()/die restlichen hier verwendeten mux-Funktionen
    -- ueberschreiben ihre jeweilige Flaeche bereits vollstaendig selbst.
    if should_clear ~= false then mux.clear(mon) end
    mux.header(mon, { title = title, node_id = model.node_id or "FU-?", page = page, status = status, icon = icon or "fuel" })
    local w = ({ mon.getSize() })[1]
    if w >= 42 then
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING", 20)
      mux.status_dot(mon, math.floor(w * 0.38), 3, tostring(model.status or "OK"), status, 20)
      mux.status_dot(mon, math.floor(w * 0.70), 3, "FUEL LINK", status, 16)
    end
    return mon.getSize()
  end

  local function section_arrow(mon, x, y, w, title, status, icon)
    mux.section(mon, x, y, w, "> " .. title, status, icon)
  end

  local function fuel_state(model, reserve, minimum)
    -- Fix (2026-07-12): REST-P1.3. view_state wird jetzt zentral einmal
    -- in monitor_ui.lua's build_model() berechnet (siehe dortiger
    -- Kommentar) -- hier nur noch lesen, nicht mehr neu berechnen, damit
    -- garantiert derselbe Wert wie bei Ampel/Diagnostics verwendet wird.
    -- Fallback fuer den (theoretischen) Fall, dass view_state fehlt.
    local vs = model.view_state or M.compute_view_state(model, devices, reserve, minimum)
    local label = vs.title
    if vs.detail then label = label .. ": " .. vs.detail end
    return label, vs.severity
  end

  local function overview(mon, model, should_clear)
    local w, h = header(mon, model, "FUEL NODE", "1/4", "fuel", should_clear)
    local p = model.payload or {}
    local reserve = tonumber(p.reserve) or 0
    local minimum = tonumber(p.minimum_reserve) or 0
    local target = math.max(minimum, reserve, 1)
    local ratio = math.max(0, math.min(1, reserve / target))
    local logistics = p.logistics or {}
    local routes_active = tonumber(logistics.active_routes or logistics.active or logistics.routes_active) or 0
    local routes_total = tonumber(logistics.total_routes or logistics.total or logistics.routes_total) or 0
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

    section_arrow(mon, 2, 12, w - 3, "FUEL RESERVE", key, "fuel")
    mux.outlined_progress(mon, 2, 14, w - 3, ratio, key, string.format("%.0f%%", ratio * 100))
    mux.data_row(mon, 2, 15, w - 3, { label = short(reserve, "mB") .. " / MIN " .. short(minimum, "mB"), value = "RESERVE", status = "text", icon = "storage" })

    if h >= 20 then
      local cw = math.floor((w - 5 - 3) / 4)
      local items = {
        { label = "ROUTEN", value = string.format("%d/%d", routes_active, routes_total), status = routes_active > 0 and "OK" or "LIMITED", icon = "network" },
        { label = "STORAGE", value = devices.storage_name and "ONLINE" or "MISSING", status = devices.storage_name and "OK" or "WARNING", icon = "storage" },
        { label = "MODE", value = "AUTO", status = "OK", icon = "config" },
        { label = "SOURCE", value = tostring(#(p.sources or {})), status = #(p.sources or {}) > 0 and "OK" or "WARNING", icon = "fuel" },
      }
      for i, item in ipairs(items) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 17, cw, 4, item) end
    end

    if h >= 25 then
      section_arrow(mon, 2, 22, w - 3, "QUELLEN & SPEICHER", "LIMITED", "storage")
      local source = (p.sources or {})[1]
      mux.data_row(mon, 2, 24, w - 3, { label = source and tostring(source.id or "SOURCE") or "KEINE QUELLE", value = source and short(source.amount, "mB") or "-", status = source and "OK" or "WARNING", icon = "fuel" })
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

    local top = {
      { label = "RESERVE", value = short(reserve, "mB"), status = reserve_key, icon = "fuel" },
      { label = "MIN", value = short(minimum, "mB"), status = "LIMITED", icon = "storage" },
      { label = "BOUND", value = tostring(summary.bound or 0), status = "OK", icon = "network" },
      { label = "MISSING", value = tostring(summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "warning" },
    }

    if w >= 54 then
      local cw = math.floor((w - 5 - 3) / 4)
      for i, item in ipairs(top) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 5, cw, 4, item) end
    else
      mux.kpi_strip(mon, 2, 5, w - 3, top)
    end

    section_arrow(mon, 2, 10, w - 3, "LOGISTICS / ROUTES", "LIMITED", "network")

    if w >= 58 then
      local left_w = math.floor((w - 5) / 2)
      local right_x = 3 + left_w
      local right_w = w - right_x - 1

      mux.card(mon, 2, 12, left_w, math.max(9, h - 13), { title = "STORAGE", status = devices.storage_name and "OK" or "WARNING", icon = "storage" })
      mux.data_row(mon, 4, 14, left_w - 4, { label = "NAME", value = tostring(devices.storage_name or "none"), status = devices.storage_name and "OK" or "WARNING", icon = "storage" })
      mux.data_row(mon, 4, 15, left_w - 4, { label = "RESERVE", value = short(reserve, "mB"), status = reserve_key, icon = "fuel" })
      mux.data_row(mon, 4, 16, left_w - 4, { label = "MINIMUM", value = short(minimum, "mB"), status = "LIMITED", icon = "storage" })
      mux.data_row(mon, 4, 17, left_w - 4, { label = "LAST SCAN", value = tostring(model.last_scan or "-"), status = "text", icon = "network" })

      mux.card(mon, right_x, 12, right_w, math.max(9, h - 13), { title = "ROUTER SUMMARY", status = "LIMITED", icon = "network" })
      mux.data_row(mon, right_x + 2, 14, right_w - 4, { label = "ACTIVE", value = tostring(logistics.active_routes or logistics.active or "n/a"), status = "OK", icon = "network" })
      mux.data_row(mon, right_x + 2, 15, right_w - 4, { label = "TOTAL", value = tostring(logistics.total_routes or logistics.total or "n/a"), status = "text", icon = "network" })
      mux.data_row(mon, right_x + 2, 16, right_w - 4, { label = "MODE", value = "AUTO", status = "OK", icon = "config" })
      mux.data_row(mon, right_x + 2, 17, right_w - 4, { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" })
    else
      mux.data_row(mon, 2, 12, w - 3, { label = "Storage", value = tostring(devices.storage_name or "none"), status = devices.storage_name and "OK" or "WARNING", icon = "storage" })
      mux.data_row(mon, 2, 13, w - 3, { label = "Active routes", value = tostring(logistics.active_routes or logistics.active or "n/a"), status = "OK", icon = "network" })
      mux.data_row(mon, 2, 14, w - 3, { label = "Total routes", value = tostring(logistics.total_routes or logistics.total or "n/a"), status = "text", icon = "network" })
      mux.data_row(mon, 2, 15, w - 3, { label = "Last scan", value = tostring(model.last_scan or "-"), status = "LIMITED", icon = "network" })
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
      local cw = math.floor((w - 5 - 3) / 4)
      for i, item in ipairs(top) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 5, cw, 4, item) end
    else
      mux.kpi_strip(mon, 2, 5, w - 3, top)
    end

    local rows = support_ui_pages.common_diagnostic_rows(model, devices.discovery_failed)
    support_ui_pages.append_local_alert_rows(rows, alerts)
    -- Feature (2026-07-12): REST-P1.3. Derselbe view_state, der auch
    -- Header/Banner/Ampel steuert, jetzt auch explizit als eigene
    -- Diagnostics-Zeile sichtbar.
    if model.view_state then
      rows[#rows + 1] = {
        text = "VIEW-STATE: " .. tostring(model.view_state.code) .. (model.view_state.action and (" -- " .. model.view_state.action) or ""),
        status = model.view_state.severity or "text",
      }
    end
    -- Feature (2026-07-12): REST-P1.1. UI-Renderfehler (error_count/
    -- last_error, vom shared ui_router ueber build_model() ins Model
    -- uebernommen) waren bisher nirgends auf der Diagnostics-Seite
    -- sichtbar, obwohl sie intern schon korrekt verfolgt wurden.
    local uidiag = model.ui_diagnostics
    if uidiag and (uidiag.error_count or 0) > 0 then
      local le = uidiag.last_error or {}
      local age_txt = le.ts and support_ui_pages.format_age(le.ts, os.epoch("utc")) or "?"
      rows[#rows + 1] = {
        text = string.format("UI-FEHLER x%d (zuletzt: %s/%s vor %s)", uidiag.error_count, tostring(le.page or "?"), tostring(le.code or "?"), age_txt),
        status = "WARNING",
      }
    end

    if w >= 58 then
      local left_w = math.floor((w - 5) / 2)
      local right_x = 3 + left_w
      local right_w = w - right_x - 1

      mux.card(mon, 2, 10, left_w, math.max(9, h - 11), { title = "SYSTEM INFO", status = "LIMITED", icon = "network" })
      mux.data_row(mon, 4, 12, left_w - 4, { label = "REGISTRY", value = string.format("%d/%d/%d", summary.total or 0, summary.bound or 0, summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "network" })
      mux.data_row(mon, 4, 13, left_w - 4, { label = "LAST SCAN", value = tostring(model.last_scan or "-"), status = "LIMITED", icon = "network" })
      mux.data_row(mon, 4, 14, left_w - 4, { label = "COMMAND", value = tostring(model.last_command or "none"), status = "text", icon = "config" })
      mux.data_row(mon, 4, 15, left_w - 4, { label = "DISCOVERY", value = devices.discovery_failed and "FAILED" or "OK", status = devices.discovery_failed and "WARNING" or "OK", icon = "network" })

      mux.card(mon, right_x, 10, right_w, math.max(9, h - 11), { title = "DIAGNOSTIC EVENTS", status = #alerts > 0 and "WARNING" or "OK", icon = "warning" })
      local y = 12
      for i = 1, math.min(#rows, math.max(0, h - y - 2)) do
        local r = rows[i]
        mux.data_row(mon, right_x + 2, y, right_w - 4, { label = tostring(r.text or ""), value = "", status = r.status or "text", icon = "network" })
        y = y + 1
      end
    else
      section_arrow(mon, 2, 10, w - 3, "SYSTEM DIAGNOSTICS", "LIMITED", "network")
      local y = 12
      for i = 1, math.min(#rows, math.max(0, h - y - 1)) do
        local r = rows[i]
        mux.data_row(mon, 2, y, w - 3, { label = tostring(r.text or ""), value = "", status = r.status or "text", icon = "network" })
        y = y + 1
      end
    end

    if utils then support_ui_pages.render_log_mode_button(mon, utils, 1, h - 1, w - 2) end
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
    -- Feature (2026-07-12): REST-P1.3. Damit render_ampel() (das ein
    -- eigenes, minimales Model unabhaengig von overview()/fuel_state()
    -- aufbaut) denselben priorisierten view_state verwenden kann statt
    -- einer eigenen, abweichenden Logik.
    compute_view_state = M.compute_view_state,
  }
end

return M
