local ui = require("core.ui")
local colors = require("shared.colors")

local widgets = {}

local function clamp_width(width, fallback)
  return math.max(1, tonumber(width) or fallback or 1)
end

function widgets.fit(text, width)
  local raw = tostring(text or "")
  local w = clamp_width(width, #raw)
  if #raw <= w then return raw end
  if w <= 2 then return string.sub(raw, 1, w) end
  return string.sub(raw, 1, w - 1) .. "~"
end

function widgets.pad(text, width)
  local w = clamp_width(width, 1)
  return string.format("%-" .. tostring(w) .. "s", widgets.fit(text or "", w))
end

function widgets.status_badge(mon, x, y, text, status, max_width)
  local label = widgets.fit(text or "", clamp_width(max_width, 24))
  ui.badge(mon, x, y, label, status or "OK")
  return #label + 2
end

function widgets.progress_bar(mon, x, y, w, percent, status)
  ui.progress(mon, x, y, w, percent or 0, status or "OK")
end

function widgets.card(mon, x, y, w, h, title, status)
  ui.panel(mon, x, y, w, h, widgets.fit(title or "", math.max(8, w - 4)), status or "OK")
end

function widgets.layout_button(mon, x, y, label, status)
  local text = widgets.fit((label or "LAYOUT"):upper(), 10)
  local badge = "<" .. text .. ">"
  ui.badge(mon, x, y, badge, status or "LIMITED")
  return { x1 = x, x2 = x + #badge + 1, y = y }
end

function widgets.stat_card(mon, x, y, w, title, value, meta, status, progress)
  local width = math.max(10, w)
  ui.panel(mon, x, y, width, 4, widgets.fit(title or "", width - 3), status or "OK")
  ui.text(mon, x + 1, y + 1, widgets.fit(tostring(value or "-"), width - 2), colors.get(status or "text"), colors.get("background"))
  if meta then ui.text(mon, x + 1, y + 2, widgets.fit(tostring(meta), width - 2), colors.get("muted"), colors.get("background")) end
  if progress ~= nil then ui.progress(mon, x + 1, y + 3, math.max(6, width - 2), math.max(0, math.min(100, progress)), status or "OK") end
end

function widgets.alert_row(mon, x, y, width, alert)
  local row_w = math.max(24, width or 24)
  local status = tostring((alert and alert.status) or "INFO")
  local title_w = math.max(10, math.min(16, math.floor(row_w * 0.25)))
  local text_w = math.max(8, row_w - (8 + title_w + 2))
  local title = widgets.fit((alert and alert.title) or "Alert", title_w)
  local text = widgets.fit((alert and alert.text) or "", text_w)
  ui.badge(mon, x, y, widgets.fit(status, 7), status)
  ui.text(mon, x + 9, y, widgets.pad(title, title_w), colors.get("text"), colors.get("background"))
  ui.text(mon, x + 10 + title_w, y, text, colors.get("muted"), colors.get("background"))
end

function widgets.compact_header(mon, x, y, labels, widths)
  local col = x
  for i, label in ipairs(labels or {}) do
    local cw = math.max(3, (widths and widths[i]) or (#tostring(label) + 2))
    ui.text(mon, col, y, widgets.pad(label, cw - 1), colors.get("muted"), colors.get("background"))
    col = col + cw
  end
end

function widgets.compact_status_row(mon, x, y, values, widths, status, status_col)
  local col = x
  local highlight_col = status_col or 3
  for i, value in ipairs(values or {}) do
    local cw = math.max(3, (widths and widths[i]) or (#tostring(value or "-") + 2))
    local color_key = (i == highlight_col) and (status or "text") or (i == #values and "muted" or "text")
    ui.text(mon, col, y, widgets.pad(value or "-", cw - 1), colors.get(color_key), colors.get("background"))
    col = col + cw
  end
end

return widgets
