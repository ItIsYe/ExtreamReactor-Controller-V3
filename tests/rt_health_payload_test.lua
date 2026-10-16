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
-- 25 s: ueber comms.peer_timeout_s (20 s, der Default aus
-- nodes/rt/config.lua). Hier stand vorher 15000 -- das war ueber der alten
-- Schwelle heartbeat_interval * 5 (10 s), die der Health-Check als EINZIGER
-- benutzte, waehrend Peer-Tabelle und Zustandsmaschine mit 20 s arbeiteten.
-- Genau diese Abweichung liess den Knoten "MASTER DOWN" anzeigen, waehrend
-- er im Zustand MASTER regelte; der Health-Check folgt jetzt derselben
-- Schwelle, also muss der Messwert auch wirklich darueber liegen.
ctx.master_seen = os.epoch('utc') - 25000
ctx.devices.registry_summary.kinds.reactor.bound = 0
ctx.devices.registry_summary.kinds.turbine.bound = 0

payload = health_payload.build_health_payload(ctx)
assert_eq(payload.status, 'DEGRADED', 'degraded payload expected when bindings/comms are missing')
assert_eq(warned['reactors_missing_health'], 'missing:reactor', 'reactor warning expected')
assert_eq(warned['turbines_missing_health'], 'missing:turbine', 'turbine warning expected')

-- Verlorene Timer-Ereignisse (nodes/support/runtime.lua): der Grund
-- TIMER_LOST steht im Payload, sobald seit dem Start einer verloren ging --
-- die Node wird dadurch aber NICHT herabgestuft, sie regelt ja weiter.
ctx.comms = { get_peers = function() return { { role = 'MASTER', down = false, age = 1.5 } } end }
ctx.master_seen = os.epoch('utc')
ctx.devices.registry_summary.kinds.reactor.bound = 1
ctx.devices.registry_summary.kinds.turbine.bound = 1
ctx.timers_lost = 0
payload = health_payload.build_health_payload(ctx)
assert_eq(#payload.reasons, 0, 'ohne verlorenen Timer kein Grund')
ctx.timers_lost = 2
payload = health_payload.build_health_payload(ctx)
assert_eq(payload.status, 'OK', 'ein ausgeglichener Timer-Verlust stuft die Node nicht herab')
assert_eq(#payload.reasons, 1, 'genau ein Grund')
assert_eq(payload.reasons[1], 'TIMER_LOST', 'der Grund heisst TIMER_LOST')

print('rt_health_payload_test.lua: ok')
