package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer das NEUE, primaere Konfigurationsformat (Fix
-- 2026-07-19, siehe nodes/fuel/redstone_router.lua): statt eines
-- verschachtelten Baums (children=...) ist jede Route jetzt ein flacher
-- Eintrag mit einer geordneten Ventilliste direkt am Reaktor ("path").
-- Ein gemeinsames Ventil auf dem Weg zu mehreren Reaktoren wird einfach
-- als IDENTISCHE {side=,integrator=}-Kombination in mehreren Routen-Pfaden
-- wiederholt -- keine Tabellen-Verschachtelung mehr noetig. Dieser Test
-- treibt exakt dasselbe Szenario wie tests/redstone_router_nested_multi_
-- valve_chain_test.lua (dort im alten, automatisch konvertierten
-- children-Format) im NEUEN Format durch, um zu beweisen: beide Formen
-- fuehren zu identischem Laufzeitverhalten.
--
-- Routen:
--   Reactor1: path = [ back ]
--   Reactor2: path = [ back, left@VALVE-B ]   -- ZWEI Ventile in Serie
--   Reactor3: path = [ back, front ]
--
-- "back" ist hier ein gemeinsames Trunk-Ventil, das einfach in ALLEN DREI
-- Pfaden wiederholt wird -- genau das ist der neue, einfachere Weg,
-- mehrere Reaktoren ueber ein gemeinsames Ventil zu fuehren.

local clock = 1000000
os.epoch = function() return clock end

local redstone_router = require('nodes.fuel.redstone_router')
local protocol = require('core.protocol')
local SECRET = 'router-test-secret-1234'

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- ── Mock-Umgebung: Funkmodem (fuer VALVE-B) + lokales Redstone ──────────────

local redstone_state = {}
_G.redstone = {
  setOutput = function(side, high) redstone_state[side] = high end,
}

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
  local message = {
    type = 'VALVE_ACK', command_id = entry.command_id,
    src = entry.dst, dst = entry.src,
    applied = applied, high = (high == nil) and entry.high or high, ts = clock,
  }
  message.auth = { algorithm = 'HMAC-SHA256',
    mac = assert(protocol.sign_value(protocol.valve_auth_value(message), SECRET)) }
  router:handle_valve_ack(message)
end

local routes = {
  { reactor = 'R1', label = 'Reactor1', path = { { side = 'back' }, { side = 'right' } } },
  { reactor = 'R2', label = 'Reactor2', path = { { side = 'back' }, { side = 'left', integrator = 'VALVE-B' } } },
  { reactor = 'R3', label = 'Reactor3', path = { { side = 'back' }, { side = 'front' } } },
}

local router = redstone_router.new({
  config = { auth_secret = SECRET, logistics = { redstone_tree = routes } },
  comms = { get_peers = function() return { ['VALVE-B'] = { down = false } } end },
  log = function() end,
  warn_once = function() end,
})
router:refresh()

-- Struktur-Sanity: 4 einzigartige Ventile (back ist in allen 3 Routen
-- identisch und wird dedupliziert), Pfad zu R2 besteht aus 2 Ventilen.
assert_eq(router:valve_count(), 4, 'the shared trunk valve must be deduplicated across all 3 routes (back+right+left+front = 4 unique valves)')
local path_to_r2 = router:get_path_to('R2')
assert_eq(#path_to_r2, 2, 'the route to R2 must consist of exactly 2 valves in series (trunk + branch)')
assert_eq(path_to_r2[1], 'back', 'first hop must be the shared trunk valve')
assert_eq(path_to_r2[2], 'left', 'second hop must be R2 own branch valve')

local table_summary = router:get_routing_table()
assert_eq(#table_summary, 3, 'get_routing_table must report all 3 configured reactors')

-- refresh() blockiert bereits beim Laden alles.
assert_eq(redstone_state['back'], true, 'trunk must start blocked')
assert_eq(redstone_state['right'], true, 'Reactor1 branch must start blocked')
assert_eq(redstone_state['front'], true, 'Reactor3 branch must start blocked')

local exported = false
local ok_start, reason_start = router:begin_transaction('R2', function() exported = true end, 500)
assert_true(ok_start, 'begin_transaction should start: ' .. tostring(reason_start))

-- ── Phase 1: WAIT_BLOCK_ACKS -- alle 4 Ventile werden auf BLOCKED gesetzt ──
router:tick(clock)
assert_eq(redstone_state['back'], true, 'trunk re-confirmed blocked in phase 1')
assert_eq(redstone_state['right'], true, 'Reactor1 branch re-confirmed blocked in phase 1')
assert_eq(redstone_state['front'], true, 'Reactor3 branch re-confirmed blocked in phase 1')
assert_true(router._state.transaction.state == 'WAIT_BLOCK_ACKS', 'must wait for the network valve ACK before opening anything')
assert_true(not exported, 'export must not happen before the block phase is confirmed')

ack(router, 'VALVE-B', 'left', true, true) -- BLOCKED-ACK fuer Phase 1
clock = clock + 100
router:tick(clock)
assert_eq(router._state.transaction.state, 'WAIT_OPEN_ACKS', 'block phase confirmed -> must move on to opening the target path')

-- ── Phase 2: WAIT_OPEN_ACKS -- NUR der Pfad zu R2 (back + left) oeffnet, ───
--    right/front bleiben unveraendert blockiert. ────────────────────────────
assert_eq(redstone_state['back'], false, 'trunk valve must open synchronously (no integrator)')
assert_eq(redstone_state['right'], true, 'Reactor1 branch must stay blocked while R2 is being served')
assert_eq(redstone_state['front'], true, 'Reactor3 branch must stay blocked while R2 is being served')
assert_true(not exported, 'export must not happen before the open phase is confirmed')

ack(router, 'VALVE-B', 'left', true, false) -- OPEN-ACK fuer Phase 2
clock = clock + 100
router:tick(clock)
assert_eq(router._state.transaction.state, 'WAIT_SETTLE', 'both hops of the R2 path confirmed open -> settle phase')
assert_true(not exported, 'export must still wait for the settle window')

-- ── Settle-Fenster abwarten, dann Export ────────────────────────────────────
clock = clock + 500
router:tick(clock)
assert_true(exported, 'export (action_fn) must run once the full multi-valve path is confirmed open')
assert_eq(router._state.transaction.state, 'HOLD_OPEN', 'must move to HOLD_OPEN right after export')

-- ── HOLD_OPEN abwarten -> finales Blockieren aller 4 Ventile ────────────────
clock = clock + 600
router:tick(clock)
assert_eq(router._state.transaction.state, 'WAIT_FINAL_ACKS', 'hold window elapsed -> final block phase')
assert_eq(redstone_state['back'], true, 'trunk must be re-blocked synchronously in the final phase')

ack(router, 'VALVE-B', 'left', true, true) -- finales BLOCKED-ACK
clock = clock + 100
router:tick(clock)
assert_true(router._state.transaction == nil, 'transaction must complete once the final block is confirmed')
assert_eq(redstone_state['back'], true, 'trunk must end blocked')
assert_eq(redstone_state['right'], true, 'Reactor1 branch must end blocked')
assert_eq(redstone_state['front'], true, 'Reactor3 branch must end blocked')

print("redstone_router_flat_path_multi_valve_chain_test.lua: ok")
