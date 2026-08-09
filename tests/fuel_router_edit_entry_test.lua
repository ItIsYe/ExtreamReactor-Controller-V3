package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}
_G.redstone = { setOutput = function() end }

local router_ui = require('nodes.fuel.router_ui')
local responsive = require('nodes.fuel.router_ui_responsive')

local cursor_x, cursor_y = 1, 1
local rows = {}
local mon = {
  getSize = function() return 80, 20 end,
  setCursorPos = function(x, y) cursor_x, cursor_y = x, y end,
  setTextColor = function() end,
  setBackgroundColor = function() end,
  write = function(text)
    text = tostring(text or '')
    rows[cursor_y] = rows[cursor_y] or {}
    rows[cursor_y][#rows[cursor_y] + 1] = { x = cursor_x, text = text }
    cursor_x = cursor_x + #text
  end,
}
local ui = {
  getSize = function(target) return target.getSize() end,
  text = function(target, x, y, text)
    target.setCursorPos(x, y)
    target.write(text)
  end,
  badge = function(target, x, y, text)
    target.setCursorPos(x, y)
    target.write('[' .. tostring(text) .. ']')
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
responsive.attach(page)
page:render(mon, ui, nil, true)

local row3 = ''
for _, part in ipairs(rows[3] or {}) do row3 = row3 .. part.text end
assert(row3:find('EDIT', 1, true), 'EDIT tab must remain visible after tree/status rendering')
assert(page._ui.edit_btn, 'EDIT touch zone must exist')
assert(page._ui.empty_edit_btn, 'empty tree must expose explicit EDIT ROUTEN touch zone')

local b = page._ui.empty_edit_btn
assert(page:handle_touch(b.x1, b.y) == true, 'empty-state EDIT touch must be consumed')
assert(page._ui.mode == 'edit' and page._ui.edit_view == 'list', 'empty-state EDIT must open edit list')

rows = {}
page:render(mon, ui, nil, false)
assert(#(page._ui.reactor_btns or {}) == 1, 'edit list must expose discovered/configured reactor target')
print('fuel_router_edit_entry_test.lua: ok')
