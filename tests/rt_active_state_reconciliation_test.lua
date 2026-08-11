package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local reactor_control = require('nodes.rt.reactor_control')
local turbine_control = require('nodes.rt.turbine_control')

local function exercise(label, setter)
  local physical = false
  local writes = 0
  local device = {
    getActive = function() return physical end,
    setActive = function(value) physical = value; writes = writes + 1; return true end,
  }
  local caps = { getActive = true, setActive = true }
  local ctrl = {}

  assert(setter({}, device, caps, true, ctrl) == true, label .. ' initial activation failed')
  assert(physical == true and writes == 1 and ctrl.active_state == true,
    label .. ' initial activation did not update hardware/cache')

  -- Simulate a manual stop or peripheral/chunk reset between control ticks.
  physical = false
  assert(setter({}, device, caps, true, ctrl) == true,
    label .. ' did not recover from external stop')
  assert(physical == true, label .. ' trusted stale cache instead of restoring hardware')
  assert(writes == 2, label .. ' must issue a fresh write after observed drift')
end

exercise('reactor', reactor_control.setReactorActive)
exercise('turbine', turbine_control.setTurbineActive)

print('rt_active_state_reconciliation_test.lua: ok')
