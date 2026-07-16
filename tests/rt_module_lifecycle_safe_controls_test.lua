package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local lifecycle = require('nodes.rt.module_lifecycle')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function test_scram_safe_state_enforces_safe_controls_and_shutdown()
  local rods_calls = {}
  local turbine_flow_calls = {}
  local reactor_active_calls = {}
  local turbine_active_calls = {}
  local ctrl = { flow = 120, requested_flow = 130 }

  local ctx = {
    peripherals = {
      reactors = { reactor_0 = {} },
      turbines = { turbine_0 = { getRotorSpeed = function() return 500 end } }
    },
    binding = {
      build_policy = function() return {} end,
      missing_devices_message = function(kind) return 'missing:' .. kind end
    },
    configured_reactors = { 'reactor_0' },
    configured_turbines = { 'turbine_0' },
    get_device_caps = function(kind)
      if kind == 'reactors' then
        return { setAllControlRodLevels = true, setActive = true }
      end
      return { setInductorEngaged = true, setFluidFlowRate = true, setActive = true }
    end,
    ensure_reactor_ctrl = function() return { last_applied = 50 } end,
    applyReactorRods = function(level, allow_overmax, source)
      rods_calls[#rods_calls + 1] = { level = level, allow_overmax = allow_overmax, source = source }
    end,
    setReactorActive = function(_, _, active)
      reactor_active_calls[#reactor_active_calls + 1] = active
      return true
    end,
    setTurbineActive = function(_, _, active)
      turbine_active_calls[#turbine_active_calls + 1] = active
      return true
    end,
    setTurbineFlow = function(_, _, flow)
      turbine_flow_calls[#turbine_flow_calls + 1] = flow
      return true
    end,
    update_inductor_for_rpm = function() return true, true end,
    get_turbine_ctrl = function() return ctrl end,
    clamp_turbine_flow = function(flow) return flow end,
    TURBINE_MODE_RAMP = 'RAMP',
    START_FLOW = 100,
    warn_once = function() end,
    warn_unsupported = function() end,
    log = function() end,
    STATE = { SAFE = 'SAFE' },
    get_current_state = function() return 'SAFE' end
  }

  lifecycle.scram(ctx)

  assert_eq(#rods_calls, 1, 'scram should apply reactor rods once')
  assert_eq(rods_calls[1].level, 100, 'scram should force rods to 100')
  assert_eq(rods_calls[1].allow_overmax, true, 'scram should allow overmax rod write')
  assert_eq(rods_calls[1].source, 'SAFE_SCRAM', 'scram rod source tag should stay SAFE_SCRAM')
  assert_eq(#turbine_flow_calls, 1, 'scram should request turbine flow exactly once')
  assert_eq(#reactor_active_calls, 1, 'safe-state scram should deactivate reactors')
  assert_eq(reactor_active_calls[1], false, 'safe-state scram should deactivate reactor')
  assert_eq(#turbine_active_calls, 1, 'safe-state scram should deactivate turbines')
  assert_eq(turbine_active_calls[1], false, 'safe-state scram should deactivate turbine')
end

test_scram_safe_state_enforces_safe_controls_and_shutdown()
print('rt_module_lifecycle_safe_controls_test.lua: ok')
