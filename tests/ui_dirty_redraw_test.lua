local writes = {}

_G.colors = {
  white = 1,
  black = 2,
  green = 3,
  red = 4,
  yellow = 5,
  gray = 6,
  lightGray = 7,
  orange = 8,
  blue = 9,
}
_G.term = {
  _current = nil,
  redirect = function(mon)
    local old = _G.term._current
    _G.term._current = mon
    return old
  end,
  setBackgroundColor = function() end,
  setTextColor = function() end,
  clear = function() writes[#writes + 1] = { op = "clear" } end,
  setCursorPos = function(x, y) writes[#writes + 1] = { op = "cursor", x = x, y = y } end,
  write = function(text) writes[#writes + 1] = { op = "write", text = text } end,
}

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local ui = require("core.ui")

local mon = {
  getSize = function() return 20, 8 end,
  setTextScale = function() end,
}

ui.begin_frame(mon)
ui.text(mon, 1, 1, "abcdef", 1, 2)
local first_count = #writes
ui.text(mon, 1, 1, "abcdef", 1, 2)
if #writes ~= first_count then
  error("unchanged dirty text should not redraw")
end

ui.text(mon, 1, 1, "abc", 1, 2)
local penultimate = writes[#writes - 1]
local last = writes[#writes]
if not penultimate or penultimate.op ~= "write" or penultimate.text ~= "abc" or not last or last.op ~= "write" or last.text ~= "   " then
  error("shorter redraw should clear trailing characters")
end

mon.getSize = function() return 30, 8 end
ui.begin_frame(mon)
local before_resize = #writes
ui.text(mon, 1, 1, "abc", 1, 2)
if #writes == before_resize then
  error("resize should invalidate dirty cache")
end

print("ui_dirty_redraw_test.lua: ok")
