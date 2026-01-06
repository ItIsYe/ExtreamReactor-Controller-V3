local colors = require("shared.colors")

local ui = {}

local function redirect(mon, fn)
  local old = term.redirect(mon)
  fn()
  term.redirect(old)
end

function ui.setScale(mon, scale)
  if mon.setTextScale then mon.setTextScale(scale) end
end

function ui.clear(mon)
  redirect(mon, function()
    term.setBackgroundColor(colors.background)
    term.setTextColor(colors.text)
    term.clear()
    term.setCursorPos(1,1)
  end)
end

function ui.clearRegion(mon, x, y, w, h)
  redirect(mon, function()
    term.setBackgroundColor(colors.background)
    for row=y,y+h-1 do
      term.setCursorPos(x, row)
      term.write(string.rep(" ", w))
    end
  end)
end

function ui.text(mon, x, y, text, fg, bg)
  redirect(mon, function()
    term.setCursorPos(x, y)
    if bg then term.setBackgroundColor(bg) end
    if fg then term.setTextColor(fg) end
    term.write(text)
  end)
end

function ui.rightText(mon, x, y, w, text, fg, bg)
  local start = x + math.max(0, w - #text)
  ui.text(mon, start, y, text, fg, bg)
end

function ui.panel(mon, x, y, w, h, title, fg, bg)
  redirect(mon, function()
    term.setBackgroundColor(bg or colors.background)
    term.setTextColor(fg or colors.text)
    for row=y,y+h-1 do
      term.setCursorPos(x, row)
      term.write(string.rep(" ", w))
    end
    if title then
      term.setCursorPos(x+1, y)
      term.write(title)
    end
  end)
end

function ui.statusBadge(mon, x, y, text, status)
  local color = colors.get(status) or colors.get("OK")
  ui.text(mon, x, y, "[" .. text .. "]", colors.background, color)
end

function ui.progress(mon, x, y, w, percent, status)
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

function ui.table(mon, x, y, w, headers, rows, opts)
  opts = opts or {}
  redirect(mon, function()
    term.setBackgroundColor(opts.bg or colors.background)
    term.setTextColor(opts.fg or colors.text)
    local col_w = math.floor(w / #headers)
    term.setCursorPos(x, y)
    for _, h in ipairs(headers) do
      local txt = h
      if #txt > col_w then txt = txt:sub(1, col_w) end
      term.write(txt .. string.rep(" ", col_w - #txt))
    end
    for idx, row in ipairs(rows) do
      if y + idx <= y + (opts.max_rows or #rows) then
        term.setCursorPos(x, y + idx)
        for _, cell in ipairs(row) do
          local txt = tostring(cell)
          if #txt > col_w then txt = txt:sub(1, col_w) end
          term.write(txt .. string.rep(" ", col_w - #txt))
        end
      end
    end
  end)
end

return ui
