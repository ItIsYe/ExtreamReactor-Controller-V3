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
      mux.status_dot(mon, math.floor(w * 0.38), 3, tostring(model.status or "OK"), status)
      mux.status_dot(mon, math.floor(w * 0.70), 3, "WATER LINK", status)
    end
    return mon.getSize()
  end

  local function section_arrow(mon, x, y, w, title, status, icon)
    mux.section(mon, x, y, w, "> " .. title, status, icon)
  end

  local function water_state(model, clusters)
    local filling, draining = false, false
    for _, c in ipairs(clusters or {}) do
      filling = filling or c.filling == true
      draining = draining or c.draining == true
    end
    if filling then return "WASSER WIRD GEFUELLT", "LIMITED", filling, draining end
    if draining then return "WASSER WIRD ENTLEERT", "LIMITED", filling, draining end
    if model.status == "OK" then return "WASSER NORMAL", "OK", filling, draining end
    return "WASSER WARNING", "WARNING", filling, draining
  end

  local function overview(mon, model)
    local w, h = header(mon, model, "WATER NODE", "1/3", "water")
    local p = model.payload or {}
    local total = tonumber(p.total_water) or 0
    local target = tonumber(config.target_volume) or 0
    local ratio = pct_from(total, target)
    local buffers = p.buffers or {}
    local clusters = p.clusters or {}
    local banner, key, filling, draining = water_state(model, clusters)

    mux.banner(mon, 2, 5, w - 3, "> " .. banner, key, nil)

    if w >= 54 then
      local gap = 1
      local cw = math.floor((w - 4 - gap * 2) / 3)
      mux.metric_card(mon, 2, 7, cw, 4, { label = "GESAMT", value = short(total, "mB"), status = key, icon = "water" })
      mux.metric_card(mon, 2 + cw + gap, 7, cw, 4, { label = "TANKS", value = tostring(#buffers), status = #buffers > 0 and "OK" or "WARNING", icon = "storage" })
      mux.metric_card(mon, 2 + (cw + gap) * 2, 7, cw, 4, { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" })
    else
      mux.kpi_strip(mon, 2, 7, w - 3, {
        { label = "GESAMT", value = short(total), status = key, icon = "water" },
        { label = "TANKS", value = tostring(#buffers), status = #buffers > 0 and "OK" or "WARNING", icon = "storage" },
        { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      })
    end

    section_arrow(mon, 2, 12, w - 3, "GESAMT FUELLSTAND", key, "water")
    mux.outlined_progress(mon, 2, 14, w - 3, ratio or 0, key, ratio and string.format("%.0f%%", ratio * 100) or "n/a")
    mux.data_row(mon, 2, 15, w - 3, { label = short(total, "mB") .. " / " .. short(target, "mB"), value = "TARGET", status = "text", icon = "storage" })

    if h >= 20 then
      local cw = math.floor((w - 5 - 3) / 4)
      local items = {
        { label = "CLUSTER", value = tostring(#clusters), status = "OK", icon = "network" },
        { label = "FILL", value = filling and "ON" or "OFF", status = filling and "LIMITED" or "OK", icon = "input" },
        { label = "DRAIN", value = draining and "ON" or "OFF", status = draining and "LIMITED" or "OK", icon = "output" },
        { label = "LAST SCAN", value = tostring(model.last_scan or "-"), status = "LIMITED", icon = "network" },
      }
      for i, item in ipairs(items) do
        mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 17, cw, 4, item)
      end
    end

    if h >= 25 then
      section_arrow(mon, 2, 22, w - 3, "TANK SNAPSHOT", "LIMITED", "storage")
      local b = buffers[1]
      mux.data_row(mon, 2, 24, w - 3, { label = b and tostring(b.id or "TANK 1") or "KEIN TANK", value = b and short(b.level, "mB") or "-", status = b and "OK" or "WARNING", icon = "storage" })
    end

    return mux.footer_nav(mon, h, w, { center = "WATER OVERVIEW" })
  end

  local function details(mon, model)
    local w, h = header(mon, model, "WATER DETAILS", "2/3", "storage")
    local p = model.payload or {}
    local clusters = p.clusters or {}
    local buffers = p.buffers or {}
    local _, _, filling, draining = water_state(model, clusters)

    local top = {
      { label = "TANKS", value = tostring(#buffers), status = #buffers > 0 and "OK" or "WARNING", icon = "storage" },
      { label = "CLUSTER", value = tostring(#clusters), status = "OK", icon = "network" },
      { label = "TOTAL", value = short(p.total_water, "mB"), status = "OK", icon = "water" },
      { label = "FLOW", value = filling and "FILL" or draining and "DRAIN" or "STABLE", status = (filling or draining) and "LIMITED" or "OK", icon = "flow" },
    }

    if w >= 54 then
      local cw = math.floor((w - 5 - 3) / 4)
      for i, item in ipairs(top) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 5, cw, 4, item) end
    else
      mux.kpi_strip(mon, 2, 5, w - 3, top)
    end

    section_arrow(mon, 2, 10, w - 3, "TANKS / CLUSTER", "LIMITED", "water")
    local y = 12
    for _, c in ipairs(clusters) do
      if y > h - 7 then break end
      local state = c.filling and "FILLING" or c.draining and "DRAINING" or "STABLE"
      local key = (c.filling or c.draining) and "LIMITED" or "OK"
      mux.card(mon, 2, y, w - 3, 6, { title = tostring(c.name or "CLUSTER") .. "   " .. state, status = key, icon = "water" })
      mux.kpi_strip(mon, 4, y + 1, w - 7, {
        { label = "LEVEL", value = short(c.level, "mB"), status = key, icon = "water" },
        { label = "MIN", value = short(c.min, "mB"), status = "LIMITED", icon = "input" },
        { label = "MAX", value = short(c.max, "mB"), status = "LIMITED", icon = "output" },
        { label = "STATE", value = state, status = key, icon = "flow" },
      })
      local span = (tonumber(c.max) or 0) - (tonumber(c.min) or 0)
      local cpct = span > 0 and math.max(0, math.min(1, ((tonumber(c.level) or 0) - (tonumber(c.min) or 0)) / span)) or 0
      mux.outlined_progress(mon, 4, y + 4, w - 7, cpct, key, state)
      y = y + 7
    end

    if #clusters == 0 then
      mux.warning_box(mon, 2, 12, w - 3, { "Keine Cluster konfiguriert", "Config pruefen" }, "WARNING")
    end

    return mux.footer_nav(mon, h, w, { center = "WATER DETAILS" })
  end

  local function diagnostics(mon, model)
    local w, h = header(mon, model, "WATER DIAGNOSTICS", "3/3", "network")
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
    return mux.footer_nav(mon, h, w, { center = "WATER DIAGNOSTICS" })
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
  }
end

return M
