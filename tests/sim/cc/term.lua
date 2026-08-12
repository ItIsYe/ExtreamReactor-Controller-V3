-- tests/sim/cc/term.lua  Phase 4.5
-- Minimaler Term/Monitor-Stub: schreibt in Puffer, kein echtes Rendering.

local term_mod = {}

function term_mod.new(opts)
  opts = opts or {}
  local w = opts.width  or 51
  local h = opts.height or 19
  local buf = {}  -- { row = { char, ... } }
  local cx, cy = 1, 1
  local fg, bg = "f", "0"  -- CC Farben als Hex
  local visible = true

  for row = 1, h do
    buf[row] = {}
    for col = 1, w do buf[row][col] = " " end
  end

  local t = {}

  function t.write(text)
    text = tostring(text or "")
    for i = 1, #text do
      if cx <= w then
        buf[cy][cx] = text:sub(i,i)
        cx = cx + 1
      end
    end
  end

  function t.print(text)
    t.write(text)
    cy = cy + 1; cx = 1
    if cy > h then cy = h end
  end

  function t.clear()
    for row = 1, h do
      for col = 1, w do buf[row][col] = " " end
    end
  end

  function t.clearLine()
    for col = 1, w do buf[cy][col] = " " end
  end

  function t.setCursorPos(x, y)
    cx = math.max(1, math.min(w, x))
    cy = math.max(1, math.min(h, y))
  end

  function t.getCursorPos()   return cx, cy end
  function t.getSize()        return w, h end
  function t.isColor()        return true end
  function t.isColour()       return true end
  function t.setTextColor(c)  fg = c end
  function t.setTextColour(c) fg = c end
  function t.setBackgroundColor(c) bg = c end
  function t.setBackgroundColour(c) bg = c end
  function t.getTextColor()   return fg end
  function t.getBackgroundColor() return bg end
  function t.scroll(n)
    if n > 0 then
      for row = 1, h - n do buf[row] = buf[row+n] end
      for row = h-n+1, h do
        buf[row] = {}
        for col = 1, w do buf[row][col] = " " end
      end
    end
  end
  function t.blit(text, tc, bc) t.write(text) end
  function t.setVisible(v) visible = v end
  function t.current() return t end

  -- Test-Hilfsfunktionen
  function t._row(r) return table.concat(buf[r] or {}) end
  function t._buf() return buf end

  return t
end

return term_mod
