local ui = require("core.ui")
local colors = require("shared.colors")

local widgets = {}

local function clamp_int(value, min_v, max_v, fallback)
  local n = tonumber(value)
  if not n then n = fallback or min_v or 1 end
  n = math.floor(n)
  if min_v and n < min_v then n = min_v end
  if max_v and n > max_v then n = max_v end
  return n
end

local function sanitize_text(text)
  return tostring(text or ""):gsub("\n", " "):gsub("\r", " ")
end

local function safe_space(count)
  local n = clamp_int(count, 0, 512, 0)
  return n > 0 and string.rep(" ", n) or ""
end

function widgets.fit(text, width)
  local raw = sanitize_text(text)
  local w = clamp_int(width, 1, 512, #raw)
  if #raw <= w then return raw end
  if w <= 2 then return string.sub(raw, 1, w) end
  return string.sub(raw, 1, w - 1) .. "~"
end

function widgets.pad(text, width)
  local w = clamp_int(width, 1, 512, 1)
  local clipped = widgets.fit(text, w)
  local missing = math.max(0, w - #clipped)
  return clipped .. safe_space(missing)
end

function widgets.status_badge(mon, x, y, text, status, max_width)
  local max_w = clamp_int(max_width, 4, 96, 24)
  local label = widgets.fit(text or "", max_w)
  ui.badge(mon, x, y, label, status or "OK")
  return #label + 2
end

function widgets.progress_bar(mon, x, y, w, percent, status)
  ui.progress(mon, x, y, clamp_int(w, 3, 512, 3), percent or 0, status or "OK")
end

function widgets.card(mon, x, y, w, h, title, status)
  local width = clamp_int(w, 8, 512, 8)
  local height = clamp_int(h, 3, 512, 3)
  ui.panel(mon, x, y, width, height, widgets.fit(title or "", math.max(4, width - 4)), status or "OK")
end

function widgets.panel_box(mon, x, y, w, h, title, status)
  local width = clamp_int(w, 8, 512, 8)
  local height = clamp_int(h, 3, 512, 3)
  widgets.card(mon, x, y, width, height, title, status)
  return { x = x + 1, y = y + 1, w = math.max(1, width - 2), h = math.max(1, height - 2) }
end

function widgets.layout_button(mon, x, y, label, status)
  local text = widgets.fit((label or "LAYOUT"):upper(), 10)
  local badge = "<" .. text .. ">"
  ui.badge(mon, x, y, badge, status or "LIMITED")
  return { x1 = x, x2 = x + #badge + 1, y = y }
end

function widgets.stat_card(mon, x, y, w, title, value, meta, status, progress)
  local width = clamp_int(w, 12, 512, 12)
  ui.panel(mon, x, y, width, 5, widgets.fit(title or "", width - 3), status or "OK")
  ui.text(mon, x + 1, y + 1, widgets.fit(tostring(value or "-"), width - 2), colors.get(status or "text"), colors.get("background"))
  if meta then ui.text(mon, x + 1, y + 2, widgets.fit(tostring(meta), width - 2), colors.get("muted"), colors.get("background")) end
  if progress ~= nil then ui.progress(mon, x + 1, y + 3, math.max(6, width - 2), math.max(0, math.min(100, progress)), status or "OK") end
end

function widgets.alert_row(mon, x, y, width, alert, opts)
  opts = opts or {}
  local row_w = clamp_int(width, 20, 512, 24)
  local status = tostring((alert and alert.status) or "INFO")
  local title_w = clamp_int(math.floor(row_w * (opts.compact and 0.24 or 0.28)), 8, 24, 12)
  local text_w = math.max(8, row_w - (11 + title_w))
  ui.badge(mon, x, y, widgets.fit(status, 7), status)
  ui.text(mon, x + 9, y, widgets.pad((alert and alert.title) or "Alert", title_w), colors.get("text"), colors.get("background"))
  ui.text(mon, x + 10 + title_w, y, widgets.fit((alert and alert.text) or "", text_w), colors.get("muted"), colors.get("background"))
end

function widgets.compact_header(mon, x, y, labels, widths)
  labels = labels or {}
  local col = x
  for i, label in ipairs(labels or {}) do
    local cw = clamp_int((widths and widths[i]) or (#tostring(label) + 2), 3, 120, 8)
    ui.text(mon, col, y, widgets.pad(label, cw - 1), colors.get("muted"), colors.get("background"))
    col = col + cw
  end
end

function widgets.compact_status_row(mon, x, y, values, widths, status, status_col)
  values = values or {}
  local col = x
  local highlight_col = status_col or 3
  for i, value in ipairs(values or {}) do
    local cw = clamp_int((widths and widths[i]) or (#tostring(value or "-") + 2), 3, 120, 8)
    local color_key = (i == highlight_col) and (status or "text") or (i == #values and "muted" or "text")
    ui.text(mon, col, y, widgets.pad(value or "-", cw - 1), colors.get(color_key), colors.get("background"))
    col = col + cw
  end
end

return widgets
