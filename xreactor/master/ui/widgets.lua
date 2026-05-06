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

return widgets
