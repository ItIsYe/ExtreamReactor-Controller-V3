package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test: ein Reaktor-Pfad kann aus MEHREREN Ventilen in Serie
-- bestehen (ein gemeinsames Trunk-Ventil plus ein reaktor-eigenes
-- Zweigventil), und ein Baum kann mehr als 1-2 Reaktoren versorgen.
--
-- Das PRIMAERE Konfigurationsformat ist die flache Routenliste mit 'path'
-- (siehe tests/redstone_router_flat_path_multi_valve_chain_test.lua fuer
-- denselben Testfall im NEUEN Format). Dieser Test bleibt bestehen, um die
-- automatische Rueck-Konvertierung des ALTEN, verschachtelten 'children'-
-- Baumformats (normalize_with_errors() in nodes/fuel/redstone_router.lua)
-- dauerhaft abzusichern -- bereits bestehende Configs duerfen nicht kaputt-
-- gehen.
--
-- Feature (2026-09-03): jeder Knoten braucht jetzt zwingend ein
-- 'integrator' (VALVE-Node-ID) -- der frueher unterstuetzte bare-redstone-
-- Knoten ohne Integrator (lokal an FUEL) existiert nicht mehr. Alle vier
-- Ventile sind daher jetzt Funk-VALVE-Nodes.
--
-- Baum (Legacy-Format):
--   TRUNK (Trunk-Ventil)
--     ├─ VALVE-R1              -> Reactor1
--     ├─ VALVE-B (Funk-Node)   -> Reactor2
--     └─ VALVE-R3              -> Reactor3
--
-- Liefert an Reactor2: der Pfad ist [TRUNK, VALVE-B] -- ZWEI Ventile
-- in Serie. Waehrend der Lieferung muessen VALVE-R1/VALVE-R3 (die
-- Nebenaeste zu Reactor1/Reactor3) blockiert bleiben.

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

-- ── Mock-Umgebung: Funkmodem fuer alle Ventile ──────────────────────────────

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

local function ack(router, integrator, applied, high)
  local entry = router._state.pending_valve_acks and router._state.pending_valve_acks[integrator]
  if not entry then error('no pending command for ' .. integrator) end
  router:handle_valve_ack({
    type = 'VALVE_ACK', command_id = entry.command_id,
    src = entry.dst, dst = entry.src,
    applied = applied, high = (high == nil) and entry.high or high,
  })
end

local function requested(router, id)
  return (router._state.valve_requested or {})[id]
end

local tree = {
  {
    integrator = 'TRUNK',
    children = {
      { integrator = 'VALVE-R1', reactor = 'R1', label = 'Reactor1' },
      { integrator = 'VALVE-B', reactor = 'R2', label = 'Reactor2' },
      { integrator = 'VALVE-R3', reactor = 'R3', label = 'Reactor3' },
    },
  },
}

local peers = {
  TRUNK = { down = false }, ['VALVE-R1'] = { down = false },
  ['VALVE-B'] = { down = false }, ['VALVE-R3'] = { down = false },
}
local router = redstone_router.new({
  config = { logistics = { redstone_tree = tree } },
  comms = { get_peers = function() return peers end },
  log = function() end,
  warn_once = function() end,
})
router:refresh()

-- Struktur-Sanity: 4 Ventile insgesamt (1 Trunk + 3 Zweige), Pfad zu R2
-- besteht aus GENAU 2 Ventilen (Trunk + eigener Zweig).
assert_eq(router:valve_count(), 4, 'tree should expose 4 valves total (1 trunk + 3 branches)')
local path_to_r2 = router:get_path_to('R2')
assert_eq(#path_to_r2, 2, 'the route to R2 must consist of exactly 2 valves in series (trunk + branch)')
assert_eq(path_to_r2[1], 'TRUNK', 'first hop must be the shared trunk valve')
assert_eq(path_to_r2[2], 'VALVE-B', 'second hop must be R2 own branch valve')

-- refresh() blockiert bereits beim Laden alles.
assert_eq(requested(router, 'TRUNK'), 'BLOCKED', 'trunk must start blocked')
assert_eq(requested(router, 'VALVE-R1'), 'BLOCKED', 'Reactor1 branch must start blocked')
assert_eq(requested(router, 'VALVE-R3'), 'BLOCKED', 'Reactor3 branch must start blocked')

local exported = false
local ok_start, reason_start = router:begin_transaction('R2', function() exported = true end, 500)
assert_true(ok_start, 'begin_transaction should start: ' .. tostring(reason_start))

-- ── Phase 1: WAIT_BLOCK_ACKS -- alle 4 Ventile werden auf BLOCKED gesetzt ──
router:tick(clock)
assert_eq(requested(router, 'TRUNK'), 'BLOCKED', 'trunk re-confirmed blocked in phase 1')
assert_eq(requested(router, 'VALVE-R1'), 'BLOCKED', 'Reactor1 branch re-confirmed blocked in phase 1')
assert_eq(requested(router, 'VALVE-R3'), 'BLOCKED', 'Reactor3 branch re-confirmed blocked in phase 1')
assert_true(router._state.transaction.state == 'WAIT_BLOCK_ACKS', 'must wait for the network valve ACK before opening anything')
assert_true(not exported, 'export must not happen before the block phase is confirmed')

ack(router, 'TRUNK', true, true)
ack(router, 'VALVE-B', true, true) -- BLOCKED-ACK fuer Phase 1
ack(router, 'VALVE-R1', true, true)
ack(router, 'VALVE-R3', true, true)
clock = clock + 100
router:tick(clock)
assert_eq(router._state.transaction.state, 'WAIT_OPEN_ACKS', 'block phase confirmed -> must move on to opening the target path')

-- ── Phase 2: WAIT_OPEN_ACKS -- NUR der Pfad zu R2 (TRUNK + VALVE-B) ─────────
--    oeffnet, VALVE-R1/VALVE-R3 bleiben unveraendert blockiert. ────────────
assert_eq(requested(router, 'TRUNK'), 'OPEN', 'trunk valve must be requested open')
assert_eq(requested(router, 'VALVE-R1'), 'BLOCKED', 'Reactor1 branch must stay blocked while R2 is being served')
assert_eq(requested(router, 'VALVE-R3'), 'BLOCKED', 'Reactor3 branch must stay blocked while R2 is being served')
assert_true(not exported, 'export must not happen before the open phase is confirmed')

ack(router, 'TRUNK', true, false)
ack(router, 'VALVE-B', true, false) -- OPEN-ACK fuer Phase 2
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
assert_eq(requested(router, 'TRUNK'), 'BLOCKED', 'trunk must be requested blocked again in the final phase')

ack(router, 'TRUNK', true, true)
ack(router, 'VALVE-B', true, true) -- finales BLOCKED-ACK
ack(router, 'VALVE-R1', true, true)
ack(router, 'VALVE-R3', true, true)
clock = clock + 100
router:tick(clock)
assert_true(router._state.transaction == nil, 'transaction must complete once the final block is confirmed')
assert_eq(requested(router, 'TRUNK'), 'BLOCKED', 'trunk must end blocked')
assert_eq(requested(router, 'VALVE-R1'), 'BLOCKED', 'Reactor1 branch must end blocked')
assert_eq(requested(router, 'VALVE-R3'), 'BLOCKED', 'Reactor3 branch must end blocked')

print("redstone_router_nested_multi_valve_chain_test.lua: ok")
