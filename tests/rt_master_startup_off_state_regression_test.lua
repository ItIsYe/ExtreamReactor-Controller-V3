package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local state_handlers = require('nodes.rt.state_handlers')
local sequencer_lib = require('master.startup_sequencer')

local function assert_true(value, message)
  if not value then
    error(message or 'assert_true failed')
  end
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

-- RT startup queue should include only OFF modules and respect enable flags.
do
  local startup_queue = {}
  local state_value = constants.node_states.OFF
  local transitioned = {}
  local ctx = {
    constants = constants,
    STATE = { MASTER = 'MASTER', AUTONOM = 'AUTONOM' },
    devices = {
      turbines = { { id = 'turbine:A' }, { id = 'turbine:B' } },
      reactors = { { id = 'reactor:A' } }
    },
    modules = {
      ['turbine:A'] = { state = 'OFF' },
      ['turbine:B'] = { state = 'RUNNING' },
      ['reactor:A'] = { state = 'OFF' }
    },
    targets = { enable_turbines = true, enable_reactors = false },
    config = { startup_watchdog_s = 60 },
    set_startup_started_ms = function() end,
    set_startup_watchdog_tripped = function() end,
    get_startup_started_ms = function() return nil end,
    get_startup_watchdog_tripped = function() return false end,
    handle_startup_timeout = function() error('watchdog should not trigger in test') end,
    get_active_startup = function() return nil end,
    set_active_startup = function() end,
    get_startup_queue = function() return startup_queue end,
    set_startup_queue = function(v) startup_queue = v end,
    start_module = function() end,
    adjust_turbines = function() end,
    adjust_reactors = function() end,
    monitor_master = function() end,
    reset_startup_watchdog = function() end,
    scram = function() end,
    add_alarm = function() end,
    clamp_autonom_targets = function() end,
    get_target_rpm = function() return 900 end,
    get_current_state = function() return 'MASTER' end,
    get_node_state_machine = function()
      return {
        state = function() return state_value end,
        transition = function(_, next_state)
          state_value = next_state
          table.insert(transitioned, next_state)
        end
      }
    end,
    is_master_connected = function() return true end
  }

  local handlers = state_handlers.build(ctx)
  handlers[constants.node_states.STARTUP].on_enter()

  assert_eq(#startup_queue, 1, 'startup queue should include only one module')
  assert_eq(startup_queue[1], 'turbine:A', 'only OFF+enabled turbine should queue')
  assert_true(not startup_queue[2], 'reactor must be skipped when disabled')
end

-- MASTER sequencer must wait for module inventory and mode before sending STARTUP_STAGE.
do
  local sent = {}
  local comms = {
    send_command = function(_, node_id, payload)
      table.insert(sent, { node_id = node_id, payload = payload })
    end
  }
  local seq = sequencer_lib.new(comms, 'NORMAL', { timeout_s = 60 })
  seq:enqueue('RT-1')

  seq:tick({ ['RT-1'] = { id = 'RT-1', mode = 'MASTER' } })
  assert_eq(#sent, 0, 'sequencer must not send startup without modules snapshot')

  seq:tick({
    ['RT-1'] = {
      id = 'RT-1',
      mode = 'AUTONOM',
      modules = {
        ['turbine:BigReactors-Turbine_1'] = { state = 'OFF' }
      }
    }
  })
  assert_eq(#sent, 0, 'sequencer must not send startup while RT not in MASTER mode')

  -- The AUTONOM-mode tick above failed the is_startable() check and armed a
  -- real 5s wall-clock backoff (skip_until_ts) to avoid busy-looping a
  -- not-yet-ready node. This test isn't exercising that backoff -- it wants
  -- to prove readiness-gating (mode/modules), so clear it to simulate the
  -- backoff having already elapsed before probing again.
  if seq.queue[1] then seq.queue[1].skip_until_ts = nil end

  seq:tick({
    ['RT-1'] = {
      id = 'RT-1',
      mode = 'MASTER',
      modules = {
        ['turbine:BigReactors-Turbine_1'] = { state = 'OFF' }
      }
    }
  })

  assert_eq(#sent, 1, 'sequencer should send startup after modules+MASTER are ready')
  assert_eq(sent[1].payload.target, constants.command_targets.STARTUP_STAGE, 'startup target mismatch')
  assert_eq(sent[1].payload.value.module_id, 'turbine:BigReactors-Turbine_1', 'module id mismatch')
end

-- Guard against regression: MASTER mode transition must trigger STARTUP path.
-- This used to be a brittle text-search against xreactor/nodes/rt/main.lua
-- for a literal 'node_state_machine:transition(constants.node_states.STARTUP)'
-- string; that logic actually lives in the shared state_handlers.lua
-- apply_mode() (called by RT's command handler), so the text pattern never
-- matched main.lua and the check no longer proved anything real. Replaced
-- with a functional check against the real apply_mode() code path.
do
  local current_state = 'INIT'
  local machine_state = constants.node_states.OFF
  local transitions = {}
  local ctx = {
    constants = constants,
    STATE = { INIT = 'INIT', MASTER = 'MASTER', AUTONOM = 'AUTONOM', SAFE = 'SAFE' },
    log = function() end,
    get_current_state = function() return current_state end,
    set_current_state = function(v) current_state = v end,
    get_node_state_machine = function()
      return {
        state = function() return machine_state end,
        transition = function(_, next_state)
          machine_state = next_state
          table.insert(transitions, next_state)
        end
      }
    end
  }

  state_handlers.apply_mode(ctx, ctx.STATE.MASTER)

  assert_eq(current_state, 'MASTER', 'apply_mode(MASTER) should set current_state to MASTER')
  assert_eq(transitions[#transitions], constants.node_states.STARTUP,
    'MASTER mode should transition an OFF machine to STARTUP to leave module OFF state')
end

print('rt_master_startup_off_state_regression_test.lua: ok')
