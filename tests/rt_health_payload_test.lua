package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local health_payload = require('nodes.rt.health_payload')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local health = {
  reasons = {
    NO_REACTOR = 'NO_REACTOR',
    NO_TURBINE = 'NO_TURBINE',
    DISCOVERY_FAILED = 'DISCOVERY_FAILED',
    PROTO_MISMATCH = 'PROTO_MISMATCH',
    CONTROL_DEGRADED = 'CONTROL_DEGRADED',
    COMMS_DOWN = 'COMMS_DOWN'
  },
  status = {
    DEGRADED = 'DEGRADED',
    OK = 'OK'
  },
  reasons_list = function(rt_health)
    local out = {}
    for reason in pairs(rt_health.reasons or {}) do
      out[#out + 1] = reason
    end
    table.sort(out)
    return out
  end
}

local warned = {}
local ctx = {
  comms = {
    get_peers = function()
      return {
        { role = 'MASTER', down = false, age = 1.5 }
      }
    end
  },
  constants = { roles = { MASTER = 'MASTER' } },
  master_seen = os.epoch('utc'),
  hb = 2,
  devices = {
    registry_summary = {
      kinds = {
        reactor = { bound = 1 },
        turbine = { bound = 1 }
      }
    },
    discovery_failed = false,
    registry_load_error = nil,
    proto_mismatch = false
  },
  registry = { get_summary = function() return { kinds = {} } end },
  binding = {
    build_policy = function() return {} end,
    missing_devices_message = function(kind) return 'missing:' .. kind end
  },
  configured_reactors = { 'R1' },
  configured_turbines = { 'T1' },
  health = health,
  warn_once = function(key, message) warned[key] = message end,
  startup_watchdog_tripped = false,
  rt_health = {},
  configured_caps = { reactors = 1, turbines = 1 }
}

local connected, age = health_payload.is_master_connected(ctx)
assert_eq(connected, true, 'master should be connected from peer table')
assert_eq(age, 1.5, 'peer age should be forwarded')

local payload = health_payload.build_health_payload(ctx)
assert_eq(payload.status, 'OK', 'healthy payload should be OK')
assert_eq(#payload.reasons, 0, 'healthy payload should have no reasons')

ctx.comms = { get_peers = function() return {} end }
ctx.master_seen = os.epoch('utc') - 15000
ctx.devices.registry_summary.kinds.reactor.bound = 0
ctx.devices.registry_summary.kinds.turbine.bound = 0

payload = health_payload.build_health_payload(ctx)
assert_eq(payload.status, 'DEGRADED', 'degraded payload expected when bindings/comms are missing')
assert_eq(warned['reactors_missing_health'], 'missing:reactor', 'reactor warning expected')
assert_eq(warned['turbines_missing_health'], 'missing:turbine', 'turbine warning expected')

print('rt_health_payload_test.lua: ok')
