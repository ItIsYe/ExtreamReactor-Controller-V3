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
    ui.text(mon, 2, 2, string.format("FUEL NODE | %s", tostring(model.node_id or "?")), colors.get("text"), colors.get("background"))
    if page and w >= 30 then ui.rightText(mon, 2, 2, w - 2, page, colors.get("muted"), colors.get("background")) end
    return w, h, status
  end

  local function overview(mon, model)
    local w, h, status = header(mon, model, "FUEL OVERVIEW", "SEITE 1/4")
    local p = model.payload or {}
    local reserve = tonumber(p.reserve) or 0
    local minimum = tonumber(p.minimum_reserve) or 0
    local target = math.max(minimum, reserve)
    local ratio = target > 0 and math.max(0, math.min(1, reserve / target)) or 0
    local key = reserve < minimum and "WARNING" or status == "OK" and "OK" or "WARNING"
    local banner = reserve < minimum and "RESERVE LOW" or "RESERVE NORMAL"
    local logistics = p.logistics or {}
    local routes_active = tonumber(logistics.active_routes or logistics.active or logistics.routes_active) or 0
    local routes_total = tonumber(logistics.total_routes or logistics.total or logistics.routes_total) or 0
    local y = 4

    ui.text(mon, 2, y, ">> " .. banner .. " <<", colors.get(key), colors.get("background")); y = y + 2
    if w >= 48 then
      ui.text(mon, 2, y, fit(string.format("RESERVE %s | MIN %s | ROUTEN %d/%d | MASTER %s", short(reserve, "mB"), short(minimum, "mB"), routes_active, routes_total, tostring(model.master_state or "?")), w - 3), colors.get("text"), colors.get("background")); y = y + 2
    else
      ui.text(mon, 2, y, string.format("Reserve %s", short(reserve, "mB")), colors.get("text"), colors.get("background")); y = y + 1
      ui.text(mon, 2, y, string.format("Minimum %s", short(minimum, "mB")), colors.get("text"), colors.get("background")); y = y + 2
    end
    ui.text(mon, 2, y, string.format("GESAMT RESERVE %.0f%%", ratio * 100), colors.get(key), colors.get("background")); y = y + 1
    ui.progress(mon, 2, y, math.max(8, w - 4), ratio, key); y = y + 2

    local sources = p.sources or {}
    ui.text(mon, 2, y, "QUELLEN & SPEICHER", colors.get("LIMITED"), colors.get("background")); y = y + 1
    local max_rows = math.max(1, h - y - 2)
    for i = 1, math.min(#sources, max_rows) do
      local s = sources[i]
      local amount = tonumber(s.amount) or 0
      local sr = reserve > 0 and math.max(0, math.min(1, amount / reserve)) or 0
      if w >= 42 then
        ui.text(mon, 2, y, fit(string.format("%-18s %10s | %5.0f%% | AKTIV", tostring(s.id or ("SOURCE " .. i)), short(amount, "mB"), sr * 100), w - 3), colors.get("OK"), colors.get("background"))
      else
        ui.text(mon, 2, y, fit(string.format("%s %s %.0f%%", tostring(s.id or i), short(amount, "mB"), sr * 100), w - 3), colors.get("OK"), colors.get("background"))
      end
      y = y + 1
    end
    if #sources == 0 then ui.text(mon, 2, y, "Keine Quelle gebunden.", colors.get("WARNING"), colors.get("background")) end
    if h >= 3 then ui.text(mon, 2, h - 1, fit(string.format("MASTER %s | AUTO MODE | VERTEILUNG | LAST SCAN %s", tostring(model.master_state or "?"), tostring(model.last_scan or "-")), w - 3), colors.get("muted"), colors.get("background")) end
  end

  local function details(mon, model)
    local w, h = header(mon, model, "FUEL DETAILS", "SEITE 2/4")
    local p = model.payload or {}
    local logistics = p.logistics or {}
    local y = 4
    ui.text(mon, 2, y, "LOGISTICS / ROUTES", colors.get("LIMITED"), colors.get("background")); y = y + 2
    local rows = {
      { text = string.format("Storage: %s", tostring(devices.storage_name or "none")) },
      { text = string.format("Reserve: %s", short(p.reserve, "mB")) },
      { text = string.format("Minimum: %s", short(p.minimum_reserve, "mB")) },
      { text = string.format("Router active:%s total:%s", tostring(logistics.active_routes or logistics.active or "n/a"), tostring(logistics.total_routes or logistics.total or "n/a")) },
      { text = string.format("Registry total:%d bound:%d missing:%d", model.summary.total or 0, model.summary.bound or 0, model.summary.missing or 0) },
      { text = string.format("Last scan: %s", tostring(model.last_scan or "-")) },
    }
    ui.list(mon, 2, y, w - 2, rows, { max_rows = math.max(1, h - y - 1) })
  end

  local function diagnostics(mon, model)
    local w, h = header(mon, model, "FUEL DIAGNOSTICS", "SEITE 3/4")
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
