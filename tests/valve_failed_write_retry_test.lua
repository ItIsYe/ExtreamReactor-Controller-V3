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

local clock = 1000000
local physical_ok = true
local writes = 0
local acks = {}
local peripheral_api = {
  getNames = function() return { 'logisticalSorter_1' } end,
  getMethods = function() return { 'setAutoMode' } end,
  find = function() return nil end,
  wrap = function(name)
    if name == 'left' then
      return { transmit = function(_, _, message) acks[#acks + 1] = message end }
    end
    return {
      setAutoMode = function()
        writes = writes + 1
        if not physical_ok then error('simulated sorter write failure') end
      end,
    }
  end,
}
local config = { sorter_name = 'logisticalSorter_1', trusted_source = 'FUEL-1' }
local controller = controller_lib.new({
  config = config, config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
  constants = { channels = { VALVE = 6504 } },
  utils = { log = function() end, write_config = function() return true end },
  peripheral_api = peripheral_api,
  colors_api = { orange = 1, red = 2, green = 3 },
  os_api = { epoch = function() return clock end },
})

-- Establish a known physical OPEN state, exactly as main.lua does at boot.
assert_true(controller:apply_valve(false, true))
local baseline = controller:get_state().last_command_ts

-- A failed command must not alter the confirmed state or refresh the safety
-- timestamp. Retrying the same command ID must perform another real write.
physical_ok = false
clock = clock + 1000
local event = { 'modem_message', 'left', 6504, 6504,
  { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-1', high = true } }
assert_true(not controller:handle_event(event), 'failed actuator write must reject the command')
assert_eq(controller:get_state().current_high, false, 'failed write must preserve the last confirmed physical state')
assert_eq(controller:get_state().last_command_ts, baseline, 'failed write must not extend the unsafe grace period')
assert_true(controller:get_state().last_write_error ~= nil, 'failure must remain visible')

physical_ok = true
clock = clock + 1000
assert_true(controller:handle_event(event), 'same command ID must be retryable after a failed write')
assert_eq(controller:get_state().current_high, true, 'successful retry must confirm BLOCKED')
assert_eq(controller:get_state().last_command_ts, clock, 'successful physical proof must update the command timestamp')

-- Even a duplicate of an already successful command is physically re-applied:
-- cached RAM state is not sufficient evidence for an actuator ACK.
local writes_before = writes
clock = clock + 1000
assert_true(controller:handle_event(event), 'an exact duplicate must be idempotently accepted')
assert_eq(writes, writes_before + 1, 'duplicate command must force one fresh sorter write')
assert_eq(controller:get_state().last_command_ts, clock, 'fresh duplicate proof must refresh the safety timestamp')

-- Reusing a command ID with a different payload is rejected and never moves
-- the actuator.
writes_before = writes
local conflicting = { 'modem_message', 'left', 6504, 6504,
  { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-1', high = false } }
assert_true(not controller:handle_event(conflicting), 'command ID reuse with changed payload must fail closed')
assert_eq(writes, writes_before, 'conflicting replay must not touch the sorter')
assert_eq(controller:get_state().current_high, true, 'conflicting replay must preserve BLOCKED')
assert_true(#acks >= 4, 'each accepted/rejected modem command should receive an ACK attempt')

print('valve_failed_write_retry_test.lua: ok')
