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

local function status_from_percent(pct, degraded)
  if degraded then return "WARNING" end
  if pct == nil then return "muted" end
  if pct < 0.15 then return "EMERGENCY" end
  if pct < 0.30 then return "WARNING" end
  if pct > 0.95 then return "LIMITED" end
  return "OK"
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
    if page_text and w >= 30 then ui.rightText(mon, 2, 2, w - 2, page_text, colors.get("muted"), colors.get("background"))
    else ui.rightText(mon, 2, 2, w - 2, model.health_status or status, colors.get(status), colors.get("background")) end
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
    render_header(mon, "ENERGY OVERVIEW", status, model, "SEITE 1/4")
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
    local m1, m2 = model.matrices[1], model.matrices[2]
    if line <= h - 2 then
      ui.text(mon, 2, line, fit(string.format("MATRIX A %s | MATRIX B %s | TREND %s", m1 and format_percent(m1.percent) or "n/a", m2 and format_percent(m2.percent) or "n/a", trend), w - 3), colors.get(trend_status), colors.get("background")); line = line + 1
    end
    if line <= h - 1 then ui.text(mon, 2, line, fit(string.format("MASTER %s (%s) | LAST SCAN %s", tostring(model.master_state or "?"), tostring(model.master_age or "-"), model.last_scan_ts and format_age(model.last_scan_ts, os.epoch("utc")) or "n/a"), w - 3), colors.get("muted"), colors.get("background")) end
  end

  local function render_matrices(mon, model)
    local status = model.degraded and "WARNING" or "OK"
    render_header(mon, "ENERGY MATRICES", status, model, "SEITE 2/4")
    local w, h = ui.getSize(mon); if not w or not h then return end
    local line = 4
    local cards = math.max(1, math.floor((h - 9) / 4))
    local pagination = ui_router.paginate(model.matrices, cards, ui_state.matrix_page)
    ui_state.matrix_page = pagination.page
    for idx = pagination.start_index, pagination.end_index do
      local entry = model.matrices[idx]
      if entry and line <= h - 7 then
        local pct = entry.percent or 0
        local key = entry.status == "DEGRADED" and "WARNING" or status_from_percent(pct, false)
        local label = entry.alias and entry.name and entry.alias ~= entry.name and (("%s (%s)"):format(entry.alias, entry.name)) or (entry.label or entry.name or ("MATRIX " .. tostring(idx)))
        ui.text(mon, 2, line, fit(string.format("%s  %s", label, format_percent(pct)), w - 3), colors.get(key), colors.get("background")); line = line + 1
        if w >= 48 then
          ui.text(mon, 2, line, fit(string.format("STORED %s | CAP %s | IN %s | OUT %s", format_energy(entry.stored), format_energy(entry.capacity), format_energy(entry.input), format_energy(entry.output)), w - 3), colors.get("text"), colors.get("background")); line = line + 1
        else
          ui.text(mon, 2, line, fit(string.format("E %s/%s IN %s OUT %s", format_energy(entry.stored), format_energy(entry.capacity), format_energy(entry.input), format_energy(entry.output)), w - 3), colors.get("text"), colors.get("background")); line = line + 1
        end
        ui.progress(mon, 2, line, math.max(8, w - 4), pct, key); line = line + 2
      end
    end
    local total = model.total or {}
    local fy = math.max(line, h - 4)
    if fy <= h - 1 then
      ui.text(mon, 2, fy, fit(string.format("GESAMT %s / %s | %s | IN %s OUT %s", format_energy(total.stored), format_energy(total.capacity), format_percent(total.percent), format_energy(total.input), format_energy(total.output)), w - 3), colors.get("text"), colors.get("background")); fy = fy + 1
      if fy <= h - 1 then ui.progress(mon, 2, fy, math.max(8, w - 4), total.percent or 0, status_from_percent(total.percent, model.degraded)) end
    end
  end

  local function render_storages(mon, model)
    local status = model.degraded and "WARNING" or "OK"
    render_header(mon, "ENERGY STORAGES", status, model, "SEITE 3/4")
    local w, h = ui.getSize(mon); if not w or not h then return end
    local storages = {}
    for _, s in ipairs(model.storages or {}) do storages[#storages + 1] = s end
    table.sort(storages, function(a, b) return (a.capacity or 0) > (b.capacity or 0) end)
    local line = 4
    local max_rows = math.max(1, h - 9)
    local pagination = ui_router.paginate(storages, max_rows, ui_state.storage_page)
    ui_state.storage_page = pagination.page
    local total_stored, total_capacity = 0, 0
    for _, s in ipairs(storages) do total_stored = total_stored + (tonumber(s.stored) or 0); total_capacity = total_capacity + (tonumber(s.capacity) or 0) end
    for idx = pagination.start_index, pagination.end_index do
      local s = storages[idx]
      if s then
        local pct = s.capacity and s.capacity > 0 and ((s.stored or 0) / s.capacity) or 0
        local key = status_from_percent(pct, false)
        local id = tostring(s.id or s.name or ("ST-" .. tostring(idx)))
        if w >= 48 then
          ui.text(mon, 2, line, fit(string.format("%-14s ENERGY %-8s / %-8s | %s | HEALTH %s", id, format_energy(s.stored), format_energy(s.capacity), format_percent(pct), key), w - 3), colors.get(key), colors.get("background"))
        else
          ui.text(mon, 2, line, fit(string.format("%s %s/%s %s", id, format_energy(s.stored), format_energy(s.capacity), format_percent(pct)), w - 3), colors.get(key), colors.get("background"))
        end
        line = line + 1
        if line <= h - 5 then ui.progress(mon, 2, line, math.max(8, w - 4), pct, key); line = line + 1 end
      end
    end
    if #storages == 0 then ui.text(mon, 2, line, "KEINE STORAGES GEFUNDEN", colors.get("WARNING"), colors.get("background")) end
    local total_pct = total_capacity > 0 and total_stored / total_capacity or 0
    local fy = math.max(line + 1, h - 3)
    if fy <= h - 1 then
      ui.text(mon, 2, fy, fit(string.format("GESAMT SPEICHER %s | %s / %s", format_percent(total_pct), format_energy(total_stored), format_energy(total_capacity)), w - 3), colors.get(status_from_percent(total_pct, false)), colors.get("background")); fy = fy + 1
      if fy <= h - 1 then ui.progress(mon, 2, fy, math.max(8, w - 4), total_pct, status_from_percent(total_pct, false)) end
    end
  end

  local function render_diagnostics(mon, model)
    local status = model.degraded and "WARNING" or "OK"
    render_header(mon, "ENERGY DIAGNOSTICS", status, model, "SEITE 4/4")
    local w, h = ui.getSize(mon); if not w or not h then return end
    local now = os.epoch("utc")
    local line = 4
    local reason = model.degraded_reason or "none"
    local summary = model.registry_summary or {}
    ui.text(mon, 2, line, fit(string.format("GESUNDHEIT %s | DEGRADATION %s", tostring(model.health_status or status), reason), w - 3), colors.get(status), colors.get("background")); line = line + 1
    ui.text(mon, 2, line, fit(string.format("REGISTRY %d total / %d bound / %d missing | MASTER %s age %s", summary.total or 0, summary.bound or 0, summary.missing or 0, tostring(model.master_state or "?"), tostring(model.master_age or "-")), w - 3), colors.get((summary.missing or 0) > 0 and "WARNING" or "text"), colors.get("background")); line = line + 2
    ui.text(mon, 2, line, fit(string.format("LETZTER SCAN %s (%s)", tostring(model.scan_result or "n/a"), format_age(model.last_scan_ts, now)), w - 3), colors.get("text"), colors.get("background")); line = line + 1
    ui.text(mon, 2, line, fit(string.format("LETZTER FEHLER %s (%s)", tostring(model.last_error or "none"), format_age(model.last_error_ts, now)), w - 3), colors.get(model.last_error and "WARNING" or "text"), colors.get("background")); line = line + 1
    ui.text(mon, 2, line, fit(string.format("LETZTER BEFEHL %s (%s)", tostring(model.last_command or "none"), format_age(model.last_command_ts, now)), w - 3), colors.get("LIMITED"), colors.get("background")); line = line + 2
    local total = model.total or {}
    local key = status_from_percent(total.percent, model.degraded)
    ui.text(mon, 2, line, fit(string.format("AMPEL %s | STORAGE %s | INPUT %s | OUTPUT %s", key, format_percent(total.percent), format_energy(total.input), format_energy(total.output)), w - 3), colors.get(key), colors.get("background")); line = line + 2
    local alerts = model.local_alerts or {}
    if #alerts > 0 and line <= h - 2 then
      ui.text(mon, 2, line, "DIAGNOSE LISTE", colors.get("text"), colors.get("background")); line = line + 1
      local shown = math.min(#alerts, math.max(0, h - line - 1))
      for i = 1, shown do
        local a = alerts[i]
        local sev = tostring(a.severity or "INFO")
        local k = sev == "CRITICAL" and "EMERGENCY" or (sev == "WARN" or sev == "WARNING") and "WARNING" or "LIMITED"
        ui.text(mon, 2, line, fit(string.format("%-9s %-12s %s", sev, tostring(a.code or "-"), tostring(a.title or a.message or "alert")), w - 3), colors.get(k), colors.get("background")); line = line + 1
      end
    end
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
