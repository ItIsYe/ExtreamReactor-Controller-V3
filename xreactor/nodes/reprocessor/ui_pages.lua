local M = {}
local mux = require("core.mockup_ui")

local function short(value, suffix)
  local n = tonumber(value)
  if not n then return "n/a" end
  local a = math.abs(n)
  if a >= 1000000 then return string.format("%.1fM%s", n / 1000000, suffix or "") end
  if a >= 1000 then return string.format("%.1fk%s", n / 1000, suffix or "") end
  return string.format("%.0f%s", n, suffix or "")
end

local function state_key(state)
  local s = tostring(state or "unknown")
  if s == "ok" then return "OK" end
  if s == "error" then return "EMERGENCY" end
  if s == "unsupported" then return "WARNING" end
  return "LIMITED"
end

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local support_ui_pages = assert(opts.support_ui_pages, "support_ui_pages required")
  local utils = opts.utils
  local devices = opts.devices or {}

  local function header(mon, model, title, page, icon)
    local status = model.status or "OK"
    mux.clear(mon)
    mux.header(mon, { title = title, node_id = model.node_id or "RP-?", page = page, status = status, icon = icon or "recycle" })
    local w = ({ mon.getSize() })[1]
    if w >= 42 then
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING")
      mux.status_dot(mon, math.floor(w * 0.42), 3, tostring(model.status or "OK"), status)
      mux.status_dot(mon, math.floor(w * 0.72), 3, "PROCESS LINK", status)
    end
    return mon.getSize()
  end

  local function totals(payload)
    local stored, capacity, active = 0, 0, 0
    local buffers = payload.buffers or {}
    for _, b in ipairs(buffers) do
      stored = stored + (tonumber(b.stored) or 0)
      capacity = capacity + (tonumber(b.capacity) or 0)
      if b.process_state == "ok" then active = active + 1 end
    end
    return stored, capacity, active, buffers
  end

  local function overview(mon, model)
    local w, h = header(mon, model, "REPROCESSING NODE", "SEITE 1/4", "recycle")
    local p = model.payload or {}
    local stored, capacity, active, buffers = totals(p)
    local ratio = capacity > 0 and math.max(0, math.min(1, stored / capacity)) or 0
    local feed = p.feed or {}
    local routes_active = tonumber(feed.active_routes or feed.active or feed.routes_active) or 0
    local routes_total = tonumber(feed.total_routes or feed.total or feed.routes_total) or 0
    local key = p.standby and "LIMITED" or model.status == "OK" and "OK" or "WARNING"
    local banner = p.standby and "AUFBEREITUNG STANDBY" or model.status == "OK" and "AUFBEREITUNG NORMAL" or "AUFBEREITUNG WARNING"
    mux.banner(mon, 2, 5, w - 3, banner, key, "recycle")

    if w >= 54 and h >= 18 then
      local gap = 1
      local cw = math.floor((w - 4 - gap * 2) / 3)
      mux.metric_card(mon, 2, 7, cw, 4, { label = "BUFFER", value = string.format("%.0f%%", ratio * 100), status = key, icon = "storage" })
      mux.metric_card(mon, 2 + cw + gap, 7, cw, 4, { label = "LINIEN", value = string.format("%d/%d", active, #buffers), status = active > 0 and "OK" or "LIMITED", icon = "recycle" })
      mux.metric_card(mon, 2 + (cw + gap) * 2, 7, cw, 4, { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" })
      mux.section(mon, 2, 12, w - 3, "PUFFER AUSLASTUNG", key, "storage")
      mux.outlined_progress(mon, 2, 14, w - 3, ratio, key, string.format("%.0f%%", ratio * 100))
      mux.kpi_strip(mon, 2, 16, w - 3, {
        { label = "STORED", value = short(stored), status = key, icon = "storage" },
        { label = "CAPACITY", value = short(capacity), status = "LIMITED", icon = "storage" },
        { label = "ROUTEN", value = string.format("%d/%d", routes_active, routes_total), status = routes_active > 0 and "OK" or "LIMITED", icon = "network" },
        { label = "MODE", value = p.standby and "STANDBY" or "ACTIVE", status = key, icon = "config" },
      })
    else
      mux.kpi_strip(mon, 2, 7, w - 3, {
        { label = "BUFFER", value = string.format("%.0f%%", ratio * 100), status = key, icon = "storage" },
        { label = "LINIEN", value = string.format("%d/%d", active, #buffers), status = "OK", icon = "recycle" },
        { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      })
      mux.section(mon, 2, 10, w - 3, "PUFFER", key, "storage")
      mux.outlined_progress(mon, 2, 12, w - 3, ratio, key, string.format("%.0f%%", ratio * 100))
    end

    if h >= 20 then
      mux.section(mon, 2, h - 4, w - 3, "VERARBEITUNGSLINIEN", "LIMITED", "recycle")
      local b = buffers[1]
      mux.data_row(mon, 2, h - 2, w - 3, { label = b and tostring(b.id or "LINE 1") or "Keine Linie", value = b and tostring(b.process_state or "unknown"):upper() or "-", status = b and state_key(b.process_state) or "WARNING", icon = "recycle" })
    end
    mux.footer_nav(mon, h, w, { center = "REPROCESSING" })
  end

  local function details(mon, model)
    local w, h = header(mon, model, "REPROCESSING DETAILS", "SEITE 2/4", "recycle")
    local p = model.payload or {}
    local _, _, _, buffers = totals(p)
    mux.kpi_strip(mon, 2, 5, w - 3, {
      { label = "BUFFER", value = tostring(#buffers), status = #buffers > 0 and "OK" or "WARNING", icon = "storage" },
      { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      { label = "STANDBY", value = p.standby and "YES" or "NO", status = p.standby and "LIMITED" or "OK", icon = "config" },
      { label = "SCAN", value = tostring(model.last_scan or "-"), status = "LIMITED", icon = "network" },
    })
    mux.section(mon, 2, 8, w - 3, "BUFFER / PROCESS STATE", "LIMITED", "recycle")
    local y = 10
    for _, b in ipairs(buffers) do
      if y > h - 5 then break end
      local key = state_key(b.process_state)
      mux.card(mon, 2, y, w - 3, 4, { title = tostring(b.id or "BUFFER"), status = key, icon = "recycle" })
      mux.data_row(mon, 4, y + 1, w - 7, { label = "STORED " .. short(b.stored), value = "CAP " .. short(b.capacity), status = key, icon = "storage" })
      mux.data_row(mon, 4, y + 2, w - 7, { label = "FILL " .. (b.percent and string.format("%.1f%%", b.percent) or "n/a"), value = tostring(b.process_state or "unknown"):upper(), status = key, icon = "recycle" })
      y = y + 5
    end
    if #buffers == 0 then mux.warning_box(mon, 2, 10, w - 3, { "Keine Buffer gefunden", "Discovery / Binding pruefen" }, "WARNING") end
    mux.footer_nav(mon, h, w, { center = "PROCESS DETAILS" })
  end

  local function diagnostics(mon, model)
    local w, h = header(mon, model, "REPROCESSING DIAGNOSTICS", "SEITE 3/4", "network")
    local summary = model.summary or {}
    mux.kpi_strip(mon, 2, 5, w - 3, {
      { label = "HEALTH", value = tostring(model.status or "OK"), status = model.status or "OK", icon = "ok" },
      { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      { label = "MISSING", value = tostring(summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "warning" },
      { label = "SCAN", value = tostring(model.last_scan or "-"), status = "LIMITED", icon = "network" },
    })
    mux.section(mon, 2, 8, w - 3, "SYSTEM DIAGNOSTICS", "LIMITED", "network")
    local rows = support_ui_pages.common_diagnostic_rows(model, devices.discovery_failed)
    support_ui_pages.append_local_alert_rows(rows, model.local_alerts)
    local y = 10
    for i = 1, math.min(#rows, math.max(0, h - y - 1)) do
      local r = rows[i]
      mux.data_row(mon, 2, y, w - 3, { label = tostring(r.text or ""), value = "", status = r.status or "text", icon = "network" })
      y = y + 1
    end
    if utils then support_ui_pages.render_log_mode_button(mon, utils, 1, h - 1, w - 2) end
    mux.footer_nav(mon, h, w, { center = "DIAGNOSTICS" })
  end

  local function diagnostics_touch(mon, x, y)
    if not utils then return false end
    local _, h = ui.getSize(mon)
    return support_ui_pages.handle_log_mode_touch(x, y, (h or 20) - 1, utils, 1)
  end

  return { render_overview = overview, render_details = details, render_diagnostics = diagnostics, handle_diagnostics_touch = diagnostics_touch }
end

return M
