local colors = require("shared.colors")

local ui = {}
local dirty_cache = setmetatable({}, { __mode = "k" })

local function redirect(mon, fn)
  if not mon or not term or not term.redirect then
    return
  end
  local old = term.redirect(mon)
  fn()
  term.redirect(old)
end

local function is_dirty(mon, key, snapshot)
  dirty_cache[mon] = dirty_cache[mon] or {}
  if dirty_cache[mon][key] == snapshot then
    return false
  end
  dirty_cache[mon][key] = snapshot
  return true
end

function ui.setScale(mon, scale)
  if not mon then return end
  if mon.setTextScale then mon.setTextScale(scale) end
end

function ui.clear(mon)
  if not mon then return end
  redirect(mon, function()
    term.setBackgroundColor(colors.background)
    term.setTextColor(colors.text)
    term.clear()
    term.setCursorPos(1,1)
  end)
end

function ui.clearRegion(mon, x, y, w, h)
  if not mon then return end
  if not w or not h or w <= 0 or h <= 0 then
    return
  end
  redirect(mon, function()
    term.setBackgroundColor(colors.background)
    for row=y,y+h-1 do
      term.setCursorPos(x, row)
      term.write(string.rep(" ", w))
    end
  end)
end

function ui.text(mon, x, y, text, fg, bg)
  if not mon then return end
  local safe_text = tostring(text or "")
  local snapshot = table.concat({ safe_text, tostring(fg), tostring(bg) }, "|")
  local key = ("text:%d:%d"):format(x, y)
  if not is_dirty(mon, key, snapshot) then return end
  redirect(mon, function()
    term.setCursorPos(x, y)
    if bg then term.setBackgroundColor(bg) end
    if fg then term.setTextColor(fg) end
    term.write(safe_text)
  end)
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
    term.setBackgroundColor(colors.background)
    term.setTextColor(colors.text)
    for row=y,y+h-1 do
      term.setCursorPos(x, row)
      term.write(string.rep(" ", w))
    end
    if title then
      term.setCursorPos(x+1, y)
      term.setTextColor(colors.get(status) or colors.get("accent"))
      term.write(title)
    end
  end)
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
  local snapshot = table.concat({ tostring(w), tostring(percent), tostring(status) }, "|")
  local key = ("progress:%d:%d"):format(x, y)
  if not is_dirty(mon, key, snapshot) then return end
  local fill = math.floor(w * math.max(0, math.min(1, percent)))
  redirect(mon, function()
    term.setCursorPos(x, y)
    term.setBackgroundColor(colors.get("OFFLINE"))
    term.write(string.rep(" ", w))
    term.setCursorPos(x, y)
    term.setBackgroundColor(colors.get(status) or colors.get("OK"))
    term.write(string.rep(" ", fill))
  end)
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

function ui.sparkline(values, width)
  local blocks = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  if not width or width <= 0 then
    return ""
  end
  if not values or #values == 0 then return string.rep(" ", width) end
  local min, max = values[1], values[1]
  for _, v in ipairs(values) do
    if v < min then min = v end
    if v > max then max = v end
  end
  local range = max - min
  if range == 0 then
    local mid = blocks[4]
    return string.rep(mid, width)
  end
  local step = math.max(1, math.floor(#values / width))
  local out = {}
  for i = 1, #values, step do
    local v = values[i]
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
  end)
end

return ui
