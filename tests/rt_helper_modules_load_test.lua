package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local startup_diagnostics = require('nodes.rt.startup_diagnostics')
local status_snapshot = require('nodes.rt.status_snapshot')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local summary = startup_diagnostics.build_peripheral_summary({
  total = 4,
  bound = 3,
  missing = 1,
  kinds = {
    reactor = { bound = 1, total = 2 },
    turbine = { bound = 2, total = 2 }
  }
})
assert_eq(summary, 'registry total=4 bound=3 missing=1 reactors=1/2 turbines=2/2', 'summary mismatch')

local emergency = startup_diagnostics.should_emergency_startup({
  max_temp = 1200,
  avg_rpm = 1800,
  turbines = {
    A = { rpm = 1850 }
  }
}, 2000, 1700)
assert_eq(emergency, true, 'rpm guard should trigger emergency')

local payload = status_snapshot.build_status_payload({
  status_level = 'OK',
  node_state_machine = { state = function() return 'RUNNING' end },
  current_state = 'MASTER',
  targets = { power = 0, rpm = 900, steam = 0 },
  build_health_payload = function()
    return { capabilities = { reactors = {}, turbines = {} }, bindings = { reactors = 1, turbines = 2 } }
  end,
  status_snapshot = { avg_rpm = 900 },
  devices = { registry_summary = { total = 3, bound = 3, missing = 0 } },
  registry = {
    get_summary = function() return { total = 3, bound = 3, missing = 0 } end,
    get_devices_by_kind = function() return { turbine = {}, reactor = {} } end,
    get_diagnostics = function() return { ok = true } end,
    get_bound_devices = function(_, kind)
      if kind == 'turbine' then
        return { { id = 'turbine:A', name = 'A', alias = 'A' } }
      end
      return { { id = 'reactor:A', name = 'R', alias = 'R' } }
    end
  },
  modules = {
    ['turbine:A'] = { state = 'RUNNING', progress = 1, limits = {} },
    ['reactor:A'] = { state = 'RUNNING', progress = 1, limits = {} }
  },
  active_startup = nil,
  startup_queue = {},
  turbine_adapter = { inspect = function() return { rpm = 900, flow = 300, coil_engaged = true } end },
  reactor_adapter = { inspect = function() return { control_rod_level = 70, active = true, steam = 1000 } end },
  log_prefix = 'RT'
})

assert_eq(payload.state, 'RUNNING', 'state mismatch')
assert_eq(payload.mode, 'MASTER', 'mode mismatch')
assert_eq(payload.turbines[1].id, 'turbine:A', 'turbine snapshot missing')
assert_eq(payload.reactors[1].id, 'reactor:A', 'reactor snapshot missing')

print('rt_helper_modules_load_test.lua: ok')
