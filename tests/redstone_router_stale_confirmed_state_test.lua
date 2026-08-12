package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer ROUTER-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 17 "KRITISCHER SAFETYFEHLER"). confirmed_valve_
-- state[key] wurde nie geloescht und ueberlebte beliebig viele nachfolgende
-- Transaktionen fuer denselben Ventilschluessel -- _check_valve_batch()
-- pruefte nur "applied==true and high==entry.high", ohne zu wissen, zu
-- WELCHEM Kommando dieser Bestaetigungszustand gehoerte. Dieser Test
-- reproduziert den in der Praxis natuerlich auftretenden Fall: eine erste
-- Transaktion bestaetigt beide Ventile BLOCKED (high=true) in ihrer
-- WAIT_FINAL_ACKS-Phase; eine ZWEITE, spaetere Transaktion sendet in ihrer
-- eigenen WAIT_BLOCK_ACKS-Phase erneut BLOCKED (high=true) fuer dieselben
-- Ventile -- aber alle ACKs dieses neuen Kommandos gehen verloren
-- (check_pending_acks() gibt nach VALVE_ACK_MAX_RETRIES auf). Der alte,
-- zufaellig passende Bestaetigungszustand der ERSTEN Transaktion darf NICHT
-- als Beweis fuer die ZWEITE gelten -- die zweite Transaktion muss
-- fehlschlagen (kein Export), statt faelschlich weiterzulaufen.

local clock = 1000000
os.epoch = function() return clock end

local redstone_router = require('nodes.fuel.redstone_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- ── Mock-Funkmodem + Peripheral-Umgebung ────────────────────────────────────

local mock_modem = {
  isWireless = function() return true end,
  open = function() end,
  transmit = function() return true end,
}
_G.peripheral = {
  find = function(kind) if kind == 'modem' then return mock_modem end return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}

local function valve_key(integrator, side)
  return tostring(integrator or '') .. '|' .. tostring(side)
end

local function ack(router, integrator, side, applied, high)
  local key = valve_key(integrator, side)
  local entry = router._state.pending_valve_acks and router._state.pending_valve_acks[key]
  if not entry then error('no pending command for ' .. key) end
  router:handle_valve_ack({
    type = 'VALVE_ACK', command_id = entry.command_id,
    src = entry.dst, dst = entry.src,
    applied = applied, high = (high == nil) and entry.high or high,
  })
end

-- Treibt check_pending_acks() so oft mit ausreichend Zeitabstand, dass der
-- gesamte Retry-Budget verbraucht wird und die betroffenen Eintraege ohne
-- confirmed_valve_state-Update aus pending_valve_acks entfernt werden --
-- simuliert real verlorene ACKs, kein direkter State-Eingriff.
local function exhaust_pending_acks(router)
  for _ = 1, 5 do
    clock = clock + 3100
    router:check_pending_acks()
  end
end

local function make_router()
  local tree = {
    { side = 'top', integrator = 'VALVE-A', reactor = 'R1', label = 'Reactor1' },
    { side = 'bottom', integrator = 'VALVE-B', reactor = 'R2', label = 'Reactor2' },
  }
  local router = redstone_router.new({
    config = { logistics = { redstone_tree = tree } },
    comms = { get_peers = function() return { ['VALVE-A'] = { down = false }, ['VALVE-B'] = { down = false } } end },
    log = function() end,
    warn_once = function() end,
  })
  router:refresh()
  return router
end

local router = make_router()

-- ── Transaktion 1: laeuft vollstaendig durch, hinterlaesst confirmed_
--    valve_state[key] = { applied=true, high=true, command_id=<tx1 CID> }
--    fuer BEIDE Ventile (aus der WAIT_FINAL_ACKS-Phase nach dem Export). ──
local export1 = false
router:begin_transaction('R1', function() export1 = true end, 500)
ack(router, 'VALVE-A', 'top', true, true)
ack(router, 'VALVE-B', 'bottom', true, true)
router:tick(clock)
assert_eq(router._state.transaction.state, 'WAIT_OPEN_ACKS', 'tx1 should reach WAIT_OPEN_ACKS')

ack(router, 'VALVE-A', 'top', true, false)
router:tick(clock)
assert_eq(router._state.transaction.state, 'WAIT_SETTLE', 'tx1 should reach WAIT_SETTLE')

clock = clock + 500
router:tick(clock)
assert_true(export1, 'tx1 export should have run')
assert_eq(router._state.transaction.state, 'HOLD_OPEN', 'tx1 should reach HOLD_OPEN')

clock = clock + 600
router:tick(clock)
assert_eq(router._state.transaction.state, 'WAIT_FINAL_ACKS', 'tx1 should reach WAIT_FINAL_ACKS')

ack(router, 'VALVE-A', 'top', true, true)
ack(router, 'VALVE-B', 'bottom', true, true)
router:tick(clock)
assert_eq(router._state.transaction, nil, 'tx1 should complete cleanly')

-- Stale state now sits in confirmed_valve_state for both keys, both
-- applied=true/high=true, tied to tx1's now-irrelevant command ids.
assert_true(router._state.confirmed_valve_state['VALVE-A|top'] ~= nil, 'stale confirmed state must exist for VALVE-A')
assert_true(router._state.confirmed_valve_state['VALVE-B|bottom'] ~= nil, 'stale confirmed state must exist for VALVE-B')
local stale_cid_a = router._state.confirmed_valve_state['VALVE-A|top'].command_id
local stale_cid_b = router._state.confirmed_valve_state['VALVE-B|bottom'].command_id

-- ── Transaktion 2: sendet erneut BLOCKED (high=true) fuer dieselben
--    Ventile -- exakt derselbe angeforderte Wert wie der stale State. ALLE
--    ACKs dieses NEUEN Kommandos gehen verloren. Die Transaktion darf
--    NIEMALS ueber den alten, zufaellig passenden Bestaetigungszustand von
--    Transaktion 1 hinweg als bestaetigt gelten. ──
local export2 = false
local ok2, reason2 = router:begin_transaction('R2', function() export2 = true end, 500)
assert_eq(ok2, true, 'tx2 should start')
assert_eq(router._state.transaction.state, 'WAIT_BLOCK_ACKS', 'tx2 should start in WAIT_BLOCK_ACKS')

-- New command ids for the same keys must differ from the stale ones.
local new_cid_a = router._state.pending_valve_acks['VALVE-A|top'].command_id
local new_cid_b = router._state.pending_valve_acks['VALVE-B|bottom'].command_id
assert_true(new_cid_a ~= stale_cid_a, 'tx2 must issue a fresh command_id for VALVE-A, distinct from tx1')
assert_true(new_cid_b ~= stale_cid_b, 'tx2 must issue a fresh command_id for VALVE-B, distinct from tx1')

exhaust_pending_acks(router)
assert_true(router._state.pending_valve_acks['VALVE-A|top'] == nil, 'tx2 VALVE-A ack must have been given up on')
assert_true(router._state.pending_valve_acks['VALVE-B|bottom'] == nil, 'tx2 VALVE-B ack must have been given up on')

router:tick(clock)

assert_true(not export2,
  'CRITICAL SAFETY: tx2 export must never run -- its own block ACKs were lost and must not be ' ..
  'satisfied by a stale confirmed_valve_state left over from tx1 for the same keys/values')
assert_eq(router._state.transaction, nil,
  'tx2 must abort (fail-safe) once its current command_id cannot be proven confirmed, instead of ' ..
  'silently advancing past WAIT_BLOCK_ACKS using stale state')

print('redstone_router_stale_confirmed_state_test.lua: ok')
