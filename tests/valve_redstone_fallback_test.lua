package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Feature (2026-09-03), explicit user request: a VALVE node should control
-- a Mekanism Logistical Sorter, if one is found, EXCLUSIVELY through the
-- Mekanism peripheral API (setAutoMode) -- and while doing so, actively hold
-- every redstone side low, since a sorter reacts to its own redstone input
-- and could otherwise silently override the ejection state this module just
-- set. Only when NO sorter can be resolved at all does a configured
-- redstone_side (any of top/bottom/left/right/front/back) become a plain
-- redstone.setOutput()/getOutput() fallback actuator.

local controller_lib = require('nodes.valve.controller')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local ALL_SIDES = { 'top', 'bottom', 'left', 'right', 'front', 'back' }

local function make_redstone_mock()
  local outputs = {}
  return {
    outputs = outputs,
    setOutput = function(side, high) outputs[side] = high end,
    getOutput = function(side) return outputs[side] == true end,
  }, outputs
end

-- 1. Sorter present: setAutoMode is used, and EVERY redstone side is
--    actively forced low as part of that same write -- not just the side
--    the sorter happens to sit on.
do
  local rs, outputs = make_redstone_mock()
  -- Pre-seed some sides high, as if something else had powered them before
  -- the sorter was ever discovered -- the controller must clear all of them.
  outputs.top = true
  outputs.back = true

  local auto_mode_calls = {}
  local controller = controller_lib.new({
    config = { sorter_name = nil, trusted_source = 'FUEL-1' },
    config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end, write_config = function() return true end },
    peripheral_api = {
      getNames = function() return { 'logisticalSorter_0' } end,
      getMethods = function() return { 'setAutoMode', 'getAutoMode' } end,
      wrap = function()
        return {
          setAutoMode = function(mode) auto_mode_calls[#auto_mode_calls + 1] = mode; return true end,
          getAutoMode = function() return auto_mode_calls[#auto_mode_calls] end,
        }
      end,
      find = function() return nil end,
    },
    colors_api = { orange = 1, red = 2, green = 3 },
    os_api = { epoch = function() return 1000000 end },
    redstone_api = rs,
  })

  assert_true(controller:apply_valve(true, true), 'sorter write must succeed')
  assert_eq(controller:get_state().actuator_mode, 'sorter', 'actuator_mode must report sorter')
  for _, side in ipairs(ALL_SIDES) do
    assert_eq(outputs[side], false, 'redstone side ' .. side .. ' must be forced low when a sorter is in control')
  end
end

-- 2. No sorter resolvable, but redstone_side configured: falls back to a
--    plain redstone write, verified via getOutput() readback.
do
  local rs, outputs = make_redstone_mock()
  local controller = controller_lib.new({
    config = { sorter_name = nil, redstone_side = 'back', trusted_source = 'FUEL-1' },
    config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end, write_config = function() return true end },
    peripheral_api = {
      getNames = function() return {} end,
      getMethods = function() return {} end,
      wrap = function() return nil end,
      find = function() return nil end,
    },
    colors_api = { orange = 1, red = 2, green = 3 },
    os_api = { epoch = function() return 1000000 end },
    redstone_api = rs,
  })

  assert_true(controller:apply_valve(true, true), 'redstone fallback write must succeed')
  assert_eq(outputs.back, true, 'configured redstone_side must receive the write')
  assert_eq(controller:get_state().actuator_mode, 'redstone', 'actuator_mode must report redstone')
  assert_eq(controller:get_state().redstone_side, 'back')

  assert_true(controller:apply_valve(false, true), 'redstone fallback OPEN write must succeed')
  assert_eq(outputs.back, false)
end

-- 3. No sorter AND no redstone_side configured: unsteuerbar, exactly as
--    before this feature existed (tests/valve_sorter_auto_detect_test.lua
--    already covers the same case; repeated here for actuator_mode).
do
  local rs = make_redstone_mock()
  local controller = controller_lib.new({
    config = { sorter_name = nil, trusted_source = 'FUEL-1' },
    config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end, write_config = function() return true end },
    peripheral_api = {
      getNames = function() return {} end,
      getMethods = function() return {} end,
      wrap = function() return nil end,
      find = function() return nil end,
    },
    colors_api = { orange = 1, red = 2, green = 3 },
    os_api = { epoch = function() return 1000000 end },
    redstone_api = rs,
  })

  assert_true(not controller:apply_valve(true, true), 'no sorter and no redstone_side must fail cleanly')
  assert_eq(controller:get_state().actuator_mode, 'none')
end

print('valve_redstone_fallback_test.lua: ok')
