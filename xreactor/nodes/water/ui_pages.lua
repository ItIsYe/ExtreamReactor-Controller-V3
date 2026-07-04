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

local function pct_from(value, target)
  local v, t = tonumber(value), tonumber(target)
  if not v or not t or t <= 0 then return nil end
  return math.max(0, math.min(1, v / t))
end

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local support_ui_pages = assert(opts.support_ui_pages, "support_ui_pages required")
  local utils = opts.utils
  local config = opts.config or {}
  local devices = opts.devices or {}

  local function header(mon, model, title, page, icon)
    local status = model.status or "OK"
    mux.clear(mon)
    mux.header(mon, { title = title, node_id = model.node_id or "WA-?", page = page, status = status, icon = icon or "water" })
    local w = ({ mon.getSize() })[1]
    if w >= 42 then
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING")
      mux.status_dot(mon, math.floor(w * 0.42), 3, tostring(model.status or "OK"), status)
      mux.status_dot(mon, math.floor(w * 0.72), 3, "WATER LINK", status)
    end
    return mon.getSize()
  end

  local function overview(mon, model)
    local w, h = header(mon, model, "WATER NODE", "SEITE 1/3", "water")
    local p = model.payload or {}
    local total = tonumber(p.total_water) or 0
    local target = tonumber(config.target_volume) or 0
    local ratio = pct_from(total, target)
    local buffers = p.buffers or {}
    local clusters = p.clusters or {}
    local filling, draining = false, false
    for _, c in ipairs(clusters) do filling = filling or c.filling == true; draining = draining or c.draining == true end
    local key = model.status == "OK" and "OK" or "WARNING"
    local banner = filling and "WASSER WIRD GEFUELLT" or draining and "WASSER WIRD ENTLEERT" or model.status == "OK" and "WASSER NORMAL" or "WASSER WARNING"
    mux.banner(mon, 2, 5, w - 3, banner, (filling or draining) and "LIMITED" or key, "water")

    if w >= 54 and h >= 18 then
      local gap = 1
      local cw = math.floor((w - 4 - gap * 2) / 3)
      mux.metric_card(mon, 2, 7, cw, 4, { label = "GESAMT", value = short(total, "mB"), status = key, icon = "water" })
      mux.metric_card(mon, 2 + cw + gap, 7, cw, 4, { label = "TANKS", value = tostring(#buffers), status = #buffers > 0 and "OK" or "WARNING", icon = "storage" })
      mux.metric_card(mon, 2 + (cw + gap) * 2, 7, cw, 4, { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" })
      mux.section(mon, 2, 12, w - 3, "GESAMT FUELLSTAND", key, "water")
      mux.outlined_progress(mon, 2, 14, w - 3, ratio or 0, key, ratio and string.format("%.0f%%", ratio * 100) or "n/a")
      mux.kpi_strip(mon, 2, 16, w - 3, {
        { label = "CLUSTER", value = tostring(#clusters), status = "OK", icon = "network" },
        { label = "FILL", value = filling and "ON" or "OFF", status = filling and "LIMITED" or "OK", icon = "input" },
        { label = "DRAIN", value = draining and "ON" or "OFF", status = draining and "LIMITED" or "OK", icon = "output" },
        { label = "TARGET", value = short(target, "mB"), status = "LIMITED", icon = "storage" },
      })
    else
      mux.kpi_strip(mon, 2, 7, w - 3, {
        { label = "GESAMT", value = short(total), status = key, icon = "water" },
        { label = "TANKS", value = tostring(#buffers), status = "OK", icon = "storage" },
        { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      })
      mux.section(mon, 2, 10, w - 3, "FUELLSTAND", key, "water")
      mux.outlined_progress(mon, 2, 12, w - 3, ratio or 0, key, ratio and string.format("%.0f%%", ratio * 100) or "n/a")
    end

    if h >= 20 then
      mux.section(mon, 2, h - 4, w - 3, "TANK SNAPSHOT", "LIMITED", "storage")
      local b = buffers[1]
      mux.data_row(mon, 2, h - 2, w - 3, { label = b and tostring(b.id or "Tank A") or "Kein Tank", value = b and short(b.level, "mB") or "-", status = b and "OK" or "WARNING", icon = "storage" })
    end
    mux.footer_nav(mon, h, w, { center = "WATER OVERVIEW" })
  end

  local function details(mon, model)
    local w, h = header(mon, model, "WATER DETAILS", "SEITE 2/3", "storage")
    local p = model.payload or {}
    local clusters = p.clusters or {}
    local buffers = p.buffers or {}
    mux.kpi_strip(mon, 2, 5, w - 3, {
      { label = "TANKS", value = tostring(#buffers), status = #buffers > 0 and "OK" or "WARNING", icon = "storage" },
      { label = "CLUSTER", value = tostring(#clusters), status = "OK", icon = "network" },
      { label = "TOTAL", value = short(p.total_water, "mB"), status = "OK", icon = "water" },
      { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
    })
    mux.section(mon, 2, 8, w - 3, "TANKS / CLUSTER", "LIMITED", "water")
    local y = 10
    for _, c in ipairs(clusters) do
      if y > h - 5 then break end
      local state = c.filling and "FILLING" or c.draining and "DRAINING" or "STABLE"
      local key = (c.filling or c.draining) and "LIMITED" or "OK"
      mux.card(mon, 2, y, w - 3, 4, { title = tostring(c.name or "CLUSTER"), status = key, icon = "water" })
      mux.data_row(mon, 4, y + 1, w - 7, { label = "LEVEL " .. short(c.level), value = state, status = key, icon = "water" })
      mux.data_row(mon, 4, y + 2, w - 7, { label = "MIN " .. short(c.min), value = "MAX " .. short(c.max), status = "text" })
      y = y + 5
    end
    if #clusters == 0 then mux.warning_box(mon, 2, 10, w - 3, { "Keine Cluster konfiguriert", "Config pruefen" }, "WARNING") end
    mux.footer_nav(mon, h, w, { center = "WATER DETAILS" })
  end

  local function diagnostics(mon, model)
    local w, h = header(mon, model, "WATER DIAGNOSTICS", "SEITE 3/3", "network")
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
