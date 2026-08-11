package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local mux = require('core.mockup_ui')

local function run(width)
  local writes = {}
  local cursor_x, cursor_y = 1, 1
  local mon = {
    setCursorPos = function(x, y) cursor_x, cursor_y = x, y end,
    setBackgroundColor = function() end,
    setTextColor = function() end,
    write = function(value)
      writes[#writes + 1] = { x = cursor_x, y = cursor_y, text = tostring(value) }
    end,
  }

  local footer = mux.footer_nav(mon, 12, width, {
    left = '< ZURUECK', center = 'FUEL ROUTING TREE WITH LONG TITLE', right = 'WEITER >', inset = 3,
  })
  local left_end = math.floor(width / 3)
  local right_start = math.floor((width * 2) / 3) + 1

  assert(footer.left.x1 == 1 and footer.left.x2 == left_end and footer.left.y == 12,
    'left footer must own the complete left third')
  assert(footer.right.x1 == right_start and footer.right.x2 == width and footer.right.y == 12,
    'right footer must own the complete right third')
  assert(#writes == 4, 'footer must draw clear row plus left, center and right text')

  local left, center, right = writes[2], writes[3], writes[4]
  assert(left.x >= 1 and left.x + #left.text - 1 <= left_end,
    'left label must stay inside the left third')
  assert(center.x >= left_end + 1 and center.x + #center.text - 1 < right_start,
    'center label must stay inside the middle third')
  assert(right.x >= right_start and right.x + #right.text - 1 <= width,
    'right label must stay inside the right third')
end

for _, width in ipairs({ 18, 30, 40, 51, 80 }) do run(width) end

print('mockup_footer_nav_layout_test.lua: ok')
