package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local startup_diagnostics = require('nodes.rt.startup_diagnostics')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function make_ctx(snapshot)
  local transitions = {}
  local published = {}
  local ctx = {
    startup_watchdog_tripped = false,
    startup_started_ms = os.epoch('utc') - 5000,
    comms = { network = { id = 'RT-1' } },
    config = { role = 'RT', node_id = 'RT-1', safety = { max_temperature = 1200, max_rpm = 1800 } },
    devices = { registry_summary = { total = 2, bound = 2, missing = 0, kinds = { reactor = { bound = 1, total = 1 }, turbine = { bound = 1, total = 1 } } } },
    registry = { get_summary = function() return {} end },
    constants = {
      status_levels = { EMERGENCY = 'EMERGENCY', WARNING = 'WARNING' },
      node_states = { EMERGENCY = 'EMERGENCY', LIMITED = 'LIMITED' }
    },
    node_state_machine = {
      state = function() return 'RUNNING' end,
      transition = function(_, state) transitions[#transitions + 1] = state end
    },
    log = function() end,
    update_status_snapshot = function() return snapshot end,
    broadcast_status = function(level) published[#published + 1] = level end,
    active_startup = 'module-1',
    startup_queue = { 'module-1', 'module-2' }
  }
  return ctx, transitions, published
end

local emergency_ctx, emergency_transitions, emergency_published = make_ctx({ max_temp = 1300, avg_rpm = 900, turbines = {} })
startup_diagnostics.handle_startup_timeout(emergency_ctx)
assert_eq(emergency_ctx.startup_watchdog_tripped, true, 'watchdog should trip')
assert_eq(emergency_ctx.active_startup, nil, 'active startup should be cleared')
assert_eq(#emergency_ctx.startup_queue, 0, 'startup queue should be cleared')
assert_eq(emergency_published[1], 'EMERGENCY', 'emergency status should be published')
assert_eq(emergency_transitions[1], 'EMERGENCY', 'emergency transition expected')

local limited_ctx, limited_transitions, limited_published = make_ctx({ max_temp = 400, avg_rpm = 900, turbines = {} })
startup_diagnostics.handle_startup_timeout(limited_ctx)
assert_eq(limited_published[1], 'WARNING', 'warning status should be published when no emergency trigger')
assert_eq(limited_transitions[1], 'LIMITED', 'limited transition expected')

local no_op_ctx, no_op_transitions, no_op_published = make_ctx({ max_temp = 1300, avg_rpm = 900, turbines = {} })
no_op_ctx.startup_watchdog_tripped = true
startup_diagnostics.handle_startup_timeout(no_op_ctx)
assert_eq(#no_op_transitions, 0, 'already tripped watchdog should be no-op for transitions')
assert_eq(#no_op_published, 0, 'already tripped watchdog should be no-op for status publish')

print('rt_startup_diagnostics_timeout_test.lua: ok')
