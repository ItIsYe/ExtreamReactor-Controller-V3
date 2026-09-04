package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- CC:Tweaked's global colors API (distinct from shared/colors.lua's own
-- palette module, which reads numeric values from this global).
_G.colors = {
  black = 1, gray = 2, lightGray = 3, white = 4, cyan = 5, lime = 6,
  green = 7, yellow = 8, orange = 9, red = 10, blue = 11,
}

-- Regression test for mux.button() (core/mockup_ui.lua), added so router_ui.lua's
-- main action buttons (SPEICHERN/RESET/FERTIG/LEEREN/ABBRECHEN/EINLERNEN) render
-- as clearly visible, filled blocks instead of plain colored text -- unlike
-- badge()/data_row(), which only color the text itself.

local mux = require('core.mockup_ui')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function make_mon()
  local cells = {}
  local fg, bg = nil, nil
  local cursor_x, cursor_y = 1, 1
  return {
    setCursorPos = function(x, y) cursor_x, cursor_y = x, y end,
    setTextColor = function(c) fg = c end,
    setBackgroundColor = function(c) bg = c end,
    write = function(text)
      for i = 1, #text do
        cells[cursor_y] = cells[cursor_y] or {}
        cells[cursor_y][cursor_x + i - 1] = { ch = text:sub(i, i), fg = fg, bg = bg }
      end
    end,
    getSize = function() return 30, 12 end,
  }, cells
end

-- 1. Single-row button: entire width is filled with the status background,
--    not just the label text -- this is exactly what data_row()/badge()
--    do NOT do (they leave the surrounding background untouched).
do
  local mon, cells = make_mon()
  local bounds = mux.button(mon, 2, 5, 10, 'HI', 'OK', 1)
  assert_eq(bounds.x1, 2); assert_eq(bounds.x2, 11); assert_eq(bounds.y, 5); assert_eq(bounds.y2, 5)
  for x = 2, 11 do
    assert_eq(cells[5][x] ~= nil, true, 'button must fill every column of its row, including padding, at x=' .. x)
  end
end

-- 2. Multi-row button: every row in [y, y+h-1] must be filled, and the
--    returned y2 must span the full height for a correct multi-row touch
--    hit-test.
do
  local mon, cells = make_mon()
  local bounds = mux.button(mon, 2, 5, 12, 'FERTIG', 'OK', 2)
  assert_eq(bounds.y, 5); assert_eq(bounds.y2, 6, 'y2 must cover the second row for a 2-row button')
  assert_eq(cells[5] ~= nil, true, 'row 5 must be filled')
  assert_eq(cells[6] ~= nil, true, 'row 6 must be filled')
end

-- 3. A label longer than the available width must be truncated (fit()),
--    never overflow past the button's own bounds.
do
  local mon = make_mon()
  local bounds = mux.button(mon, 2, 5, 6, 'MUCH TOO LONG LABEL', 'OK', 1)
  assert_eq(bounds.x2 - bounds.x1 + 1, 6, 'button width must match the requested width regardless of label length')
end

print('mockup_ui_button_test.lua: ok')
