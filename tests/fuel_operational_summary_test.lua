package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local operational = require('nodes.fuel.operational_summary')

local summary = {
  enabled = true,
  bridge = 'meBridge_0',
  reactors = {
    { label = 'R1', reactor_id = 'rid-1', inlet = 'inlet_1', connected = true, fuel_pct = 60 },
    { label = 'R2', reactor_id = 'rid-2', inlet = 'inlet_2', connected = true, fuel_pct = nil },
    { label = 'R3', reactor_id = 'rid-3', inlet = 'inlet_3', connected = true, fuel_pct = nil },
  },
}

local config = {
  logistics = {
    reactors = {
      { name = 'R1', reactor_id = 'rid-1', inlet = 'inlet_1', item = 'fuel:a', request_below = 0.25, fill_amount = 64, min_in_me = 32 },
      { name = 'R2', reactor_id = 'rid-2', inlet = 'inlet_2', item = 'fuel:b', request_below = 0.30, fill_amount = 32, min_in_me = 16 },
      { name = 'R3', reactor_id = 'rid-3', inlet = 'inlet_3', item = 'fuel:c', request_below = 0.35, fill_amount = 16, min_in_me = 8 },
    },
  },
}

local cache = {
  master_relay = {
    ['rid-1'] = { fuel_amount = 600, fuel_capacity = 1000, ts = 99000 },
    ['rid-2'] = { fuel_amount = 200, fuel_capacity = 1000, ts = 50000 },
  },
  direct_heard = {
    ['rid-1'] = { fuel_amount = 590, fuel_capacity = 1000, ts = 98000 },
  },
}

local rs = {
  get_routing_state = function() return 'ROUTING_VALID' end,
  get_tree = function()
    return {
      { reactor = 'R1', label = 'R1', path = { { side = 'left', integrator = 'VALVE-1' } } },
      { reactor = 'R2', label = 'R2', path = { { side = 'right', integrator = 'VALVE-2' } } },
    }
  end,
  get_valve_status = function()
    return {
      { id = 'VALVE-1', online = true, stale = false },
      { id = 'VALVE-2', online = false, stale = false },
    }
  end,
}

operational.enrich(summary, { config = config, fuel_status = cache, rs_router = rs, now_ms = 100000 })

local r1, r2, r3 = summary.reactors[1], summary.reactors[2], summary.reactors[3]
assert(r1.fuel_data_state == 'FRESH', 'fuel_pct from logistics summary is the canonical fresh signal')
assert(r1.fuel_age_s == 1 and r1.fuel_source == 'MASTER', 'newest source and data age must be exposed')
assert(r1.route_state == 'ROUTE_READY' and r1.operational_state == 'READY')
assert(r1.item == 'fuel:a' and r1.configured_inlet == 'inlet_1')
assert(r1.request_below == 0.25 and r1.fill_amount == 64 and r1.min_in_me == 32)

assert(r2.fuel_data_state == 'STALE', 'numeric cached sample rejected by logistics freshness must be STALE')
assert(r2.fuel_age_s == 50)
assert(r2.route_state == 'VALVE_OFFLINE', 'offline valve on the reactor path must block that route')
assert(r2.operational_state == 'BLOCKED', 'route failure outranks stale fuel state')

assert(r3.fuel_data_state == 'MISSING', 'reactor with no usable cache entry must be MISSING')
assert(r3.route_state == 'ROUTE_MISSING', 'configured routing without a target route must be explicit')
assert(r3.operational_state == 'BLOCKED', 'missing route must block the reactor')

assert(summary.fuel_data_summary.fresh == 1)
assert(summary.fuel_data_summary.stale == 1)
assert(summary.fuel_data_summary.missing == 1)
assert(summary.operational_counts.configured == 3)
assert(summary.operational_counts.ready == 1)
assert(summary.operational_counts.blocked == 2)
assert(summary.routing_state == 'ROUTING_VALID')

-- Direct-export mode is a legitimate route state when routing was never configured.
local direct = {
  enabled = true,
  bridge = 'meBridge_0',
  reactors = { { label = 'R1', reactor_id = 'rid-1', inlet = 'inlet_1', connected = true, fuel_pct = 60 } },
}
operational.enrich(direct, {
  config = config,
  fuel_status = cache,
  rs_router = {
    get_routing_state = function() return 'ROUTING_NOT_CONFIGURED' end,
    get_tree = function() return {} end,
    get_valve_status = function() return {} end,
  },
  now_ms = 100000,
})
assert(direct.reactors[1].route_state == 'DIRECT')
assert(direct.reactors[1].operational_state == 'READY')

print('fuel_operational_summary_test.lua: ok')
