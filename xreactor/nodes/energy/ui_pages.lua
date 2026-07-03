local M = {}
local support_ui_pages = require("nodes.support.ui_pages")
local ok_ampel_mod, ampel_mod = pcall(require, "optional.ampel")
local ampel_instance = ok_ampel_mod and type(ampel_mod) == "table" and type(ampel_mod.new) == "function" and ampel_mod.new() or nil

local function format_energy(value)
  if value == nil then return "n/a" end
  local suffixes = { "", "k", "M", "G", "T", "P", "E" }
  local v, idx = math.abs(value), 1
  while v >= 1000 and idx < #suffixes do v = v / 1000; idx = idx + 1 end
  local out = (v >= 100 and string.format("%.0f", v) or string.format("%.1f", v)) .. suffixes[idx]
  return value < 0 and ("-" .. out) or out
end

local function format_percent(value)
  if value == nil then return "n/a" end
  return string.format("%.0f%%", value * 100)
end

local function format_age(ts, now)
  if not ts then return "n/a" end
  return ("%ds"):format(math.max(0, math.floor((now - ts) / 1000)))
end

local function fit(text, width)
  local s = tostring(text or "")
  local w = math.max(1, tonumber(width) or #s)
  if #s <= w then return s end
  if w <= 2 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "~"
end

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local colors = assert(opts.colors, "colors required")
  local ui_router = assert(opts.ui_router, "ui_router required")
  local ui_state = assert(opts.ui_state, "ui_state required")
  local utils = opts.utils

  local function render_header(mon, title, status, model, page_text)
    local w, h = ui.getSize(mon)
    if not w or not h then return end
    ui.panel(mon, 1, 1, w, h, title, status)
    ui.text(mon, 2, 2, ("ENERGY NODE | %s"):format(model.node_id or "UNKNOWN"), colors.get("text"), colors.get("background"))
    if page_text and w >= 30 then
      ui.rightText(mon, 2, 2, w - 2, page_text, colors.get("muted"), colors.get("background"))
    else
      ui.rightText(mon, 2, 2, w - 2, model.health_status or status, colors.get(status), colors.get("background"))
    end
    if model.local_alerts_critical and model.local_alerts_critical > 0 then
      local label = "CRIT " .. tostring(model.local_alerts_critical)
      ui.badge(mon, math.max(2, w - (#label + 2)), 1, label, "EMERGENCY")
    end
  end

  local function storage_banner(model)
    local total = model.total or {}
    local pct = tonumber(total.percent)
    if model.degraded then return "STORAGE WARNING", "WARNING" end
    if pct == nil then return "STORAGE UNKNOWN", "muted" end
    if pct < 0.15 then return "STORAGE CRITICAL", "EMERGENCY" end
    if pct < 0.30 then return "STORAGE LOW", "WARNING" end
    if pct > 0.95 then return "STORAGE HIGH", "LIMITED" end
    return "STORAGE NORMAL", "OK"
  end

  local function trend_label(total)
    local input = tonumber(total.input)
    local output = tonumber(total.output)
    if not input or not output then return "UNKNOWN", "muted" end
    local delta = input - output
    local base = math.max(1, math.abs(input), math.abs(output))
    if math.abs(delta) / base < 0.05 then return "STABLE", "OK" end
    if delta > 0 then return "CHARGING", "LIMITED" end
    return "DRAINING", "WARNING"
  end

  local function render_overview(mon, model)
    local status = model.degraded and "WARNING" or "OK"
    render_header(mon, "ENERGY OVERVIEW", status, model, "SEITE 1")
    local w, h = ui.getSize(mon); if not w or not h then return end
    local total = model.total or {}
    local banner, banner_status = storage_banner(model)
    local line = 4

    ui.text(mon, 2, line, ">> " .. banner .. " <<", colors.get(banner_status), colors.get("background")); line = line + 2

    if w >= 48 then
      ui.text(mon, 2, line, fit(string.format("ENERGIE %s | INPUT %sRF/t | OUTPUT %sRF/t", format_percent(total.percent), format_energy(total.input), format_energy(total.output)), w - 3), colors.get("text"), colors.get("background")); line = line + 1
      ui.text(mon, 2, line, fit(string.format("MATRICES %d | STORAGES %d | MASTER %s", #model.matrices, model.storages_count or 0, tostring(model.master_state or "?")), w - 3), colors.get("text"), colors.get("background")); line = line + 2
    else
      ui.text(mon, 2, line, "Energie " .. format_percent(total.percent), colors.get("text"), colors.get("background")); line = line + 1
      ui.text(mon, 2, line, "IN " .. format_energy(total.input) .. "  OUT " .. format_energy(total.output), colors.get("text"), colors.get("background")); line = line + 1
      ui.text(mon, 2, line, string.format("Matrices %d  Storages %d", #model.matrices, model.storages_count or 0), colors.get("text"), colors.get("background")); line = line + 2
    end

    ui.text(mon, 2, line, "ENERGY STORAGE", colors.get("text"), colors.get("background")); line = line + 1
    ui.progress(mon, 2, line, math.max(8, w - 4), total.percent or 0, banner_status); line = line + 1
    ui.text(mon, 2, line, fit(("%s / %s  (%s)"):format(format_energy(total.stored), format_energy(total.capacity), format_percent(total.percent)), w - 3), colors.get("text"), colors.get("background")); line = line + 2

    local trend, trend_status = trend_label(total)
    local m1 = model.matrices[1]
    local m2 = model.matrices[2]
    if line <= h - 2 then
      ui.text(mon, 2, line, fit(string.format("MATRIX A %s | MATRIX B %s | TREND %s", m1 and format_percent(m1.percent) or "n/a", m2 and format_percent(m2.percent) or "n/a", trend), w - 3), colors.get(trend_status), colors.get("background")); line = line + 1
    end
    if line <= h - 1 then
      ui.text(mon, 2, line, fit(string.format("MASTER %s (%s) | LAST SCAN %s", tostring(model.master_state or "?"), tostring(model.master_age or "-"), model.last_scan_ts and format_age(model.last_scan_ts, os.epoch("utc")) or "n/a"), w - 3), colors.get("muted"), colors.get("background"))
    end
  end

  local function render_matrices(mon, model)
    local status = model.degraded and "WARNING" or "OK"
    render_header(mon, "ENERGY MATRICES", status, model, nil)
    local w, h = ui.getSize(mon); if not w or not h then return end
    local list_start, footer_lines, total_lines, card_lines = 5, 2, 4, 4
    local available = math.max(0, (h - footer_lines - total_lines) - list_start + 1)
    local pagination = ui_router.paginate(model.matrices, math.max(1, math.floor(available / card_lines)), ui_state.matrix_page)
    ui_state.matrix_page = pagination.page
    local line = list_start
    for idx = pagination.start_index, pagination.end_index do
      local entry = model.matrices[idx]
      if entry then
        local pct = entry.percent or 0
        local label = entry.alias and entry.name and entry.alias ~= entry.name and (("%s (%s)"):format(entry.alias, entry.name)) or (entry.label or entry.name or ("Matrix " .. tostring(idx)))
        ui.text(mon, 2, line, label, colors.get("text"), colors.get("background"))
        ui.rightText(mon, 2, line, w - 2, format_percent(pct), colors.get(entry.status == "DEGRADED" and "WARNING" or status), colors.get("background")); line = line + 1
        ui.progress(mon, 2, line, w - 4, pct, entry.status == "DEGRADED" and "WARNING" or status); line = line + 1
        ui.text(mon, 2, line, ("E: %s / %s"):format(format_energy(entry.stored), format_energy(entry.capacity)), colors.get("text"), colors.get("background")); line = line + 1
        ui.text(mon, 2, line, ("IN %s  OUT %s"):format(format_energy(entry.input), format_energy(entry.output)), colors.get("text"), colors.get("background")); line = line + 1
      end
    end
    local total = model.total or {}
    line = h - footer_lines - total_lines + 1
    ui.text(mon, 2, line, ("GESAMT (%d)"):format(#model.matrices), colors.get("text"), colors.get("background")); line = line + 1
    ui.progress(mon, 2, line, w - 4, total.percent or 0, status); line = line + 1
    ui.text(mon, 2, line, ("E: %s / %s (%s)"):format(format_energy(total.stored), format_energy(total.capacity), format_percent(total.percent)), colors.get("text"), colors.get("background")); line = line + 1
    ui.text(mon, 2, line, (total.input ~= nil or total.output ~= nil) and ("IN " .. format_energy(total.input) .. "  OUT " .. format_energy(total.output)) or "IN/OUT n/a", colors.get("text"), colors.get("background"))
  end

  local function render_storages(mon, model)
    local status = model.degraded and "WARNING" or "OK"
    render_header(mon, "ENERGY STORAGES", status, model, nil)
    local w, h = ui.getSize(mon); if not w or not h then return end
    local rows = {}
    table.sort(model.storages, function(a, b) return (a.capacity or 0) > (b.capacity or 0) end)
    for _, s in ipairs(model.storages) do
      local pct = s.capacity and s.capacity > 0 and (s.stored / s.capacity) or 0
      table.insert(rows, { text = string.format("%s %s", s.id, format_percent(pct)), status = status })
    end
    if #rows == 0 then table.insert(rows, { text = "none", status = "WARNING" }) end
    local pagination = ui_router.paginate(rows, math.max(1, h - 6), ui_state.storage_page)
    ui_state.storage_page = pagination.page
    local page_rows = {}
    for idx = pagination.start_index, pagination.end_index do table.insert(page_rows, rows[idx]) end
    ui.list(mon, 2, 5, w - 2, page_rows, { max_rows = math.max(1, h - 6) })
  end

  local function render_diagnostics(mon, model)
    local status = model.degraded and "WARNING" or "OK"
    render_header(mon, "ENERGY DIAGNOSTICS", status, model, nil)
    local w, h = ui.getSize(mon); if not w or not h then return end
    local now = os.epoch("utc")
    local rows = {
      { text = ("Health: %s"):format(model.health_status or status), status = status },
      { text = ("Reasons: %s"):format(model.degraded_reason or "none") },
      { text = ("Registry total:%d bound:%d missing:%d"):format(model.registry_summary.total or 0, model.registry_summary.bound or 0, model.registry_summary.missing or 0) },
      { text = ("Master link: %s age:%s"):format(model.master_state, model.master_age) },
      { text = ("Last scan: %s (%s)"):format(model.scan_result or "n/a", format_age(model.last_scan_ts, now)) },
      { text = ("Last error: %s (%s)"):format(model.last_error or "none", format_age(model.last_error_ts, now)) },
      { text = ("Last cmd: %s (%s)"):format(model.last_command or "none", format_age(model.last_command_ts, now)) }
    }
    ui.list(mon, 2, 4, w - 2, rows, { max_rows = math.max(1, h - 6) })
    if utils then support_ui_pages.render_log_mode_button(mon, utils, 1, h - 1, w - 2) end
  end

  local function energy_status_key(model)
    local total = model and model.total or {}
    local pct = tonumber(total.percent)
    if model and model.degraded then return "WARNING" end
    if not pct then return "muted" end
    local emergency_below, warning_below, limited_above = 15, 30, 95
    local cfg_path = "/xreactor/config/ampel_thresholds.lua"
    if fs and fs.exists and fs.exists(cfg_path) then
      local ok_read, cfg = pcall(function()
        local f = fs.open(cfg_path, "r"); if not f then return nil end
        local raw = f.readAll(); f.close()
        local chunk = load(raw, "=ampel_thresholds", "t", {}); if not chunk then return nil end
        return chunk()
      end)
      if ok_read and type(cfg) == "table" then
        emergency_below = tonumber(cfg.emergency_below_pct) or emergency_below
        warning_below = tonumber(cfg.warning_below_pct) or warning_below
        limited_above = tonumber(cfg.limited_above_pct) or limited_above
      end
    end
    if pct < emergency_below then return "EMERGENCY" end
    if pct < warning_below then return "WARNING" end
    if pct > limited_above then return "LIMITED" end
    return "OK"
  end

  local function render_ampel(main_monitor_name, model)
    if not ampel_instance then return end
    ampel_instance.render(main_monitor_name, energy_status_key(model))
  end

  local function handle_diagnostics_touch(mon, x, y)
    if not utils then return false end
    local _, h = ui.getSize(mon)
    if not h then return false end
    return support_ui_pages.handle_log_mode_touch(x, y, h - 1, utils, 1)
  end

  return {
    render_overview = render_overview,
    render_matrices = render_matrices,
    render_storages = render_storages,
    render_diagnostics = render_diagnostics,
    handle_diagnostics_touch = handle_diagnostics_touch,
    render_ampel = render_ampel
  }
end

return M
