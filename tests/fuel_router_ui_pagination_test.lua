package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}
_G.redstone = { setOutput = function() end }

local redstone_router = require('nodes.fuel.redstone_router')
local router_ui = require('nodes.fuel.router_ui')
local responsive = require('nodes.fuel.router_ui_responsive')

local peers = {}
for i = 1, 20 do
  peers[string.format('VALVE-%02d', i)] = { down = false, role = 'VALVE-NODE' }
end
local comms = { get_peers = function() return peers end }

local reactors, routes = {}, {}
for i = 1, 20 do
  local id = string.format('R%02d', i)
  reactors[#reactors + 1] = { id = id, label = 'Reactor ' .. tostring(i) }
  routes[#routes + 1] = { reactor = id, label = 'Reactor ' .. tostring(i), path = { { side = 'back' } } }
end

local rs = redstone_router.new({
  config = { logistics = { redstone_tree = routes } },
  comms = comms, log = function() end, warn_once = function() end,
})
rs:refresh()

local page = responsive.attach(router_ui.new({
  redstone_router = rs,
  get_reactors = function() return reactors end,
  log = function() end,
}))

local width, height = 30, 12
local mon = { getSize = function() return width, height end }
local ui_stub = {
  badge = function() end,
  text = function() end,
  getSize = function(target) return target.getSize() end,
}

local function render(label)
  local ok, err = pcall(function() page:render(mon, ui_stub, nil, true) end)
  if not ok then error(label .. ': ' .. tostring(err)) end
end

local function tap(button)
  assert(button, 'expected paging button')
  assert(page:handle_touch(button.x1, button.y) == true, 'paging touch must be consumed')
end

local function any_button(list, field, expected)
  for _, button in ipairs(list or {}) do
    if button[field] == expected then return true end
  end
  return false
end

-- 20 reactors must remain reachable on a short monitor.
page._ui.mode = 'edit'
page._ui.edit_view = 'list'
render('reactor list initial')
assert(#page._ui.reactor_btns < #reactors, 'short monitor should paginate the reactor list')
assert(page._ui.list_scroll_down, 'reactor list must expose a down pager')
for _ = 1, 40 do
  if any_button(page._ui.reactor_btns, 'id', 'R20') then break end
  tap(page._ui.list_scroll_down)
  render('reactor list page')
end
assert(any_button(page._ui.reactor_btns, 'id', 'R20'), 'last configured reactor must be reachable')

-- A 12-step valve chain must not overflow the card and the last step must be reachable.
local long_path = {}
for i = 1, 12 do long_path[i] = { side = BUILTIN_SIDES and BUILTIN_SIDES[((i - 1) % 6) + 1] or 'back' } end
page._ui.edit_view = 'path'
page._ui.editing = { reactor = 'R01', label = 'Reactor 1', path = long_path }
page._ui.pending_side = nil
page._ui.path_scroll = 0
page._ui.picker_scroll = 0
render('long path initial')
assert(page._ui.path_scroll_down, 'long path must expose a down pager')
for _ = 1, 30 do
  if any_button(page._ui.step_btns, 'index', 12) then break end
  tap(page._ui.path_scroll_down)
  render('long path page')
end
assert(any_button(page._ui.step_btns, 'index', 12), 'last valve step must be reachable')

-- All six local sides must be reachable even when the picker is short.
page._ui.pending_side = nil
page._ui.picker_scroll = 0
render('side picker initial')
for _ = 1, 20 do
  if any_button(page._ui.side_btns, 'side', 'back') then break end
  tap(page._ui.picker_scroll_down)
  render('side picker page')
end
assert(any_button(page._ui.side_btns, 'side', 'back'), 'last built-in side must be reachable')

-- 20 VALVE nodes must also be pageable in the integrator picker.
page._ui.pending_side = 'front'
page._ui.picker_scroll = 0
render('integrator picker initial')
for _ = 1, 40 do
  if any_button(page._ui.integrator_btns, 'integrator', 'VALVE-20') then break end
  tap(page._ui.picker_scroll_down)
  render('integrator picker page')
end
assert(any_button(page._ui.integrator_btns, 'integrator', 'VALVE-20'), 'last VALVE node must be reachable')

-- Render all key states across the requested monitor-size matrix.
local sizes = { {30, 12}, {40, 16}, {51, 19}, {80, 20}, {100, 30} }
for _, size in ipairs(sizes) do
  width, height = size[1], size[2]
  page._ui.mode = 'edit'
  page._ui.edit_view = 'list'
  render(string.format('list %dx%d', width, height))
  page._ui.edit_view = 'path'
  page._ui.editing = { reactor = 'R01', label = 'Reactor 1', path = long_path }
  page._ui.pending_side = nil
  render(string.format('path %dx%d', width, height))
  page._ui.pending_side = 'front'
  render(string.format('picker %dx%d', width, height))
end

print('fuel_router_ui_pagination_test.lua: ok')
