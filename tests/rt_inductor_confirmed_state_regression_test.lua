package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local turbine_control = require('nodes.rt.turbine_control')
local calls = 0
local fail_first = true
local turbine = {
  setInductorEngaged = function(value)
    calls = calls + 1
    if fail_first then fail_first = false; error('simulated actuator failure') end
    assert(value == true)
  end,
}
local ctx = {
  turbine_ctrl_store = {},
  config = { rails = { coil = { cooldown_s = 0, ema_alpha = 1, engage_rpm = 850, disengage_rpm = 750, overspeed_band = 20 } } },
  CONFIG = { TARGET_RPM = 900, COIL_ENGAGE_RPM = 850, COIL_DISENGAGE_RPM = 750 },
  rails = {
    new_state = function() return { last_change_ts = 0 } end,
    smooth = function(_, _, value) return value end,
  },
  safe_wrapped_call = function(obj, method, ...) return pcall(obj[method], ...) end,
  warn_once = function() end,
}
local caps = { setInductorEngaged = true, getInductorEngaged = false }

local ok1, applied1 = turbine_control.update_inductor_for_rpm(ctx, 'T1', turbine, caps, 950, 900)
assert(ok1 == false or applied1 == false, 'failed actuator write must be reported')
assert(turbine_control.get_turbine_ctrl(ctx, 'T1').inductor_engaged == false,
  'failed write must not be cached as confirmed engaged')

local ok2, applied2 = turbine_control.update_inductor_for_rpm(ctx, 'T1', turbine, caps, 950, 900)
assert(ok2 == true and applied2 == true, 'second control tick must retry actuator write')
assert(calls == 2, 'actuator must be retried after failure')
assert(turbine_control.get_turbine_ctrl(ctx, 'T1').inductor_engaged == true,
  'state becomes confirmed only after successful write')

local src = assert(io.open('xreactor/nodes/rt/turbine_control.lua', 'r')):read('*a')
assert(not src:find('if not %(caps and caps%.setInductorEngaged%) then%s+ctrl%.inductor_engaged = true'),
  'overspeed fallback must not fake a confirmed brake state')

print('rt_inductor_confirmed_state_regression_test.lua: ok')
