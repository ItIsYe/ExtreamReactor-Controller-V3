package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.colors = _G.colors or {
  black = 1, gray = 2, white = 3, lightGray = 4, cyan = 5, lime = 6,
  green = 7, yellow = 8, orange = 9, red = 10, blue = 11,
}

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}
_G.redstone = { setOutput = function() end }

local router_ui = require('nodes.fuel.router_ui')

local cursor_x, cursor_y = 1, 1
local cells = {}
local function row_text(y)
  local out = {}
  for x = 1, 80 do out[x] = (cells[y] and cells[y][x]) or ' ' end
  return table.concat(out)
end
local mon = {
  getSize = function() return 80, 20 end,
  setCursorPos = function(x, y) cursor_x, cursor_y = x, y end,
  setTextColor = function() end,
  setBackgroundColor = function() end,
  write = function(text)
    text = tostring(text or '')
    cells[cursor_y] = cells[cursor_y] or {}
    for i = 1, #text do
      cells[cursor_y][cursor_x] = text:sub(i, i)
      cursor_x = cursor_x + 1
    end
  end,
}
local dirty = {}
local function cached_text(target, x, y, text)
  local key = tostring(x) .. ':' .. tostring(y)
  if dirty[key] == tostring(text) then return end
  dirty[key] = tostring(text)
  target.setCursorPos(x, y)
  target.write(text)
end
local ui = {
  getSize = function(target) return target.getSize() end,
  text = cached_text,
  badge = function(target, x, y, text)
    cached_text(target, x, y, '[' .. tostring(text) .. ']')
  end,
}

local page = router_ui.new({
  redstone_router = {
    config = { logistics = { redstone_tree = {} } },
    get_tree = function() return {} end,
    valve_count = function() return 0 end,
    get_valve_status = function() return {} end,
    get_active_route = function() return {} end,
  },
  get_reactors = function() return { { id = 'RT-1', label = 'Reactor 1' } } end,
  log = function() end,
})
page:render(mon, ui, nil, true)

local row3 = row_text(3)
assert(row3:find('EDIT', 1, true), 'EDIT tab must remain visible after tree/status rendering')
assert(row3:find('TREE', 1, true), 'TREE tab must remain visible after tree/status rendering')
assert(page._ui.edit_btn, 'EDIT touch zone must exist')
assert(page._ui.empty_edit_btn, 'empty tree must expose explicit EDIT ROUTEN touch zone')

-- header() clears row 3 on every refresh. If TREE/EDIT still use the cached
-- core.ui primitives, an unchanged second frame skips both writes and the
-- controls disappear even though their touch zones survive.
page:render(mon, ui, nil, false)
row3 = row_text(3)
assert(row3:find('EDIT', 1, true) and row3:find('TREE', 1, true),
  'TREE and EDIT must be restored after every header refresh')

local b = page._ui.empty_edit_btn
assert(page:handle_touch(b.x1, b.y) == true, 'empty-state EDIT touch must be consumed')
assert(page._ui.mode == 'edit' and page._ui.edit_view == 'list', 'empty-state EDIT must open edit list')

page:render(mon, ui, nil, false)
assert(#(page._ui.reactor_btns or {}) == 1, 'edit list must expose discovered/configured reactor target')
print('fuel_router_edit_entry_test.lua: ok')
