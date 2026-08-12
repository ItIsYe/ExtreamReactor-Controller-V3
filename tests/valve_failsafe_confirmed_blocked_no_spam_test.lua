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

local function make_controller(clock)
  local log_lines = {}
  local writes = 0
  local controller = controller_lib.new({
    config = { sorter_name = 'logisticalSorter_1', trusted_source = 'FUEL-1' },
    config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function(_, message, level) log_lines[#log_lines + 1] = { message = message, level = level } end,
              write_config = function() return true end },
    peripheral_api = {
      wrap = function() return { setAutoMode = function() writes = writes + 1 end } end,
      find = function() return nil end,
    },
    colors_api = { orange = 'orange', red = 'red', green = 'green' },
    os_api = { epoch = function() return clock.now end },
  })
  return controller, log_lines, function() return writes end
end

-- A confirmed BLOCKED valve with no pending error must never fire the
-- fail-safe again, no matter how long it has been idle: staleness alone
-- must not force a physical write on an already-safe valve.
do
  local clock = { now = 0 }
  local controller, log_lines, get_writes = make_controller(clock)
  assert_true(controller:apply_valve(true, true), 'initial BLOCKED write must succeed')
  local writes_after_init = get_writes()
  local logs_after_init = #log_lines

  -- Advance far past both the 20s staleness threshold and the 2s retry
  -- cooldown, then tick repeatedly as a real service loop would.
  for _ = 1, 5 do
    clock.now = clock.now + 30000
    local fired = controller:tick_failsafe(20, 2000)
    assert_true(fired == false, 'tick_failsafe must not fire on a confirmed BLOCKED valve')
  end

  assert_eq(get_writes(), writes_after_init, 'no additional sorter writes on a healthy idle valve')
  assert_eq(#log_lines, logs_after_init, 'no additional log lines on a healthy idle valve')
end

-- An OPEN valve with no fresh SET_VALVE command must still be forced back
-- to BLOCKED once it goes stale.
do
  local clock = { now = 0 }
  local controller, log_lines, get_writes = make_controller(clock)
  assert_true(controller:apply_valve(false, true), 'initial OPEN write must succeed')
  local writes_after_open = get_writes()

  clock.now = clock.now + 25000
  local fired = controller:tick_failsafe(20, 2000)
  assert_true(fired == true, 'tick_failsafe must force BLOCKED on a stale OPEN valve')
  assert_eq(get_writes(), writes_after_open + 1, 'exactly one corrective write expected')
end

print('valve_failsafe_confirmed_blocked_no_spam_test.lua: ok')
