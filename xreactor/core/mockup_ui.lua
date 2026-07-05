local colors = require("shared.colors")

local M = {}

local ICONS = {
  energy = "E",
  reactor = "R",
  turbine = "T",
  water = "W",
  storage = "S",
  fuel = "F",
  recycle = "P",
  config = "C",
  warning = "!",
  ok = "*",
  input = "+",
  output = "-",
  flow = "~",
  master = "M",
  network = "N",
  temperature = "T",
}

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return false end
  return pcall(obj[method], ...)
end

local function fit(text, width)
  local s = tostring(text or ""):gsub("\n", " "):gsub("\r", " ")
  local w = math.max(0, tonumber(width) or #s)
  if w <= 0 then return "" end
  if #s <= w then return s end
  if w <= 2 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "~"
end

local function write(mon, x, y, text, fg, bg)
  if not mon then return end
  safe_call(mon, "setCursorPos", x, y)
  if bg then safe_call(mon, "setBackgroundColor", bg) end
  if fg then safe_call(mon, "setTextColor", fg) end
  safe_call(mon, "write", tostring(text or ""))
end

local function fill(mon, x, y, w, h, bg)
  if not mon or w <= 0 or h <= 0 then return end
  safe_call(mon, "setBackgroundColor", bg or colors.get("background"))
  for row = y, y + h - 1 do
    safe_call(mon, "setCursorPos", x, row)
    safe_call(mon, "write", string.rep(" ", w))
  end
end

function M.fit(text, width) return fit(text, width) end
function M.icon(name) return ICONS[name] or "*" end

function M.clear(mon)
  local w, h = mon.getSize()
  fill(mon, 1, 1, w, h, colors.get("background"))
end

function M.header(mon, opts)
  opts = opts or {}
  local w = ({ mon.getSize() })[1]
  local status = opts.status or "OK"
  local accent = colors.get(status) or colors.get("accent")
  fill(mon, 1, 1, w, 3, colors.get("background"))
  write(mon, 1, 1, string.rep(" ", w), colors.get("background"), accent)
  local icon = opts.icon and ("[" .. M.icon(opts.icon) .. "] ") or ""
  write(mon, 2, 2, fit(icon .. tostring(opts.title or "SYSTEM"), math.max(1, w - 16)), colors.get("text"), colors.get("background"))
  if opts.page then
    local p = tostring(opts.page)
    write(mon, math.max(2, w - #p - 1), 2, p, colors.get("muted"), colors.get("background"))
  end
  if opts.node_id and w >= 34 then
    local node = tostring(opts.node_id)
    local x = math.max(2, math.floor(w * 0.50) - math.floor(#node / 2))
    write(mon, x, 2, fit(node, math.max(1, w - x - 12)), colors.get("muted"), colors.get("background"))
  end
end

function M.status_dot(mon, x, y, label, status)
  local key = status or "OK"
  local dot = key == "OK" and "*" or "!"
  write(mon, x, y, dot .. " " .. tostring(label or key), colors.get(key), colors.get("background"))
end

function M.section(mon, x, y, w, title, status, icon)
  local key = status or "LIMITED"
  local accent = colors.get(key) or colors.get("accent")
  local prefix = icon and ("[" .. M.icon(icon) .. "] ") or ""
  write(mon, x, y, fit(prefix .. tostring(title or ""), w), accent, colors.get("background"))
  if w >= 4 then write(mon, x, y + 1, string.rep("-", w), colors.get("OFFLINE"), colors.get("background")) end
end

function M.card(mon, x, y, w, h, opts)
  opts = opts or {}
  if w < 3 or h < 3 then return end
  local key = opts.status or "LIMITED"
  local border = colors.get(key) or colors.get("accent")
  local bg = opts.bg or colors.get("background")
  fill(mon, x, y, w, h, bg)
  write(mon, x, y, "+" .. string.rep("-", w - 2) .. "+", border, bg)
  for row = y + 1, y + h - 2 do
    write(mon, x, row, "|", border, bg)
    write(mon, x + w - 1, row, "|", border, bg)
  end
  write(mon, x, y + h - 1, "+" .. string.rep("-", w - 2) .. "+", border, bg)
  if opts.title and w > 6 then
    local icon = opts.icon and ("[" .. M.icon(opts.icon) .. "] ") or ""
    write(mon, x + 2, y, fit(icon .. tostring(opts.title), w - 4), border, bg)
  end
end

function M.metric_card(mon, x, y, w, h, opts)
  opts = opts or {}
  M.card(mon, x, y, w, h, opts)
  local key = opts.status or "OK"
  local label = tostring(opts.label or "")
  local value = tostring(opts.value or "-")
  local unit = opts.unit and (" " .. tostring(opts.unit)) or ""
  local icon = opts.icon and ("[" .. M.icon(opts.icon) .. "] ") or ""
  write(mon, x + 2, y + 1, fit(icon .. label, math.max(1, w - 4)), colors.get("muted"), colors.get("background"))
  if h >= 4 then write(mon, x + 2, y + 2, fit(value .. unit, math.max(1, w - 4)), colors.get(key), colors.get("background")) end
end

function M.segmented_bar(mon, x, y, w, percent, status, opts)
  opts = opts or {}
  local pct = math.max(0, math.min(1, tonumber(percent) or 0))
  local segments = math.max(1, tonumber(opts.segments) or math.floor(w / 2))
  local seg_w = math.max(1, math.floor(w / segments))
  local active = math.floor((pct * segments) + 0.5)
  local key = status or "OK"
  for i = 1, segments do
    local sx = x + (i - 1) * seg_w
    if sx > x + w - 1 then break end
    local width = math.min(seg_w - (seg_w > 1 and 1 or 0), x + w - sx)
    if width < 1 then width = 1 end
    local bg = i <= active and colors.get(key) or colors.get("OFFLINE")
    write(mon, sx, y, string.rep(" ", width), colors.get("background"), bg)
  end
end

function M.outlined_progress(mon, x, y, w, percent, status, label)
  if w < 5 then return end
  local pct = math.max(0, math.min(1, tonumber(percent) or 0))
  local key = status or "OK"
  local inner = w - 2
  local filled = math.floor(inner * pct + 0.5)
  write(mon, x, y, "[", colors.get("muted"), colors.get("background"))
  for i = 1, inner do
    local bg = i <= filled and colors.get(key) or colors.get("OFFLINE")
    write(mon, x + i, y, " ", colors.get("background"), bg)
  end
  write(mon, x + w - 1, y, "]", colors.get("muted"), colors.get("background"))
  if label and #tostring(label) <= inner then
    local txt = tostring(label)
    local sx = x + 1 + math.max(0, math.floor((inner - #txt) / 2))
    write(mon, sx, y, txt, colors.get("text"), colors.get("background"))
  end
end

function M.data_row(mon, x, y, w, opts)
  opts = opts or {}
  local key = opts.status or "text"
  local icon = opts.icon and ("[" .. M.icon(opts.icon) .. "] ") or ""
  local left = icon .. tostring(opts.label or "")
  local right = tostring(opts.value or "")
  local left_w = math.max(1, w - #right - 1)
  local line = fit(left, left_w) .. string.rep(" ", math.max(1, w - math.min(#left, left_w) - #right)) .. right
  write(mon, x, y, fit(line, w), colors.get(key), colors.get("background"))
end

function M.kpi_strip(mon, x, y, w, items)
  items = items or {}
  if #items == 0 then return end
  local cell_w = math.max(5, math.floor((w - (#items - 1)) / #items))
  for i, item in ipairs(items) do
    local cx = x + (i - 1) * (cell_w + 1)
    local icon = item.icon and ("[" .. M.icon(item.icon) .. "] ") or ""
    write(mon, cx, y, fit(icon .. tostring(item.label or ""), cell_w), colors.get("muted"), colors.get("background"))
    write(mon, cx, y + 1, fit(tostring(item.value or "-"), cell_w), colors.get(item.status or "OK"), colors.get("background"))
  end
end

function M.banner(mon, x, y, w, text, status, icon)
  local key = status or "OK"
  local bg = colors.get(key)
  local prefix = icon and ("[" .. M.icon(icon) .. "] ") or ""
  local content = fit(prefix .. tostring(text or ""), math.max(1, w - 2))
  local left = math.max(0, math.floor((w - #content) / 2))
  write(mon, x, y, string.rep(" ", w), colors.get("background"), bg)
  write(mon, x + left, y, content, colors.get("background"), bg)
end

function M.table_header(mon, x, y, w, columns)
  columns = columns or {}
  local pos = x
  for _, col in ipairs(columns) do
    local cw = tonumber(col.width) or math.max(1, math.floor(w / math.max(1, #columns)))
    write(mon, pos, y, fit(col.label or "", cw), colors.get("muted"), colors.get("background"))
    pos = pos + cw
    if pos >= x + w then break end
  end
  write(mon, x, y + 1, string.rep("-", w), colors.get("OFFLINE"), colors.get("background"))
end

-- Fix (2026-07-05): footer_nav() zeichnete bisher NUR Text ("< ZURUECK" /
-- "WEITER >"), gab aber nie Touch-Koordinaten zurueck. Der Router
-- (core/ui_router.lua) zeichnet danach an derselben Zeile seinen eigenen
-- "< Page X/Y >"-Indikator und registriert NUR dessen eigene, unsichtbar
-- gewordene Touch-Zonen (self.footer.prev/next) — die tatsaechlich
-- sichtbaren Mockup-Buttons hatten also nie eine funktionierende Touch-
-- Zone dahinter, obwohl sie wie klickbare Buttons aussahen. Jetzt gibt
-- diese Funktion { left = {x1,x2,y}, right = {x1,x2,y} } zurueck, das der
-- Aufrufer (ui_router.lua) nutzt um seine eigenen Touch-Zonen auf die
-- tatsaechlich sichtbaren Buttons zu legen statt auf seinen eigenen,
-- ueberschriebenen Footer-Text.
function M.footer_nav(mon, y, w, opts)
  opts = opts or {}
  write(mon, 1, y, string.rep(" ", w), colors.get("text"), colors.get("OFFLINE"))
  local left = opts.left or "< ZURUECK"
  local center = opts.center or ""
  local right = opts.right or "WEITER >"
  local left_text = fit(left, math.floor(w / 3) - 1)
  write(mon, 2, y, left_text, colors.get("text"), colors.get("OFFLINE"))
  if center ~= "" then
    local cx = math.max(2, math.floor((w - #center) / 2))
    write(mon, cx, y, fit(center, math.floor(w / 3)), colors.get("muted"), colors.get("OFFLINE"))
  end
  local right_text = fit(right, math.floor(w / 3))
  local rx = math.max(2, w - #right_text - 1)
  write(mon, rx, y, right_text, colors.get("text"), colors.get("OFFLINE"))
  return {
    left = { x1 = 2, x2 = 2 + #left_text - 1, y = y },
    right = { x1 = rx, x2 = rx + #right_text - 1, y = y },
  }
end

function M.warning_box(mon, x, y, w, lines, status)
  lines = lines or {}
  local h = math.max(3, #lines + 2)
  M.card(mon, x, y, w, h, { title = "WARNUNG", status = status or "WARNING", icon = "warning" })
  for i, line in ipairs(lines) do
    if i > h - 2 then break end
    write(mon, x + 2, y + i, fit(line, w - 4), colors.get(status or "WARNING"), colors.get("background"))
  end
end

return M
