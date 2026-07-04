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

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local colors = assert(opts.colors, "colors required")
  local support_ui_pages = assert(opts.support_ui_pages, "support_ui_pages required")
  local utils = opts.utils
  local devices = opts.devices or {}

  local function header(mon, model, title, page)
    local w, h = ui.getSize(mon)
    local status = model.status or "OK"
    ui.panel(mon, 1, 1, w, h, title, status)
    ui.text(mon, 2, 2, string.format("REPROCESSING NODE | %s", tostring(model.node_id or "?")), colors.get("text"), colors.get("background"))
    if page and w >= 34 then ui.rightText(mon, 2, 2, w - 2, page, colors.get("muted"), colors.get("background")) end
    return w, h, status
  end

  local function overview(mon, model)
    local w, h, status = header(mon, model, "REPROCESSING OVERVIEW", "SEITE 1/4")
    local p = model.payload or {}
    local buffers = p.buffers or {}
    local feed = p.feed or {}
    local stored, capacity, active = 0, 0, 0
    for _, b in ipairs(buffers) do
      stored = stored + (tonumber(b.stored) or 0)
      capacity = capacity + (tonumber(b.capacity) or 0)
      if b.process_state == "ok" then active = active + 1 end
    end
    local ratio = capacity > 0 and math.max(0, math.min(1, stored / capacity)) or 0
    local key = status == "OK" and "OK" or "WARNING"
    local banner = p.standby and "AUFBEREITUNG STANDBY" or status == "OK" and "AUFBEREITUNG NORMAL" or "AUFBEREITUNG WARNING"
    local routes_active = tonumber(feed.active_routes or feed.active or feed.routes_active) or 0
    local routes_total = tonumber(feed.total_routes or feed.total or feed.routes_total) or 0
    local y = 4

    ui.text(mon, 2, y, ">> " .. banner .. " <<", colors.get(p.standby and "LIMITED" or key), colors.get("background")); y = y + 2
    if w >= 52 then
      ui.text(mon, 2, y, fit(string.format("ABFALL PUFFER %.0f%% | VERARBEITUNG %s | LINIEN %d/%d | ROUTEN %d/%d | MASTER %s", ratio * 100, p.standby and "STANDBY" or "AKTIV", active, #buffers, routes_active, routes_total, tostring(model.master_state or "?")), w - 3), colors.get("text"), colors.get("background")); y = y + 2
    else
      ui.text(mon, 2, y, string.format("Puffer %.0f%%  Linien %d/%d", ratio * 100, active, #buffers), colors.get("text"), colors.get("background")); y = y + 1
      ui.text(mon, 2, y, string.format("Master %s", tostring(model.master_state or "?")), colors.get("text"), colors.get("background")); y = y + 2
    end

    ui.text(mon, 2, y, string.format("PUFFER AUSLASTUNG %.0f%%  %s/%s", ratio * 100, short(stored), short(capacity)), colors.get(key), colors.get("background")); y = y + 1
    ui.progress(mon, 2, y, math.max(8, w - 4), ratio, key); y = y + 2
    ui.text(mon, 2, y, "VERARBEITUNGSLINIEN", colors.get("LIMITED"), colors.get("background")); y = y + 1

    local max_rows = math.max(1, h - y - 2)
    for i = 1, math.min(#buffers, max_rows) do
      local b = buffers[i]
      local state = tostring(b.process_state or "unknown")
      local bkey = state == "ok" and "OK" or state == "error" and "EMERGENCY" or state == "unsupported" and "WARNING" or "LIMITED"
      local br = tonumber(b.percent) and math.max(0, math.min(1, tonumber(b.percent) / 100)) or 0
      if w >= 46 then
        ui.text(mon, 2, y, fit(string.format("%02d %-18s | %-11s | STORED %-9s | %5.0f%%", i, tostring(b.id or "?"), state:upper(), short(b.stored), br * 100), w - 3), colors.get(bkey), colors.get("background"))
      else
        ui.text(mon, 2, y, fit(string.format("%02d %s %s %.0f%%", i, tostring(b.id or "?"), state:upper(), br * 100), w - 3), colors.get(bkey), colors.get("background"))
      end
      y = y + 1
    end
    if #buffers == 0 then ui.text(mon, 2, y, "Keine Buffer gefunden.", colors.get("WARNING"), colors.get("background")) end
    if h >= 3 then ui.text(mon, 2, h - 1, fit(string.format("DURCHSATZ STATUS | FEED ROUTES %d/%d | LAST SCAN %s", routes_active, routes_total, tostring(model.last_scan or "-")), w - 3), colors.get("muted"), colors.get("background")) end
  end

  local function details(mon, model)
    local w, h = header(mon, model, "REPROCESSING DETAILS", "SEITE 2/4")
    local p = model.payload or {}
    local y = 4
    ui.text(mon, 2, y, "BUFFER / PROCESS STATE", colors.get("LIMITED"), colors.get("background")); y = y + 2
    for _, b in ipairs(p.buffers or {}) do
      if y > h - 2 then break end
      local state = tostring(b.process_state or "unknown")
      local key = state == "ok" and "OK" or state == "error" and "EMERGENCY" or "WARNING"
      ui.text(mon, 2, y, fit(string.format("%-18s STORED %-9s CAP %-9s FILL %-6s PROCESS %s", tostring(b.id or "?"), short(b.stored), short(b.capacity), b.percent and string.format("%.1f%%", b.percent) or "n/a", state), w - 3), colors.get(key), colors.get("background")); y = y + 1
    end
  end

  local function diagnostics(mon, model)
    local w, h = header(mon, model, "REPROCESSING DIAGNOSTICS", "SEITE 3/4")
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
