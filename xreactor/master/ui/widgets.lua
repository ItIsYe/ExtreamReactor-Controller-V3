local ui = require("core.ui")
local colors = require("shared.colors")

local widgets = {}

function widgets.status_badge(mon, x, y, text, status)
  ui.badge(mon, x, y, text or "", status or "OK")
end

function widgets.progress_bar(mon, x, y, w, percent, status)
  ui.progress(mon, x, y, w, percent or 0, status or "OK")
end

function widgets.card(mon, x, y, w, h, title, status)
  ui.panel(mon, x, y, w, h, title, status or "OK")
end

function widgets.section_header(mon, x, y, title, status, subtitle)
  ui.text(mon, x, y, tostring(title or ""), colors.get(status or "text"), colors.get("background"))
  if subtitle and #tostring(subtitle) > 0 then
    ui.text(mon, x + #tostring(title) + 1, y, tostring(subtitle), colors.get("muted"), colors.get("background"))
  end
end

function widgets.kpi_tile(mon, x, y, w, title, value, detail, status)
  ui.panel(mon, x, y, w, 4, title, status or "OK")
  ui.text(mon, x + 1, y + 1, tostring(value or "-"), colors.get(status or "OK"), colors.get("background"))
  if detail then
    ui.text(mon, x + 1, y + 2, tostring(detail), colors.get("muted"), colors.get("background"))
  end
end

function widgets.layout_button(mon, x, y, label, status)
  local text = label or "LAYOUT"
  ui.text(mon, x, y, text, colors.get(status or "accent"), colors.get("background"))
  return { x1 = x, x2 = x + #text - 1, y = y }
end

function widgets.stat_card(mon, x, y, w, title, value, meta, status, progress)
  ui.panel(mon, x, y, w, 4, title, status or "OK")
  ui.text(mon, x + 1, y + 1, tostring(value or "-"), colors.get(status or "text"), colors.get("background"))
  if meta then ui.text(mon, x + 1, y + 2, tostring(meta), colors.get("muted"), colors.get("background")) end
  if progress ~= nil then ui.progress(mon, x + 1, y + 3, math.max(6, w - 2), progress, status or "OK") end
end

function widgets.compact_header(mon, x, y, labels, widths)
  local col = x
  for i, label in ipairs(labels or {}) do
    ui.text(mon, col, y, tostring(label), colors.get("muted"), colors.get("background"))
    col = col + (widths and widths[i] or (#tostring(label) + 2))
  end
end

function widgets.compact_status_row(mon, x, y, values, widths, status)
  local col = x
  for i, value in ipairs(values or {}) do
    ui.text(mon, col, y, tostring(value or "-"), colors.get(i == 3 and (status or "text") or "text"), colors.get("background"))
    col = col + (widths and widths[i] or (#tostring(value or "-") + 2))
  end
end

return widgets
