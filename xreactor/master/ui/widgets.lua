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

function widgets.sparkline(values, width)
  return ui.sparkline(values, width)
end

function widgets.layout_button(mon, x, y, label, status)
  local text = label or "LAYOUT"
  ui.text(mon, x, y, text, colors.get(status or "accent"), colors.get("background"))
  return {
    x1 = x,
    x2 = x + #text - 1,
    y = y
  }
end

return widgets
