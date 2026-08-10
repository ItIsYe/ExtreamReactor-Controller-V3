package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local clock = 1000000
os.epoch = function() return clock end
local redstone_router = require('nodes.fuel.redstone_router')

local transmitted = {}
local modem = {
  isWireless = function() return true end,
  open = function() end,
  transmit = function(_, _, message) transmitted[#transmitted + 1] = message; return true end,
}
_G.peripheral = {
  find = function(kind) if kind == 'modem' then return modem end end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}

local peers = { ['VALVE-A'] = { down = false, stale = false } }
local router = redstone_router.new({
  config = { logistics = { redstone_tree = {
    { side = 'top', integrator = 'VALVE-A', reactor = 'R1', label = 'R1' },
  } } },
  comms = { get_peers = function() return peers end },
  log = function() end,
  warn_once = function() end,
})
router:refresh()

local function ack_current(high)
  local key = 'VALVE-A|top'
  local entry = assert(router._state.pending_valve_acks[key], 'pending valve command required')
  router:handle_valve_ack({
    type = 'VALVE_ACK', command_id = entry.command_id,
    src = entry.dst, dst = entry.src, applied = true, high = high,
  })
end

local exported = false
assert(router:begin_transaction('R1', function() exported = true end, 500))
local tx = router._state.transaction
local ok_refresh, why = router:refresh()
assert(ok_refresh == false and why == 'busy', 'refresh must defer during active transaction')
assert(router._state.transaction == tx, 'refresh must not replace active transaction')
assert(router._state.refresh_deferred == true, 'deferred refresh marker required')

ack_current(true)
router:tick(clock)
assert(router._state.transaction.state == 'WAIT_OPEN_ACKS')
ack_current(false)
router:tick(clock)
assert(router._state.transaction.state == 'WAIT_SETTLE')

-- The valve was confirmed open, then disappeared before the physical export.
peers['VALVE-A'] = { down = true, stale = true }
clock = clock + 500
router:tick(clock)
assert(exported == false, 'export must not run after route peer becomes stale')
assert(router._state.transaction == nil, 'stale route must abort transaction')

-- Next idle tick applies the deferred discovery refresh safely.
router:tick(clock + 1)
assert(router._state.refresh_deferred == false, 'deferred refresh must be consumed after transaction')

print('redstone_router_refresh_transaction_race_test.lua: ok')
