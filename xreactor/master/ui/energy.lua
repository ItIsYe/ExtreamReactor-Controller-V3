local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function status_weight(status)
  local s = tostring(status or "OFFLINE"):upper()
  if s == "EMERGENCY" or s == "OFFLINE" then return 6 end
  if s == "WARNING" then return 5 end
  if s == "LIMITED" then return 4 end
  if s == "OK" then return 2 end
  return 3
end

local function matrix_score(matrix)
  local score = status_weight(matrix and matrix.status) * 1000
  local age = tonumber(matrix and matrix.last_seen_age) or -1
  if age > 0 then
    score = score + math.min(age, 300)
  end
  local percent = tonumber(matrix and matrix.percent) or 0
  if percent < 15 then
    score = score + 500
  elseif percent < 30 then
    score = score + 250
  end
  local input = tonumber(matrix and matrix.input) or 0
  local output = tonumber(matrix and matrix.output) or 0
  score = score + math.min(200, math.abs(input - output))
  return score
end

local function support_score(node)
  local score = status_weight(node and node.status) * 1000
  local age = tonumber(node and node.last_seen_age) or -1
  if age > 0 then
    score = score + math.min(age, 300)
  end
  return score
end

local function prioritized_list(items, score_fn)
  local list = {}
  for _, item in ipairs(items or {}) do
    list[#list + 1] = item
  end
  table.sort(list, function(a, b)
    local sa = score_fn(a)
    local sb = score_fn(b)
    if sa ~= sb then
      return sa > sb
    end
    local aid = tostring((a and (a.id or a.label or a.name)) or "")
    local bid = tostring((b and (b.id or b.label or b.name)) or "")
    return aid < bid
  end)
  return list
end

local function render_matrix_overflow(mon, x, y, width, hidden)
  if #hidden <= 0 then
    return
  end
  local critical = 0
  for _, matrix in ipairs(hidden) do
    if status_weight(matrix.status) >= 5 then
      critical = critical + 1
    end
  end
  local lead = hidden[1]
  local text = "+" .. tostring(#hidden) .. " weitere Matrizen"
  if critical > 0 then
    text = text .. " | kritisch=" .. tostring(critical)
  end
  ui.text(mon, x, y, widgets.fit(text, width), colors.get("muted"), colors.get("background"))
  if lead then
    ui.text(mon, x, y + 1, widgets.fit("Top hidden: " .. tostring(lead.id or lead.label or "M"), width), colors.get("muted"), colors.get("background"))
  end
end

local function render_support_overflow(mon, x, y, width, hidden)
  if #hidden <= 0 then
    return
  end
  local stale = 0
  for _, node in ipairs(hidden) do
    if (tonumber(node.last_seen_age) or -1) > 15 then
      stale = stale + 1
    end
  end
  local text = "+" .. tostring(#hidden) .. " weitere Support-Nodes"
  if stale > 0 then
    text = text .. " | stale=" .. tostring(stale)
  end
  ui.text(mon, x, y, widgets.fit(text, width), colors.get("muted"), colors.get("background"))
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  local is_large = (w * h) >= 900 and w >= 48 and h >= 18
  ui.panel(mon, 1, 1, w, h, "ENERGY", model.status or "OK")

  local pct = model.capacity and model.capacity > 0 and ((model.stored or 0) / model.capacity) * 100 or 0
  local summary_h = is_large and 11 or 10
  local summary = widgets.panel_box(mon, 2, 2, w - 2, summary_h, "Energy Summary", model.status or "OK")
  ui.bigNumber(mon, summary.x, summary.y, "Fuellstand", string.format("%.1f", model.aggregate_percent or pct), "%", model.status or "OK")
  ui.progress(mon, summary.x, summary.y + 2, math.max(12, summary.w), math.max(0, math.min(100, model.aggregate_percent or pct)) / 100, model.status or "OK")
  ui.text(mon, summary.x, summary.y + 3, widgets.fit(string.format("Stored %.1f / %.1f", model.stored or 0, model.capacity or 0), summary.w), colors.get("text"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 4, widgets.fit(string.format("Input %.1f | Output %.1f MRF/t", model.input or 0, model.output or 0), summary.w), colors.get("text"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 5, widgets.fit("Mode " .. tostring(model.mode or "-") .. " | Matrices " .. tostring(model.matrix_count or 0), summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 6, widgets.fit((model.matrix_only and "Matrix-Only" or "Hybrid/Storage") .. " | Support " .. tostring(model.support_online or 0) .. "/" .. tostring(#(model.support_nodes or {})), summary.w), colors.get("muted"), colors.get("background"))
  ui.text(mon, summary.x, summary.y + 7, widgets.fit("Resources: " .. tostring(model.resource_summary or "-"), summary.w), colors.get("muted"), colors.get("background"))
  if (model.matrix_count or 0) == 1 and model.matrices and model.matrices[1] then
    local m = model.matrices[1]
    ui.text(mon, summary.x, summary.y + 8, widgets.fit(string.format("Single Matrix %s %.1f%% | In %.1f | Out %.1f", tostring(m.id or "M1"), m.percent or 0, m.input or 0, m.output or 0), summary.w), colors.get("LIMITED"), colors.get("background"))
  end

  local content_y = 2 + summary_h + 1
  local content_h = math.max(8, h - content_y - 1)
  local cols = widgets.split_columns(w - 2, { 3, 2 }, 1)
  local left_w, right_w = cols[1], cols[2]

  local matrix = widgets.panel_box(mon, 2, content_y, left_w, content_h, ((model.matrix_count or 0) == 1) and "Matrix-Detail" or "Matrix / Storage", (model.matrix_count or 0) > 0 and "OK" or "OFFLINE")
  local matrix_widths = widgets.table_widths(matrix.w, is_large and { 12, 9, 9, 9, 8 } or { 10, 8, 8, 8, 7 })
  widgets.compact_header(mon, matrix.x, matrix.y, { "ID", "%", "In", "Out", "Status" }, matrix_widths)
  local ordered_matrices = prioritized_list(model.matrices or {}, matrix_score)
  local matrix_rows = math.max(1, matrix.h - 1)
  local matrix_overflow = #ordered_matrices > matrix_rows
  local matrix_show = matrix_overflow and math.max(1, matrix_rows - 2) or matrix_rows
  local my = matrix.y + 1
  for i = 1, math.min(#ordered_matrices, matrix_show) do
    local m = ordered_matrices[i]
    widgets.compact_status_row(mon, matrix.x, my, {
      tostring(m.id or m.label or "M"),
      string.format("%.1f", m.percent or 0),
      string.format("%.1f", m.input or 0),
      string.format("%.1f", m.output or 0),
      tostring(m.status or "OK")
    }, matrix_widths, m.status or "OK", 5)
    my = my + 1
  end
  if #ordered_matrices == 0 then
    local has_flow = (model.stored or 0) > 0 or (model.input or 0) > 0 or (model.output or 0) > 0
    local msg = has_flow and "Keine Matrixzeilen, aber Energiefluss vorhanden" or "Keine Matrixdaten sichtbar"
    ui.text(mon, matrix.x, my, widgets.fit(msg, matrix.w), colors.get(has_flow and "WARNING" or "OFFLINE"), colors.get("background"))
  elseif matrix_overflow then
    local hidden = {}
    for i = matrix_show + 1, #ordered_matrices do
      hidden[#hidden + 1] = ordered_matrices[i]
    end
    render_matrix_overflow(mon, matrix.x, my, matrix.w, hidden)
  end

  local right_x = 2 + left_w + 1
  local resources_h = math.max(7, math.floor(content_h * 0.45))
  local resources = widgets.panel_box(mon, right_x, content_y, right_w, resources_h, "Ressourcen", "OK")
  local r = model.resources or {}
  widgets.stat_card(mon, resources.x, resources.y, resources.w, "Fuel", string.format("%.1f Reserve", r.fuel_total or 0), string.format("%d Quellen", r.fuel_sources or 0), "LIMITED")
  widgets.stat_card(mon, resources.x, resources.y + 6, resources.w, "Water / Reproc", string.format("Water %.1f", r.water_total or 0), "Reproc " .. tostring(r.reprocessing_state or "-"), "OK")
  if model.matrix_only then
    ui.text(mon, resources.x, resources.y + math.max(0, resources.h - 1), widgets.fit("Payload: Matrix-Only", resources.w), colors.get("LIMITED"), colors.get("background"))
  end

  local support_y = content_y + resources_h + 1
  local support_h = math.max(6, (content_y + content_h) - support_y + 1)
  local support = widgets.panel_box(mon, right_x, support_y, right_w, support_h, "Support-Nodes", (model.support_stale or 0) > 0 and "WARNING" or "OK")
  local support_widths = widgets.table_widths(support.w, { 8, 8, 7, 10 })
  widgets.compact_header(mon, support.x, support.y, { "Node", "Rolle", "Seen", "Hinweis" }, support_widths)
  local ordered_support = prioritized_list(model.support_nodes or {}, support_score)
  local support_rows = math.max(1, support.h - 1)
  local support_overflow = #ordered_support > support_rows
  local support_show = support_overflow and math.max(1, support_rows - 1) or support_rows
  local sy = support.y + 1
  for i = 1, math.min(#ordered_support, support_show) do
    local n = ordered_support[i]
    widgets.compact_status_row(mon, support.x, sy, {
      tostring(n.id or "-"),
      tostring(n.role or "-"),
      tostring(n.last_seen_age or -1) .. "s",
      tostring(n.note or "-")
    }, support_widths, n.status or "OFFLINE", 2)
    sy = sy + 1
  end
  if #ordered_support == 0 then
    ui.text(mon, support.x, sy, "Keine Support-Nodes sichtbar", colors.get("OFFLINE"), colors.get("background"))
  elseif support_overflow then
    local hidden = {}
    for i = support_show + 1, #ordered_support do
      hidden[#hidden + 1] = ordered_support[i]
    end
    render_support_overflow(mon, support.x, sy, support.w, hidden)
  end
end

return { render = render }
