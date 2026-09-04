package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer den Einzelbildschirm der FUEL-Router-Seite
-- (2026-09-04-Rewrite): kein TREE/EDIT-Tabpaar mehr -- der Statuspunkt
-- "REAKTOREN x/y BEREIT" (Zeile 3) und der EINLERNEN-Button (Zeile 4)
-- muessen bei einer leeren Reaktorliste sichtbar bleiben, auch nach einem
-- zweiten, nicht loeschenden Refresh (header() leert Zeile 3 bei jedem
-- Aufruf -- wenn TREE/EDIT bzw. jetzt REAKTOREN/EINLERNEN weiterhin die
-- gecachten core.ui-Primitiven benutzen wuerden, wuerde ein unveraendertes
-- zweites Frame beide Schreibvorgaenge ueberspringen und die Steuerelemente
-- verschwinden, obwohl ihre Touch-Zonen erhalten bleiben).

_G.colors = _G.colors or {
  black = 1, gray = 2, white = 3, lightGray = 4, cyan = 5, lime = 6,
  green = 7, yellow = 8, orange = 9, red = 10, blue = 11,
}

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
  getNames = function() return {} end,
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

local config = { logistics = { reactors = {} } }
local page = router_ui.new({
  config = config,
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
assert(row3:find('REAKTOREN', 1, true), 'reactor-readiness status must be visible on the main screen')
assert(page._ui.learn_btn, 'EINLERNEN touch zone must exist')
assert(page._ui.mode == 'list', 'must start on the single main screen')

-- header() clears row 3 on every refresh. If the status dot still used the
-- cached core.ui primitives, an unchanged second frame would skip the
-- write and the status would disappear even though the touch zone survives.
page:render(mon, ui, nil, false)
row3 = row_text(3)
assert(row3:find('REAKTOREN', 1, true), 'reactor-readiness status must be restored after every header refresh')
assert(page._ui.learn_btn, 'EINLERNEN touch zone must survive an unchanged refresh')

local b = page._ui.learn_btn
assert(page:handle_touch(b.x1, b.y) == true, 'EINLERNEN touch must be consumed')
assert(page._ui.mode == 'learn', 'EINLERNEN must open the reactor-learn picker')

page:render(mon, ui, nil, false)
assert(#(page._ui.learn_btns or {}) == 1, 'the learn picker must expose the live-broadcasting reactor')

local learn_btn = page._ui.learn_btns[1]
assert(page:handle_touch(learn_btn.x1, learn_btn.y) == true, 'tapping a learnable reactor must be consumed')
assert(page._ui.mode == 'edit', 'tapping a learnable reactor must open the edit form')
assert(page._ui.editing.reactor_id == 'RT-1', 'the edit form must carry the learned reactor_id, not a synthetic label')

print('fuel_router_edit_entry_test.lua: ok')
