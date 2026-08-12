package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local controller_lib = require('nodes.valve.controller')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_controller(monitor)
  return controller_lib.new({
    config = { sorter_name = 'logisticalSorter_1', trusted_source = 'FUEL-1' },
    config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end, write_config = function() return true end },
    peripheral_api = {
      wrap = function() return { setAutoMode = function() end } end,
      find = function(kind) if kind == 'monitor' then return monitor end end,
    },
    colors_api = { orange = 'orange', red = 'red', green = 'green' },
    os_api = { epoch = function() return 1000000 end },
  })
end

-- Monitor is optional.
do
  assert_true(make_controller(nil):apply_valve(false, true),
    'sorter operation must not depend on an attached monitor')
end

-- OPEN is green, BLOCKED is red, and an unchanged render is deduplicated.
do
  local seen = {}
  local monitor = {
    setBackgroundColor = function(color) seen[#seen + 1] = color end,
    clear = function() end,
  }
  local controller = make_controller(monitor)
  assert_true(controller:apply_valve(false, true))
  assert_eq(seen[#seen], 'green', 'OPEN must render green')
  assert_true(controller:apply_valve(true, true))
  assert_eq(seen[#seen], 'red', 'BLOCKED must render red')
  local count = #seen
  assert_true(controller:apply_valve(true, false))
  assert_eq(#seen, count, 'unchanged monitor colour must not be redrawn')
end

-- A broken monitor is detached from the controller but never fails a valid
-- physical sorter write.
do
  local monitor = {
    setBackgroundColor = function() error('monitor detached') end,
    clear = function() end,
  }
  local controller = make_controller(monitor)
  assert_true(controller:apply_valve(false, true),
    'monitor failure must not turn a successful sorter write into failure')
end

print('valve_status_monitor_test.lua: ok')
