local ui = require("core.ui")
local colorset = require("shared.colors")
local widgets = require("master.ui.widgets")
local cache = {}

local function join_names(names, max_len)
  if type(names) ~= "table" or #names == 0 then
    return "none"
  end
  local text = table.concat(names, ",")
  if max_len and #text > max_len then
    return text:sub(1, math.max(1, max_len - 1)) .. "…"
  end
  return text
end

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  local w, h = mon.getSize()
  widgets.card(mon, 1, 1, w, h, "ENERGY", "OK")
  local percent = model.capacity and model.capacity > 0 and (model.stored or 0) / model.capacity or 0
  ui.bigNumber(mon, 2, 2, "Stored", string.format("%.0f%%", percent * 100), "", model.status)
  widgets.progress_bar(mon, 2, 4, w - 4, percent, model.status or "OK")
  local line = 6
  ui.text(mon, 2, line, "Trend", colorset.get("text"), colorset.get("background"))
  if model.trend_dirty then
    local trend = widgets.sparkline(model.trend_values or {}, w - 8)
    ui.text(mon, 8, 6, trend, colorset.get(model.status or "OK"), colorset.get("background"))
  end
  line = line + 1
  ui.text(mon, 2, line, "Flow", colorset.get("text"), colorset.get("background"))
  ui.text(mon, 8, line, string.format("In %.0f  Out %.0f  %s", model.input or 0, model.output or 0, model.trend_arrow or "→"), colorset.get("text"), colorset.get("background"))
  line = line + 1
  local counts = model.alert_counts or {}
  local crit = counts.CRITICAL or 0
  local warn = counts.WARN or 0
  if crit > 0 or warn > 0 then
    ui.text(mon, 2, line, "Alerts", colorset.get("WARNING"), colorset.get("background"))
    ui.badge(mon, 10, line, "CRIT " .. tostring(crit), crit > 0 and "EMERGENCY" or "OFFLINE")
    ui.badge(mon, 20, line, "WARN " .. tostring(warn), warn > 0 and "WARNING" or "OFFLINE")
    line = line + 1
    local top = model.alert_top or {}
    if #top > 0 then
      for i = 1, math.min(3, #top) do
        ui.text(mon, 4, line, top[i].title or top[i].message or "CRITICAL", colorset.get("EMERGENCY"), colorset.get("background"))
        line = line + 1
      end
    else
      ui.text(mon, 4, line, "Warnings active", colorset.get("WARNING"), colorset.get("background"))
      line = line + 1
    end
  end
  if model.top_matrices and #model.top_matrices > 0 then
    ui.text(mon, 2, line, "Top Matrices", colorset.get("text"), colorset.get("background"))
    line = line + 1
    for i = 1, math.min(3, #model.top_matrices) do
      local m = model.top_matrices[i]
      local label = string.format("%s %.0f%%", m.label or m.id or "matrix", (m.percent or 0) * 100)
      ui.text(mon, 4, line, label, colorset.get(m.status or "OK"), colorset.get("background"))
      line = line + 1
    end
  end
  local rows = {}
  line = math.max(line + 1, 9)
  table.insert(rows, { text = "Nodes", status = "OK" })
  for _, node in ipairs(model.nodes or {}) do
    local monitor_flag = node.monitor_bound and "M:Y" or "M:N"
    local storage_count = node.storage_bound_count or 0
    local degraded = node.degraded_reason and (" " .. node.degraded_reason) or ""
    local status = node.degraded_reason and "WARNING" or (node.status or model.status)
    local scan_age = ""
    if node.last_scan_ts and model.now_ms then
      local age = math.max(0, math.floor((model.now_ms - node.last_scan_ts) / 1000))
      scan_age = (" scan %ds"):format(age)
    end
    local storage_names = join_names(node.bound_storage_names, w - 8)
    local bindings = node.bindings_summary and (" " .. node.bindings_summary) or ""
    table.insert(rows, { text = string.format("%s %s S:%d%s%s%s", node.id or "ENERGY", monitor_flag, storage_count, degraded, scan_age, bindings), status = status })
    table.insert(rows, { text = "  storages: " .. storage_names, status = status })
    if node.last_scan_result then
      table.insert(rows, { text = "  last: " .. tostring(node.last_scan_result), status = status })
    end
  end
  table.insert(rows, { text = "Storages", status = "OK" })
  for _, s in ipairs(model.stores or {}) do
    table.insert(rows, { text = string.format("%s %.0f/%.0f", s.id, s.stored or 0, s.capacity or 0), status = model.status })
  end
  ui.list(mon, 2, line, w - 2, rows, { max_rows = h - line - 1 })
end

return { render = render }
