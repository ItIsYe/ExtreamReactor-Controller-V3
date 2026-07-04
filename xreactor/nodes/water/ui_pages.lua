local M = {}

local function fit(text, width)
  local s = tostring(text or "")
  local w = math.max(1, tonumber(width) or #s)
  if #s <= w then return s end
  if w <= 2 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "~"
end

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
  local colors = assert(opts.colors, "colors required")
  local support_ui_pages = assert(opts.support_ui_pages, "support_ui_pages required")
  local utils = opts.utils
  local config = opts.config or {}
  local devices = opts.devices or {}

  local function header(mon, model, title, page)
    local w, h = ui.getSize(mon)
    local status = model.status or "OK"
    ui.panel(mon, 1, 1, w, h, title, status)
    ui.text(mon, 2, 2, string.format("WATER NODE | %s", tostring(model.node_id or "?")), colors.get("text"), colors.get("background"))
    if page and w >= 30 then ui.rightText(mon, 2, 2, w - 2, page, colors.get("muted"), colors.get("background")) end
    return w, h, status
  end

  local function overview(mon, model)
    local w, h, status = header(mon, model, "WATER OVERVIEW", "SEITE 1/3")
    local p = model.payload or {}
    local total = tonumber(p.total_water) or 0
    local target = tonumber(config.target_volume) or 0
    local ratio = pct_from(total, target)
    local banner = status == "OK" and "WASSER NORMAL" or "WASSER WARNING"
    local key = status == "OK" and "OK" or "WARNING"
    local buffers = p.buffers or {}
    local clusters = p.clusters or {}
    local filling, draining = false, false
    for _, c in ipairs(clusters) do filling = filling or c.filling == true; draining = draining or c.draining == true end

    local y = 4
    ui.text(mon, 2, y, ">> " .. banner .. " <<", colors.get(key), colors.get("background")); y = y + 2
    if w >= 48 then
      ui.text(mon, 2, y, fit(string.format("GESAMT %s | TANKS %d | FUELLEN %s | ENTLEEREN %s | MASTER %s", short(total, "mB"), #buffers, filling and "AKTIV" or "AUTO", draining and "AKTIV" or "AUTO", tostring(model.master_state or "?")), w - 3), colors.get("text"), colors.get("background")); y = y + 2
    else
      ui.text(mon, 2, y, string.format("Gesamt %s  Tanks %d", short(total, "mB"), #buffers), colors.get("text"), colors.get("background")); y = y + 1
      ui.text(mon, 2, y, string.format("Master %s", tostring(model.master_state or "?")), colors.get("text"), colors.get("background")); y = y + 2
    end

    ui.text(mon, 2, y, string.format("GESAMT FUELLSTAND %s", ratio and string.format("%.0f%%", ratio * 100) or "n/a"), colors.get(key), colors.get("background")); y = y + 1
    ui.progress(mon, 2, y, math.max(8, w - 4), ratio or 0, key); y = y + 2

    local max_rows = math.max(1, h - y - 2)
    for i = 1, math.min(#buffers, max_rows) do
      local b = buffers[i]
      local name = tostring(b.id or ("TANK " .. i))
      local bpct = target > 0 and math.max(0, math.min(1, (tonumber(b.level) or 0) / target)) or 0
      local bkey = bpct < 0.15 and "WARNING" or "OK"
      if w >= 42 then
        ui.text(mon, 2, y, fit(string.format("%-16s %10s | %5.0f%%", name, short(b.level, "mB"), bpct * 100), w - 3), colors.get(bkey), colors.get("background"))
      else
        ui.text(mon, 2, y, fit(string.format("%s %s %.0f%%", name, short(b.level, "mB"), bpct * 100), w - 3), colors.get(bkey), colors.get("background"))
      end
      y = y + 1
      if y <= h - 2 then ui.progress(mon, 2, y, math.max(8, w - 4), bpct, bkey); y = y + 1 end
    end

    if h >= 3 then
      ui.text(mon, 2, h - 1, fit(string.format("CLUSTER %d | FILL %s | DRAIN %s | LAST SCAN %s", #clusters, filling and "ON" or "OFF", draining and "ON" or "OFF", tostring(model.last_scan or "-")), w - 3), colors.get("muted"), colors.get("background"))
    end
  end

  local function details(mon, model)
    local w, h = header(mon, model, "WATER DETAILS", "SEITE 2/3")
    local p = model.payload or {}
    local y = 4
    ui.text(mon, 2, y, "TANKS / CLUSTER", colors.get("LIMITED"), colors.get("background")); y = y + 2
    for _, c in ipairs(p.clusters or {}) do
      if y > h - 2 then break end
      local state = c.filling and "FILLING" or c.draining and "DRAINING" or "STABLE"
      local key = c.filling or c.draining and "LIMITED" or "OK"
      ui.text(mon, 2, y, fit(string.format("%-14s LEVEL %-9s MIN %-9s MAX %-9s %s", tostring(c.name or "?"), short(c.level), short(c.min), short(c.max), state), w - 3), colors.get(key), colors.get("background")); y = y + 1
    end
    if #(p.clusters or {}) == 0 then ui.text(mon, 2, y, "Keine Cluster konfiguriert.", colors.get("muted"), colors.get("background")); y = y + 1 end
    y = y + 1
    ui.text(mon, 2, y, fit(string.format("REGISTRY total:%d bound:%d missing:%d", model.summary.total or 0, model.summary.bound or 0, model.summary.missing or 0), w - 3), colors.get((model.summary.missing or 0) > 0 and "WARNING" or "text"), colors.get("background"))
  end

  local function diagnostics(mon, model)
    local w, h = header(mon, model, "WATER DIAGNOSTICS", "SEITE 3/3")
    local rows = support_ui_pages.common_diagnostic_rows(model, devices.discovery_failed)
    support_ui_pages.append_local_alert_rows(rows, model.local_alerts)
    ui.list(mon, 2, 4, w - 2, rows, { max_rows = math.max(1, h - 6) })
    if utils then support_ui_pages.render_log_mode_button(mon, utils, 1, h - 1, w - 2) end
  end

  local function diagnostics_touch(mon, x, y)
    if not utils then return false end
    local _, h = ui.getSize(mon)
    return support_ui_pages.handle_log_mode_touch(x, y, (h or 20) - 1, utils, 1)
  end

  return { render_overview = overview, render_details = details, render_diagnostics = diagnostics, handle_diagnostics_touch = diagnostics_touch }
end

return M
