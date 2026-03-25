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
    end
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

-- Guard against regression: MASTER mode transition must trigger STARTUP path in RT main.
do
  local file = io.open('xreactor/nodes/rt/main.lua', 'r')
  if not file then
    error('failed to open RT main source')
  end
  local content = file:read('*a')
  file:close()
  if not content:find('node_state_machine:transition%(constants%.node_states%.STARTUP%)') then
    error('MASTER mode should transition to STARTUP to leave module OFF state')
  end
end

print('rt_master_startup_off_state_regression_test.lua: ok')
