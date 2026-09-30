package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: "FUEL braucht ziemlich lang, bis er Daten von den RT bekommt".
--
-- Fuer eine FUEL-Node, die die RT-Nodes direkt mithoeren kann
-- (fuel_status_network.make_overhear_service), ist der erste Fuellstand
-- nach spaetestens einem RT-Statusintervall da. Kann sie das nicht (keine
-- Funkreichweite zur RT, aber zum MASTER), ist master/fuel_relay.lua der
-- EINZIGE Weg -- und der lief fest alle 10s, ohne jeden Anlass-Trigger.
-- Eine gerade gebootete FUEL-Node hat aber gar keine Daten, nicht nur
-- leicht veraltete: sie musste bis zu 10s zusaetzlich warten.

local constants = require('shared.constants')
local fuel_relay = require('master.fuel_relay')
local fuel_status_network = require('nodes.fuel.fuel_status_network')
local protocol = require('core.protocol')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local now = 1000000
local real_epoch = os.epoch
os.epoch = function(kind) if kind == nil or kind == 'utc' then return now end return real_epoch(kind) end

local function make_runtime()
  local sent = {}
  return {
    libs = { constants = constants },
    state = {
      nodes = {
        ['RT-1'] = {
          id = 'RT-1', role = constants.roles.RT_NODE, last_seen = now,
          rt = { reactors = { { id = 'reactor_0', global_id = 'RT-1:reactor_0',
            fuel_amount = 1000, fuel_capacity = 4000 } } },
        },
      },
    },
    refs = { comms = { send_command = function(_self, target, command)
      sent[#sent + 1] = { target = target, command = command }
    end } },
    sent = sent,
  }
end

-- 1. Ohne FUEL-Node passiert nichts.
do
  local runtime = make_runtime()
  fuel_relay.tick(runtime)
  assert_eq(#runtime.sent, 0, 'no FUEL node -> nothing to relay')
end

-- 2. Eine neu aufgetauchte FUEL-Node bekommt SOFORT einen Snapshot, auch
--    wenn gerade eben erst relayed wurde -- sonst startet sie blind.
do
  local runtime = make_runtime()
  runtime.state.nodes['FUEL-1'] = { id = 'FUEL-1', role = constants.roles.FUEL_NODE, last_seen = now }
  fuel_relay.tick(runtime)
  assert_eq(#runtime.sent, 1, 'first FUEL node must be served immediately')
  assert_eq(runtime.sent[1].target, 'FUEL-1')
  assert_eq(runtime.sent[1].command.target, constants.command_targets.FUEL_STATUS)
  assert_true(runtime.sent[1].command.value['RT-1:reactor_0'] ~= nil, 'snapshot must carry the RT reactor')

  -- Direkt danach, ohne Aenderung: die Drossel greift.
  now = now + 500
  fuel_relay.tick(runtime)
  assert_eq(#runtime.sent, 1, 'unchanged node set must stay throttled')

  -- Eine ZWEITE FUEL-Node taucht auf -> sofortiges Relais an alle.
  runtime.state.nodes['FUEL-2'] = { id = 'FUEL-2', role = constants.roles.FUEL_NODE, last_seen = now }
  fuel_relay.tick(runtime)
  assert_eq(#runtime.sent, 3, 'a newly appeared FUEL node must trigger an immediate relay')

  -- Und danach wieder gedrosselt.
  now = now + 500
  fuel_relay.tick(runtime)
  assert_eq(#runtime.sent, 3, 'after the kick the interval applies again')
end

-- 3. Die periodische Drossel darf nicht laenger sein als das
--    RT-Statusintervall -- sonst ist das Relais und nicht die RT-Node der
--    bestimmende Term fuer eine FUEL-Node ohne Direktempfang.
do
  local rt_config = require('nodes.rt.config')
  local runtime = make_runtime()
  runtime.state.nodes['FUEL-1'] = { id = 'FUEL-1', role = constants.roles.FUEL_NODE, last_seen = now }
  fuel_relay.tick(runtime)
  local baseline = #runtime.sent

  local rt_status_interval_ms = (rt_config.status_interval or rt_config.heartbeat_interval) * 1000
  now = now + rt_status_interval_ms
  fuel_relay.tick(runtime)
  assert_true(#runtime.sent > baseline, string.format(
    'relay interval must not exceed the RT status interval (%dms)', rt_status_interval_ms))
end

-- 4. Der Mithoer-Dienst haengt am KONFIGURIERTEN Status-Kanal, nicht an
--    einer fest verdrahteten Konstante.
do
  local cache = fuel_status_network.new()
  local custom_channel = 7501
  local svc = fuel_status_network.make_overhear_service(cache, constants, custom_channel)
  local message = protocol.sanitize_message({
    type = constants.message_types.STATUS,
    sender_id = 'RT-1', src = 'RT-1', node_id = 'RT-1',
    role = constants.roles.RT_NODE,
    ts = now, timestamp = now,
    proto_ver = { major = 1, minor = 0 },
    payload = { reactors = { { id = 'reactor_0', global_id = 'RT-1:reactor_0',
      fuel_amount = 1000, fuel_capacity = 4000 } } },
  })

  svc.tick(svc, nil, { 'modem_message', 'back', constants.channels.STATUS, constants.channels.STATUS, message, 0 })
  assert_eq(cache.direct_heard['RT-1:reactor_0'], nil, 'the default channel must be ignored when another one is configured')

  svc.tick(svc, nil, { 'modem_message', 'back', custom_channel, custom_channel, message, 0 })
  assert_true(cache.direct_heard['RT-1:reactor_0'] ~= nil, 'the configured status channel must be heard')
  assert_eq(cache.direct_heard['RT-1:reactor_0'].fuel_amount, 1000)
end

-- 5. Ohne expliziten Kanal bleibt der bisherige Default gueltig.
do
  local cache = fuel_status_network.new()
  local svc = fuel_status_network.make_overhear_service(cache, constants)
  local message = protocol.sanitize_message({
    type = constants.message_types.STATUS,
    sender_id = 'RT-1', src = 'RT-1', node_id = 'RT-1',
    role = constants.roles.RT_NODE,
    ts = now, timestamp = now,
    proto_ver = { major = 1, minor = 0 },
    payload = { reactors = { { id = 'reactor_0', global_id = 'RT-1:reactor_0',
      fuel_amount = 2000, fuel_capacity = 4000 } } },
  })
  svc.tick(svc, nil, { 'modem_message', 'back', constants.channels.STATUS, constants.channels.STATUS, message, 0 })
  assert_true(cache.direct_heard['RT-1:reactor_0'] ~= nil, 'default channel must keep working')
end

os.epoch = real_epoch
print('fuel_relay_cold_start_test.lua: ok')
