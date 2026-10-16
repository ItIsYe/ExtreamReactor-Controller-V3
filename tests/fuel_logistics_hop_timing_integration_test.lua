package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test: logistics_router.lua must size begin_transaction()'s
-- HOLD_OPEN window (valve_open_ms) per reactor via an injected hop_timing
-- instance (nodes/fuel/hop_timing.lua) instead of always using the flat
-- config.logistics.valve_open_ms, and must call begin_delivery()/
-- finish_delivery() around the delivery lifecycle so hop_timing can learn.
-- See nodes/fuel/hop_timing.lua's header comment for the full design.

local logistics_router = require('nodes.fuel.logistics_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function make_fake_rs_router(calls)
  local fake = {}
  function fake:route_count() return 1 end
  function fake:get_routing_state() return 'ROUTING_VALID' end
  function fake:refresh() end
  function fake:begin_transaction(target_id, action_fn, valve_open_ms, opts)
    table.insert(calls, { target_id = target_id, valve_open_ms = valve_open_ms })
    local ok, moved = action_fn()
    if opts and opts.on_complete then opts.on_complete({ state = 'COMPLETE_SAFE' }) end
    return true, 'started'
  end
  return fake
end

local function make_fake_hop_timing()
  local fake = { begin_calls = {}, finish_calls = {} }
  function fake:begin_delivery(reactor_id, path, item, started_ts)
    table.insert(self.begin_calls, { reactor_id = reactor_id, path = path, item = item, started_ts = started_ts })
  end
  function fake:finish_delivery(reactor_id)
    table.insert(self.finish_calls, reactor_id)
  end
  function fake:compute_timeout_ms(path, default_ms)
    -- Distinct, easily-asserted value: distance-aware, not the flat default.
    return default_ms + (#(path or {}) * 500)
  end
  return fake
end

local now_ms = 1000000
local os_epoch = os.epoch
os.epoch = function(kind) if kind == 'utc' then return now_ms end return os_epoch(kind) end

local fuel_status = { master_relay = { ['rid-1'] = { fuel_amount = 100, fuel_capacity = 1000, ts = now_ms } }, direct_heard = {} }

local tx_calls = {}
local fake_rs = make_fake_rs_router(tx_calls)
local fake_hop_timing = make_fake_hop_timing()

local router = logistics_router.new({
  config = {
    logistics = { enabled = true, reactors = {}, valve_open_ms = 2000 },
    reserve_items = { { item = 'bigreactors:yellorium_ingot', element = 'yellorium' } },
  },
  fuel_status = fuel_status,
  hop_timing = fake_hop_timing,
})
router._state.bridge = {
  name = 'me_bridge',
  wrapped = {
    getItem = function(_query) return { amount = 1000 } end,
    exportItemToPeripheral = function(_query, _inlet_name) return 64 end,
  },
}
router._state.export_chest = { name = 'transporter_1' }
router._state.reactors = {
  {
    label = 'Reactor A', reactor_id = 'rid-1', path = { 'VALVE-1', 'VALVE-2' },
    request_below = 0.25, fill_amount = 64, min_in_me = 32,
    resupply_cooldown_s = 0, cfg = {},
  },
}
router._state.rs_router = fake_rs

router:run_cycle()

assert_eq(#tx_calls, 1, 'expected exactly one begin_transaction call')
-- default 2000 + 2 hops * 500 = 3000, NOT the flat config default of 2000.
assert_eq(tx_calls[1].valve_open_ms, 3000, 'valve_open_ms must come from hop_timing:compute_timeout_ms(), not the flat default')

assert_eq(#fake_hop_timing.begin_calls, 1, 'expected begin_delivery() to be called once')
assert_eq(fake_hop_timing.begin_calls[1].reactor_id, 'rid-1')
assert_eq(#fake_hop_timing.begin_calls[1].path, 2)
assert_eq(fake_hop_timing.begin_calls[1].item, 'bigreactors:yellorium_ingot')

assert_eq(#fake_hop_timing.finish_calls, 1, 'expected finish_delivery() to be called once on completion')
assert_eq(fake_hop_timing.finish_calls[1], 'rid-1')

os.epoch = os_epoch

print('fuel_logistics_hop_timing_integration_test.lua: ok')
