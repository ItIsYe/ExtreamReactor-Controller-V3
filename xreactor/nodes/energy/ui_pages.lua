local M = {}
local support_ui_pages = require("nodes.support.ui_pages")

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

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local colors = assert(opts.colors, "colors required")
  local ui_router = assert(opts.ui_router, "ui_router required")
  local ui_state = assert(opts.ui_state, "ui_state required")
  local utils = opts.utils  -- optional: needed for log mode buttons

  local function render_header(mon, title, status, model)
    local w, h = ui.getSize(mon)
    if not w or not h then return end
    ui.panel(mon, 1, 1, w, h, title, status)
    ui.text(mon, 2, 2, ("ID: %s"):format(model.node_id or "UNKNOWN"), colors.get("text"), colors.get("background"))
    ui.rightText(mon, 2, 2, w - 2, model.health_status or status, colors.get(status), colors.get("background"))
    if model.local_alerts_critical and model.local_alerts_critical > 0 then
      local label = "CRIT " .. tostring(model.local_alerts_critical)
      ui.badge(mon, w - (#label + 2), 1, label, "EMERGENCY")
    end
  end

  local function render_overview(mon, model)
    local status = model.degraded and "WARNING" or "OK"
    render_header(mon, "ENERGY NODE", status, model)
    local w = select(1, ui.getSize(mon)); if not w then return end
    local line = 4
    ui.text(mon, 2, line, ("Matrices: %d"):format(#model.matrices), colors.get("text"), colors.get("background")); line = line + 1
    ui.text(mon, 2, line, ("Storages: %d"):format(model.storages_count or 0), colors.get("text"), colors.get("background")); line = line + 2
    local total = model.total or {}
    ui.text(mon, 2, line, "GESAMT", colors.get("text"), colors.get("background")); line = line + 1
    ui.progress(mon, 2, line, w - 4, total.percent or 0, status); line = line + 1
    ui.text(mon, 2, line, ("E: %s / %s (%s)"):format(format_energy(total.stored), format_energy(total.capacity), format_percent(total.percent)), colors.get("text"), colors.get("background")); line = line + 1
    local flow = (total.input ~= nil or total.output ~= nil) and ("IN " .. format_energy(total.input) .. "  OUT " .. format_energy(total.output)) or "IN/OUT n/a"
    ui.text(mon, 2, line, flow, colors.get("text"), colors.get("background")); line = line + 2
    ui.text(mon, 2, line, ("Last scan: %s"):format(model.last_scan_ts and format_age(model.last_scan_ts, os.epoch("utc")) or "n/a"), colors.get("text"), colors.get("background"))
  end

  local function render_matrices(mon, model)
    local status = model.degraded and "WARNING" or "OK"
    render_header(mon, "ENERGY MATRICES", status, model)
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
    render_header(mon, "ENERGY STORAGES", status, model)
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
    render_header(mon, "ENERGY DIAGNOSTICS", status, model)
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
    if utils then
      support_ui_pages.render_log_mode_button(mon, utils, 1, h - 1, w - 2)
    end
  end

  -- Touch handler for the Diagnostics page (log mode buttons).
  -- Called from main.lua's monitor_touch/mouse_click event handler.
  local function handle_diagnostics_touch(mon, x, y)
    if not utils then return false end
    local _, h = ui.getSize(mon)
    if not h then return false end
    return support_ui_pages.handle_log_mode_touch(x, y, h - 1, utils, 1)
  end
  M.handle_diagnostics_touch = handle_diagnostics_touch

  return {
    render_overview = render_overview,
    render_matrices = render_matrices,
    render_storages = render_storages,
    render_diagnostics = render_diagnostics
  }
end

return M
