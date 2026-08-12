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

local function make_controller(sorter_name, devices)
  local names = {}
  for name in pairs(devices) do names[#names + 1] = name end
  table.sort(names)
  return controller_lib.new({
    config = { sorter_name = sorter_name, trusted_source = 'FUEL-1' },
    config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end, write_config = function() return true end },
    peripheral_api = {
      getNames = function() return names end,
      getMethods = function(name) return devices[name] and devices[name].methods or {} end,
      wrap = function(name) return devices[name] and devices[name].device or nil end,
      find = function() return nil end,
    },
    colors_api = { orange = 1, red = 2, green = 3 },
    os_api = { epoch = function() return 1000000 end },
  })
end

do
  local controller = make_controller(nil, {
    chest_1 = { methods = { 'list' }, device = { list = function() return {} end } },
    logisticalSorter_3 = {
      methods = { 'setAutoMode' }, device = { setAutoMode = function() end },
    },
  })
  assert_true(controller:apply_valve(false, true), 'capability discovery should find the sorter')
  assert_eq(controller:get_state().sorter_name, 'logisticalSorter_3', 'resolved peripheral name must be reported')
  assert_eq(controller:get_state().current_high, false)
end

do
  local controller = make_controller(nil, {
    chest_1 = { methods = { 'list' }, device = { list = function() return {} end } },
  })
  assert_true(not controller:apply_valve(false, true), 'missing sorter must fail cleanly')
  assert_true(controller:get_state().last_write_error ~= nil)
end

do
  local controller = make_controller('configured_missing', {
    logisticalSorter_3 = {
      methods = { 'setAutoMode' }, device = { setAutoMode = function() end },
    },
  })
  assert_true(not controller:apply_valve(false, true),
    'an explicit missing name must not silently fall back to another sorter')
end

print('valve_sorter_auto_detect_test.lua: ok')
