local colors = require("shared.colors")
local logger = require("core.logger")

local ui = {}
local dirty_cache = setmetatable({}, { __mode = "k" })
local monitor_state = setmetatable({}, { __mode = "k" })

local function report_redirect_error(context, err)
  local message = "UI redirect failure"
  if context then
    message = message .. " context=" .. tostring(context)
  end
  message = message .. " err=" .. tostring(err)
  if logger and logger.log then
    logger.log("UI", "ERROR: " .. message, "ERROR")
  else
    print("WARN: " .. message)
  end
end

local function redirect(mon, fn, context)
  if not mon or not term or not term.redirect or type(fn) ~= "function" then
    return
  end

  local old = nil
  if term.current then
    local ok_current, current = pcall(term.current)
    if ok_current then
      old = current
    end
  end

  local ok_redirect, previous_or_err = pcall(term.redirect, mon)
  if not ok_redirect then
    report_redirect_error(context or "redirect", previous_or_err)
    return
  end
  if previous_or_err ~= nil then
    old = previous_or_err
  end

  local ok_exec, exec_err = xpcall(fn, function(err)
    if debug and debug.traceback then
      return debug.traceback(err, 2)
    end
    return tostring(err)
  end)

  local ok_restore, restore_err = pcall(term.redirect, old)
  if not ok_restore then
    report_redirect_error(context or "restore", restore_err)
  end
  if not ok_exec then
    report_redirect_error(context or "render", exec_err)
  end
end

local function is_dirty(mon, key, snapshot)
  dirty_cache[mon] = dirty_cache[mon] or {}
  if dirty_cache[mon][key] == snapshot then
    return false
  end
  dirty_cache[mon][key] = snapshot
  return true
end

local function state_for(mon)
  monitor_state[mon] = monitor_state[mon] or { scale = nil, size = nil }
  return monitor_state[mon]
end

local function safe_monitor_call(mon, method, ...)
  if not mon or type(mon[method]) ~= "function" then
    return false, "missing method"
  end
  local fn = mon[method]
  return pcall(fn, ...)
end

function ui.invalidate(mon)
  dirty_cache[mon] = nil
end

function ui.getSize(mon)
  if not mon or type(mon.getSize) ~= "function" then
    return nil
  end
  local ok, w, h = safe_monitor_call(mon, "getSize")
  if ok and type(w) == "number" and type(h) == "number" then
    return w, h
  end
  return nil
end

function ui.setScale(mon, scale)
  if not mon then return end
  local numeric_scale = tonumber(scale)
  if type(numeric_scale) ~= "number" then
    if logger and logger.log then
      logger.log("UI", "WARN: Ignoring invalid monitor scale value=" .. tostring(scale), "WARN")
    end
    return
  end
  local normalized = math.floor((numeric_scale * 2) + 0.5) / 2
  if normalized < 0.5 then normalized = 0.5 end
  if normalized > 5 then normalized = 5 end
  local state = state_for(mon)
  if state.scale == normalized then
    return
  end
  if mon.setTextScale then
    local ok, err = safe_monitor_call(mon, "setTextScale", normalized)
    if not ok and logger and logger.log then
      logger.log("UI", "WARN: setTextScale failed: " .. tostring(err), "WARN")
      return
    end
  end
  state.scale = normalized
  ui.invalidate(mon)
end

function ui.clear(mon)
  if not mon then return end
  ui.invalidate(mon)
  redirect(mon, function()
    term.setBackgroundColor(colors.background)
    term.setTextColor(colors.text)
    term.clear()
    term.setCursorPos(1,1)
  end, "ui.clear")
end

function ui.clearRegion(mon, x, y, w, h)
  if not mon then return end
  if not w or not h or w <= 0 or h <= 0 then
    return
  end
  redirect(mon, function()
    term.setBackgroundColor(colors.background)
    for row = y, y + h - 1 do
      term.setCursorPos(x, row)
      term.write(string.rep(" ", w))
    end
  end, "ui.clearRegion")
end

function ui.text(mon, x, y, text, fg, bg)
  if not mon then return end
  local safe_text = tostring(text or "")
  local width = #safe_text
  local snapshot = table.concat({ safe_text, tostring(fg), tostring(bg) }, "|")
  local key = ("text:%d:%d"):format(x, y)
  if not is_dirty(mon, key, snapshot) then return end
  local state = state_for(mon)
  local prev_width = state[key]
  state[key] = width
  redirect(mon, function()
    term.setCursorPos(x, y)
    if bg then term.setBackgroundColor(bg) end
    if fg then term.setTextColor(fg) end
    term.write(safe_text)
    if prev_width and prev_width > width then
      term.write(string.rep(" ", prev_width - width))
    end
  end, "ui.text")
end

function ui.rightText(mon, x, y, w, text, fg, bg)
  if not mon then return end
  local safe_text = tostring(text or "")
  local start = x + math.max(0, w - #safe_text)
  ui.text(mon, start, y, safe_text, fg, bg)
end

function ui.panel(mon, x, y, w, h, title, status)
  if not mon then return end
  if not w or not h or w <= 0 or h <= 0 then
    return
  end
  local snapshot = table.concat({ tostring(w), tostring(h), tostring(title), tostring(status) }, "|")
  local key = ("panel:%d:%d"):format(x, y)
  if not is_dirty(mon, key, snapshot) then return end
  redirect(mon, function()
    local border_color = colors.get(status) or colors.get("accent") or colors.text
    term.setBackgroundColor(colors.background)
    term.setTextColor(colors.text)
    for row = y, y + h - 1 do
      term.setCursorPos(x, row)
      term.write(string.rep(" ", w))
    end

    if w == 1 or h == 1 then
      if title then
        term.setCursorPos(x, y)
        term.setTextColor(border_color)
        term.write(tostring(title):sub(1, w))
      end
      return
    end

    local top = "+" .. string.rep("-", math.max(0, w - 2)) .. "+"
    local mid = "|" .. string.rep(" ", math.max(0, w - 2)) .. "|"
    term.setTextColor(border_color)
    term.setCursorPos(x, y)
    term.write(top)
    for row = y + 1, y + h - 2 do
      term.setCursorPos(x, row)
      term.write(mid)
    end
    term.setCursorPos(x, y + h - 1)
    term.write(top)

    if title and w > 4 then
      local clipped = tostring(title):gsub("\n", " "):gsub("\r", " ")
      clipped = clipped:sub(1, w - 4)
      term.setCursorPos(x + 2, y)
      term.setTextColor(border_color)
      term.write(clipped)
    end
  end, "ui.panel")
end

function ui.badge(mon, x, y, text, status)
  if not mon then return end
  local color = colors.get(status) or colors.get("OK")
  ui.text(mon, x, y, " " .. text .. " ", colors.background, color)
end

function ui.bigNumber(mon, x, y, label, value, unit, status)
  if not mon then return end
  local value_text = tostring(value or "")
  local unit_text = unit and (" " .. unit) or ""
  local snapshot = table.concat({ tostring(label), value_text, unit_text, tostring(status) }, "|")
  local key = ("bignumber:%d:%d"):format(x, y)
  if not is_dirty(mon, key, snapshot) then return end
  local width = math.max(12, #tostring(label or ""), #value_text + #unit_text)
  ui.clearRegion(mon, x, y, width + 1, 2)
  ui.text(mon, x, y, tostring(label or ""), colors.get("text"), colors.get("background"))
  ui.text(mon, x, y + 1, value_text .. unit_text, colors.get(status or "OK"), colors.get("background"))
end

function ui.progress(mon, x, y, w, percent, status)
  if not mon then return end
  if not w or w <= 0 then
    return
  end
  local pct = tonumber(percent) or 0
  if pct < 0 then pct = 0 end
  if pct > 1 then pct = 1 end
  local snapshot = table.concat({ tostring(w), tostring(pct), tostring(status) }, "|")
  local key = ("progress:%d:%d"):format(x, y)
  if not is_dirty(mon, key, snapshot) then return end
  local fill = math.floor(w * pct)
  redirect(mon, function()
    term.setCursorPos(x, y)
    term.setBackgroundColor(colors.get("OFFLINE"))
    term.write(string.rep(" ", w))
    term.setCursorPos(x, y)
    term.setBackgroundColor(colors.get(status) or colors.get("OK"))
    term.write(string.rep(" ", fill))
  end, "ui.progress")
end

function ui.list(mon, x, y, w, rows, opts)
  if not mon then return end
  opts = opts or {}
  rows = rows or {}
  if not w or w <= 0 then
    return
  end
  local snapshot = nil
  if textutils and textutils.serialize then
    local ok, result = pcall(textutils.serialize, { rows = rows, opts = opts })
    if ok then
      snapshot = result
    end
  end
  snapshot = snapshot or tostring(rows) .. "|" .. tostring(opts)
  local key = ("list:%d:%d:%d"):format(x, y, w)
  if not is_dirty(mon, key, snapshot) then return end
  local max_rows = opts.max_rows or #rows
  if max_rows <= 0 then
    return
  end
  for idx = 1, max_rows do
    local row = rows[idx]
    if not row then
      ui.text(mon, x, y + idx - 1, string.rep(" ", w), opts.fg or colors.text, opts.bg or colors.background)
    else
      local text = row
      local status = nil
      if type(row) == "table" then
        text = row.text or ""
        status = row.status
      end
      text = tostring(text)
      if #text > w then text = text:sub(1, w) end
      ui.text(mon, x, y + idx - 1, text .. string.rep(" ", w - #text), colors.get(status) or (opts.fg or colors.text), opts.bg or colors.background)
    end
  end
end

function ui.begin_frame(mon)
  if not mon then
    return
  end
  local w, h = ui.getSize(mon)
  if not w or not h then
    return
  end
  local state = state_for(mon)
  local size_key = ("%dx%d"):format(w, h)
  if state.size ~= size_key then
    state.size = size_key
    ui.invalidate(mon)
  end
end

function ui.sparkline(values, width)
  local blocks = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  if not width or width <= 0 then
    return ""
  end
  if not values or #values == 0 then return string.rep(" ", width) end
  local numeric = {}
  for _, v in ipairs(values) do
    if type(v) == "number" then
      table.insert(numeric, v)
    end
  end
  if #numeric == 0 then
    return string.rep(" ", width)
  end
  local min, max = numeric[1], numeric[1]
  for _, v in ipairs(numeric) do
    if v < min then min = v end
    if v > max then max = v end
  end
  local range = max - min
  if range == 0 then
    local mid = blocks[4]
    return string.rep(mid, width)
  end
  local step = math.max(1, math.floor(#numeric / width))
  local out = {}
  for i = 1, #numeric, step do
    local v = numeric[i]
    local idx = math.floor(((v - min) / range) * (#blocks - 1)) + 1
    table.insert(out, blocks[math.min(#blocks, math.max(1, idx))])
    if #out >= width then break end
  end
  while #out < width do table.insert(out, blocks[1]) end
  return table.concat(out)
end

function ui.table(mon, x, y, w, headers, rows, opts)
  if not mon then return end
  opts = opts or {}
  rows = rows or {}
  if not headers or #headers == 0 then
    return
  end
  if not w or w <= 0 then
    return
  end
  redirect(mon, function()
    term.setBackgroundColor(opts.bg or colors.background)
    term.setTextColor(opts.fg or colors.text)
    local col_w = math.max(1, math.floor(w / #headers))
    term.setCursorPos(x, y)
    for _, h in ipairs(headers) do
      local txt = tostring(h or "")
      if #txt > col_w then txt = txt:sub(1, col_w) end
      term.write(txt .. string.rep(" ", col_w - #txt))
    end
    for idx, row in ipairs(rows) do
      if y + idx <= y + (opts.max_rows or #rows) then
        term.setCursorPos(x, y + idx)
        for _, cell in ipairs(row) do
          local txt = tostring(cell or "")
          if #txt > col_w then txt = txt:sub(1, col_w) end
          term.write(txt .. string.rep(" ", col_w - #txt))
        end
      end
    end
  end, "ui.table")
end

return ui
