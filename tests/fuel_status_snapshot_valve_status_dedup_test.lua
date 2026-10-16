package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (user report 2026-09-14: "leichte Performance-Probleme"
-- on FUEL with ~20 active VALVE nodes). rs_router:get_valve_status()
-- rebuilds a fresh table across every comms peer and sorts every valve --
-- expensive with many valves. build_status_payload() used to call it
-- directly for payload.valve_summary AND indirectly a second time via
-- operational_summary.enrich()'s internal route_context(), both within the
-- same status cycle producing identical results. Now fetched once and
-- threaded through via opts.valve_status.

local status_snapshot = require('nodes.fuel.status_snapshot')
local health = require('core.health')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ' expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local get_valve_status_calls = 0
local valve_list = {
  { id = 'VALVE-1', online = true, stale = false },
  { id = 'VALVE-2', online = false, stale = false },
  { id = 'VALVE-3', online = true, stale = true },
}
local rs_router = {
  get_valve_status = function()
    get_valve_status_calls = get_valve_status_calls + 1
    return valve_list
  end,
  get_routing_state = function() return 'ROUTING_VALID' end,
  get_tree = function() return {} end,
}

local logistics_router = {
  get_summary = function() return { reactors = {} } end,
  fuel_status = {},
}

local registry = {
  get_summary = function() return {} end,
  get_devices_by_kind = function() return {} end,
  get_diagnostics = function() return {} end,
}

local ctx = {
  health = health,
  non_rt_payload = require('core.non_rt_payload'),
  devices = {},
  config = { role = 'FUEL', node_id = 'FUEL-1' },
  fuel_health = health.new({}),
  node_id = 'FUEL-1',
  read_fuel = function() return 1000 end,
  enforce_reserve = function(amount) return amount end,
  is_master_connected = function() return true end,
  storage = 'meBridge_0',
  reserve = 2000,
  comms = nil,
  master_alerts = nil,
  master_seen_ts = nil,
  registry = registry,
  get_router = function() return logistics_router end,
  get_rs_router = function() return rs_router end,
  routing_load_status = nil,
}

local payload = status_snapshot.build_status_payload(ctx)

assert_eq(get_valve_status_calls, 1,
  'get_valve_status() must be called exactly once per status cycle, not once directly plus once more inside operational_summary.enrich()')
assert_eq(payload.valve_summary.total, 3, 'valve_summary.total must reflect the fetched valve list')
assert_eq(payload.valve_summary.offline, 1, 'valve_summary.offline must count VALVE-2')
assert_eq(payload.valve_summary.stale, 1, 'valve_summary.stale must count VALVE-3')

print('fuel_status_snapshot_valve_status_dedup_test.lua: ok')
