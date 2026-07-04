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

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local support_ui_pages = assert(opts.support_ui_pages, "support_ui_pages required")
  local utils = opts.utils
  local devices = opts.devices or {}

  local function header(mon, model, title, page, icon)
    local status = model.status or "OK"
    mux.clear(mon)
    mux.header(mon, { title = title, node_id = model.node_id or "FU-?", page = page, status = status, icon = icon or "fuel" })
    local w = ({ mon.getSize() })[1]
    if w >= 42 then
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING")
      mux.status_dot(mon, math.floor(w * 0.42), 3, tostring(model.status or "OK"), status)
      mux.status_dot(mon, math.floor(w * 0.72), 3, "FUEL LINK", status)
    end
    return mon.getSize()
  end

  local function overview(mon, model)
    local w, h = header(mon, model, "FUEL NODE", "SEITE 1/4", "fuel")
    local p = model.payload or {}
    local reserve = tonumber(p.reserve) or 0
    local minimum = tonumber(p.minimum_reserve) or 0
    local target = math.max(minimum, reserve, 1)
    local ratio = math.max(0, math.min(1, reserve / target))
    local logistics = p.logistics or {}
    local routes_active = tonumber(logistics.active_routes or logistics.active or logistics.routes_active) or 0
    local routes_total = tonumber(logistics.total_routes or logistics.total or logistics.routes_total) or 0
    local key = reserve < minimum and "WARNING" or model.status == "OK" and "OK" or "WARNING"
    mux.banner(mon, 2, 5, w - 3, reserve < minimum and "RESERVE LOW" or "RESERVE NORMAL", key, "fuel")

    if w >= 54 and h >= 18 then
      local gap = 1
      local cw = math.floor((w - 4 - gap * 2) / 3)
      mux.metric_card(mon, 2, 7, cw, 4, { label = "RESERVE", value = short(reserve, "mB"), status = key, icon = "fuel" })
      mux.metric_card(mon, 2 + cw + gap, 7, cw, 4, { label = "MINIMUM", value = short(minimum, "mB"), status = "LIMITED", icon = "storage" })
      mux.metric_card(mon, 2 + (cw + gap) * 2, 7, cw, 4, { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" })
      mux.section(mon, 2, 12, w - 3, "FUEL RESERVE", key, "fuel")
      mux.outlined_progress(mon, 2, 14, w - 3, ratio, key, string.format("%.0f%%", ratio * 100))
      mux.kpi_strip(mon, 2, 16, w - 3, {
        { label = "ROUTEN", value = string.format("%d/%d", routes_active, routes_total), status = routes_active > 0 and "OK" or "LIMITED", icon = "network" },
        { label = "STORAGE", value = tostring(devices.storage_name or "none"), status = devices.storage_name and "OK" or "WARNING", icon = "storage" },
        { label = "MODE", value = "AUTO", status = "OK", icon = "config" },
        { label = "SOURCE", value = tostring(#(p.sources or {})), status = "OK", icon = "fuel" },
      })
    else
      mux.kpi_strip(mon, 2, 7, w - 3, {
        { label = "RESERVE", value = short(reserve), status = key, icon = "fuel" },
        { label = "MIN", value = short(minimum), status = "LIMITED", icon = "storage" },
        { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      })
      mux.section(mon, 2, 10, w - 3, "RESERVE", key, "fuel")
      mux.outlined_progress(mon, 2, 12, w - 3, ratio, key, string.format("%.0f%%", ratio * 100))
    end

    if h >= 20 then
      mux.section(mon, 2, h - 4, w - 3, "QUELLEN & SPEICHER", "LIMITED", "storage")
      local source = (p.sources or {})[1]
      mux.data_row(mon, 2, h - 2, w - 3, { label = source and tostring(source.id or "SOURCE") or "Keine Quelle", value = source and short(source.amount, "mB") or "-", status = source and "OK" or "WARNING", icon = "fuel" })
    end
    mux.footer_nav(mon, h, w, { center = "FUEL OVERVIEW" })
  end

  local function details(mon, model)
    local w, h = header(mon, model, "FUEL DETAILS", "SEITE 2/4", "network")
    local p = model.payload or {}
    local logistics = p.logistics or {}
    local summary = model.summary or {}
    mux.kpi_strip(mon, 2, 5, w - 3, {
      { label = "RESERVE", value = short(p.reserve, "mB"), status = "OK", icon = "fuel" },
      { label = "MIN", value = short(p.minimum_reserve, "mB"), status = "LIMITED", icon = "storage" },
      { label = "BOUND", value = tostring(summary.bound or 0), status = "OK", icon = "network" },
      { label = "MISSING", value = tostring(summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "warning" },
    })
    mux.section(mon, 2, 8, w - 3, "LOGISTICS / ROUTES", "LIMITED", "network")
    mux.data_row(mon, 2, 10, w - 3, { label = "Storage", value = tostring(devices.storage_name or "none"), status = devices.storage_name and "OK" or "WARNING", icon = "storage" })
    mux.data_row(mon, 2, 11, w - 3, { label = "Active routes", value = tostring(logistics.active_routes or logistics.active or "n/a"), status = "OK", icon = "network" })
    mux.data_row(mon, 2, 12, w - 3, { label = "Total routes", value = tostring(logistics.total_routes or logistics.total or "n/a"), status = "text", icon = "network" })
    mux.data_row(mon, 2, 13, w - 3, { label = "Last scan", value = tostring(model.last_scan or "-"), status = "LIMITED", icon = "network" })
    mux.footer_nav(mon, h, w, { center = "FUEL DETAILS" })
  end

  local function diagnostics(mon, model)
    local w, h = header(mon, model, "FUEL DIAGNOSTICS", "SEITE 3/4", "network")
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
