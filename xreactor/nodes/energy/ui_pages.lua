local M = {}
local mux = require("core.mockup_ui")
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

local function status_from_percent(pct, degraded)
  if degraded then return "WARNING" end
  if pct == nil then return "muted" end
  if pct < 0.15 then return "EMERGENCY" end
  if pct < 0.30 then return "WARNING" end
  if pct > 0.95 then return "LIMITED" end
  return "OK"
end

local function trend_label(total)
  local input = tonumber(total and total.input)
  local output = tonumber(total and total.output)
  if not input or not output then return "UNKNOWN", "muted" end
  local delta = input - output
  local base = math.max(1, math.abs(input), math.abs(output))
  if math.abs(delta) / base < 0.05 then return "STABLE", "OK" end
  if delta > 0 then return "CHARGING", "LIMITED" end
  return "DRAINING", "WARNING"
end

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local colors = assert(opts.colors, "colors required")
  local ui_router = assert(opts.ui_router, "ui_router required")
  local ui_state = assert(opts.ui_state, "ui_state required")
  local utils = opts.utils

  local function page_header(mon, model, title, page, icon)
    local status = model.degraded and "WARNING" or "OK"
    mux.clear(mon)
    mux.header(mon, { title = title, node_id = model.node_id or "EN-?", page = page, status = status, icon = icon })
    local w = ({ mon.getSize() })[1]
    if w >= 42 then
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING")
      mux.status_dot(mon, math.floor(w * 0.40), 3, model.degraded and "DEGRADED" or "HEALTHY", status)
      mux.status_dot(mon, math.floor(w * 0.72), 3, tostring(model.health_status or status), status)
    end
    return mon.getSize()
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

  local function render_overview(mon, model)
    local w, h = page_header(mon, model, "ENERGY NODE", "SEITE 1/4", "energy")
    local total = model.total or {}
    local banner, key = storage_banner(model)
    local trend, trend_key = trend_label(total)
    mux.banner(mon, 2, 5, w - 3, banner, key, "energy")

    if w >= 54 and h >= 18 then
      local gap = 1
      local cw = math.floor((w - 4 - gap * 2) / 3)
      mux.metric_card(mon, 2, 7, cw, 4, { label = "ENERGIE", value = format_percent(total.percent), status = key, icon = "energy" })
      mux.metric_card(mon, 2 + cw + gap, 7, cw, 4, { label = "INPUT", value = format_energy(total.input), unit = "RF/t", status = "LIMITED", icon = "input" })
      mux.metric_card(mon, 2 + (cw + gap) * 2, 7, cw, 4, { label = "OUTPUT", value = format_energy(total.output), unit = "RF/t", status = "OK", icon = "output" })

      mux.section(mon, 2, 12, w - 3, "ENERGY STORAGE", key, "storage")
      mux.outlined_progress(mon, 2, 14, w - 3, total.percent or 0, key, format_percent(total.percent))
      mux.kpi_strip(mon, 2, 16, w - 3, {
        { label = "MATRICES", value = tostring(#(model.matrices or {})), status = "OK", icon = "storage" },
        { label = "STORAGES", value = tostring(model.storages_count or #(model.storages or {})), status = "OK", icon = "storage" },
        { label = "TREND", value = trend, status = trend_key, icon = "flow" },
        { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      })
    else
      mux.kpi_strip(mon, 2, 7, w - 3, {
        { label = "ENERGIE", value = format_percent(total.percent), status = key, icon = "energy" },
        { label = "INPUT", value = format_energy(total.input), status = "LIMITED", icon = "input" },
        { label = "OUTPUT", value = format_energy(total.output), status = "OK", icon = "output" },
      })
      mux.section(mon, 2, 10, w - 3, "STORAGE", key, "storage")
      mux.outlined_progress(mon, 2, 12, w - 3, total.percent or 0, key, format_percent(total.percent))
      mux.data_row(mon, 2, 14, w - 3, { label = "Trend", value = trend, status = trend_key, icon = "flow" })
    end

    if h >= 20 then
      local m1, m2 = (model.matrices or {})[1], (model.matrices or {})[2]
      mux.section(mon, 2, h - 4, w - 3, "MATRIX SNAPSHOT", "LIMITED", "storage")
      mux.data_row(mon, 2, h - 2, w - 3, { label = "A " .. (m1 and format_percent(m1.percent) or "n/a") .. " | B " .. (m2 and format_percent(m2.percent) or "n/a"), value = trend, status = trend_key })
    end
    mux.footer_nav(mon, h, w, { center = "ENERGY OVERVIEW" })
  end

  local function render_matrices(mon, model)
    local w, h = page_header(mon, model, "ENERGY MATRICES", "SEITE 2/4", "storage")
    local matrices = model.matrices or {}
    local cards_per_page = math.max(1, math.floor((h - 10) / 6))
    local pagination = ui_router.paginate(matrices, cards_per_page, ui_state.matrix_page)
    ui_state.matrix_page = pagination.page

    mux.kpi_strip(mon, 2, 5, w - 3, {
      { label = "MATRICES", value = tostring(#matrices), status = "OK", icon = "storage" },
      { label = "TOTAL", value = format_percent((model.total or {}).percent), status = status_from_percent((model.total or {}).percent, model.degraded), icon = "energy" },
      { label = "INPUT", value = format_energy((model.total or {}).input), status = "LIMITED", icon = "input" },
      { label = "OUTPUT", value = format_energy((model.total or {}).output), status = "OK", icon = "output" },
    })

    local y = 8
    for idx = pagination.start_index, pagination.end_index do
      local entry = matrices[idx]
      if entry and y <= h - 7 then
        local pct = entry.percent or 0
        local key = entry.status == "DEGRADED" and "WARNING" or status_from_percent(pct, false)
        local label = entry.alias or entry.label or entry.name or ("MATRIX " .. tostring(idx))
        mux.card(mon, 2, y, w - 3, 5, { title = tostring(label), status = key, icon = "storage" })
        mux.kpi_strip(mon, 4, y + 1, w - 7, {
          { label = "FILL", value = format_percent(pct), status = key, icon = "energy" },
          { label = "STORED", value = format_energy(entry.stored), status = key, icon = "storage" },
          { label = "INPUT", value = format_energy(entry.input), status = "LIMITED", icon = "input" },
          { label = "OUTPUT", value = format_energy(entry.output), status = "OK", icon = "output" },
        })
        mux.outlined_progress(mon, 4, y + 3, w - 7, pct, key, format_percent(pct))
        y = y + 6
      end
    end
    mux.footer_nav(mon, h, w, { center = "MATRICES" })
  end

  local function render_storages(mon, model)
    local w, h = page_header(mon, model, "ENERGY STORAGES", "SEITE 3/4", "storage")
    local storages = {}
    for _, s in ipairs(model.storages or {}) do storages[#storages + 1] = s end
    table.sort(storages, function(a, b) return (a.capacity or 0) > (b.capacity or 0) end)

    local total_stored, total_capacity = 0, 0
    for _, s in ipairs(storages) do
      total_stored = total_stored + (tonumber(s.stored) or 0)
      total_capacity = total_capacity + (tonumber(s.capacity) or 0)
    end
    local total_pct = total_capacity > 0 and total_stored / total_capacity or 0
    local total_key = status_from_percent(total_pct, model.degraded)
    mux.kpi_strip(mon, 2, 5, w - 3, {
      { label = "STORAGES", value = tostring(#storages), status = "OK", icon = "storage" },
      { label = "GESAMT", value = format_percent(total_pct), status = total_key, icon = "energy" },
      { label = "STORED", value = format_energy(total_stored), status = total_key, icon = "storage" },
      { label = "CAPACITY", value = format_energy(total_capacity), status = "LIMITED", icon = "storage" },
    })
    mux.section(mon, 2, 8, w - 3, "STORAGE BANK", total_key, "storage")
    mux.outlined_progress(mon, 2, 10, w - 3, total_pct, total_key, format_percent(total_pct))

    local max_rows = math.max(1, h - 13)
    local pagination = ui_router.paginate(storages, max_rows, ui_state.storage_page)
    ui_state.storage_page = pagination.page
    local y = 12
    for idx = pagination.start_index, pagination.end_index do
      local s = storages[idx]
      if s then
        local pct = s.capacity and s.capacity > 0 and ((s.stored or 0) / s.capacity) or 0
        local key = status_from_percent(pct, false)
        mux.data_row(mon, 2, y, w - 3, { label = tostring(s.id or s.name or ("ST-" .. idx)), value = format_energy(s.stored) .. "/" .. format_energy(s.capacity) .. " " .. format_percent(pct), status = key, icon = "storage" })
        y = y + 1
      end
    end
    if #storages == 0 then mux.warning_box(mon, 2, 12, w - 3, { "Keine Storages gefunden", "Discovery / Binding pruefen" }, "WARNING") end
    mux.footer_nav(mon, h, w, { center = "STORAGES" })
  end

  local function render_diagnostics(mon, model)
    local w, h = page_header(mon, model, "ENERGY DIAGNOSTICS", "SEITE 4/4", "network")
    local summary = model.registry_summary or {}
    local total = model.total or {}
    local storage_key = status_from_percent(total.percent, model.degraded)
    mux.kpi_strip(mon, 2, 5, w - 3, {
      { label = "HEALTH", value = tostring(model.health_status or (model.degraded and "WARNING" or "OK")), status = model.degraded and "WARNING" or "OK", icon = "ok" },
      { label = "MASTER", value = tostring(model.master_state or "?") .. " " .. tostring(model.master_age or ""), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      { label = "MISSING", value = tostring(summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "warning" },
      { label = "STORAGE", value = format_percent(total.percent), status = storage_key, icon = "energy" },
    })

    mux.section(mon, 2, 8, w - 3, "REGISTRY & DISCOVERY", "LIMITED", "network")
    mux.data_row(mon, 2, 10, w - 3, { label = "Registry", value = string.format("%d total / %d bound / %d missing", summary.total or 0, summary.bound or 0, summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "text", icon = "network" })
    mux.data_row(mon, 2, 11, w - 3, { label = "Last scan", value = tostring(model.scan_result or "n/a") .. " / " .. format_age(model.last_scan_ts, os.epoch("utc")), status = "text", icon = "network" })
    mux.data_row(mon, 2, 12, w - 3, { label = "Last error", value = tostring(model.last_error or "none"), status = model.last_error and "WARNING" or "OK", icon = "warning" })
    mux.data_row(mon, 2, 13, w - 3, { label = "Last command", value = tostring(model.last_command or "none"), status = "LIMITED", icon = "config" })

    mux.section(mon, 2, 15, w - 3, "ENERGY LOGIC", storage_key, "energy")
    mux.data_row(mon, 2, 17, w - 3, { label = "Storage status", value = storage_key, status = storage_key, icon = "energy" })
    mux.data_row(mon, 2, 18, w - 3, { label = "Input", value = format_energy(total.input), status = "LIMITED", icon = "input" })
    mux.data_row(mon, 2, 19, w - 3, { label = "Output", value = format_energy(total.output), status = "OK", icon = "output" })

    local alerts = model.local_alerts or {}
    if #alerts > 0 and h >= 24 then
      mux.section(mon, 2, 21, w - 3, "AKTIVE ALERTE", "WARNING", "warning")
      local y = 23
      for i = 1, math.min(#alerts, math.max(0, h - y - 1)) do
        local a = alerts[i]
        local sev = tostring(a.severity or "INFO")
        local key = sev == "CRITICAL" and "EMERGENCY" or (sev == "WARN" or sev == "WARNING") and "WARNING" or "LIMITED"
        mux.data_row(mon, 2, y, w - 3, { label = tostring(a.code or sev), value = tostring(a.title or a.message or "alert"), status = key, icon = "warning" })
        y = y + 1
      end
    end
    if utils then support_ui_pages.render_log_mode_button(mon, utils, 1, h - 1, w - 2) end
    mux.footer_nav(mon, h, w, { center = "DIAGNOSTICS" })
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
    render_ampel = render_ampel,
  }
end

return M
