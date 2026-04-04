package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local lifecycle = require('nodes.rt.module_lifecycle')

local function make_ctx(module)
  local active = module.id
  local apply_calls = 0
  local last_apply_source = nil
  local state = nil
  local transitions = 0
  return {
    modules = { [module.id] = module },
    config = { safety = { max_temperature = 2000 } },
    TURBINE_MODE = { RAMP = 'RAMP' },
    RPM_TOL = 20,
    comms = { network = { id = 'RT-1' } },
    set_active_startup = function(value) active = value end,
    get_active_startup = function() return active end,
    ramp_duration = function() return 1 end,
    setReactorActive = function() return true end,
    setTurbineActive = function() return true end,
    setTurbineFlow = function() return true end,
    update_inductor_for_rpm = function() return true, true end,
    update_turbine_flow_state = function(_, _, ctrl) return ctrl.flow or 200, 'HOLD' end,
    get_target_rpm = function() return 900 end,
    get_turbine_ctrl = function() return { flow = 200, rails = {} } end,
    ensure_reactor_ctrl = function() return { last_applied = nil } end,
    applyReactorRods = function(_, _, source)
      apply_calls = apply_calls + 1
      last_apply_source = source
    end,
    reactor_low_water = function() return false end,
    add_alarm = function() end,
    log = function() end,
    warn_once = function() end,
    warn_unsupported = function() end,
    current_state = function() return 'MASTER' end,
    STATE = { SAFE = 'SAFE' },
    setState = function(value) state = value end,
    node_state_machine = {
      state = function() return 'RUNNING' end,
      transition = function() transitions = transitions + 1 end,
    },
    constants = { node_states = { EMERGENCY = 'EMERGENCY', RUNNING = 'RUNNING' } },
    _assert = function()
      if state ~= nil then
        error('unexpected SAFE transition while validating rod capabilities')
      end
      if transitions ~= 0 then
        error('unexpected emergency transition while validating rod capabilities')
      end
      if apply_calls < 1 then
        error('expected reactor rod application during startup for setControlRodLevel-only reactor')
      end
      if last_apply_source ~= 'STARTUP_RAMP' then
        error('expected startup reactor writes to carry STARTUP_RAMP source tag')
      end
    end,
  }
end

local function test_setControlRodLevel_caps_allow_reactor_startup_path()
  local module = {
    id = 'R1',
    type = 'reactor',
    name = 'reactor_0',
    state = 'STARTING',
    progress = 0,
    start_time = os.epoch('utc') - 1000,
    caps = { setControlRodLevel = true },
    peripheral = {
      getCasingTemperature = function() return 900 end,
    },
  }

  local ctx = make_ctx(module)
  lifecycle.process_startup(ctx)
  if module.state == 'ERROR' then
    error('setControlRodLevel capability should be accepted as valid control path')
  end
  ctx._assert()
end

test_setControlRodLevel_caps_allow_reactor_startup_path()
print('rt_module_lifecycle_control_rod_caps_test.lua: ok')
