package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer ROUTER-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 8 "Verbindliche Sicherheitsregel"). Vor diesem
-- Fix gate'te redstone_router.lua's Transaktions-Zustandsmaschine den
-- Export ueber eine feste Settle-Zeit statt ueber echte Ventil-
-- Bestaetigung, und "watched_keys" umfasste nur die Zielpfad-Ventile,
-- nicht die zu blockierenden Nebenpfade. Dieser Test treibt die echte
-- begin_transaction()/tick()-Zustandsmaschine mit einem Mock-Funkmodem und
-- beweist: Export laeuft erst, wenn WIRKLICH JEDES betroffene Ventil
-- (Zielpfad UND Nebenpfade) bestaetigt applied==true mit dem angeforderten
-- high-Wert meldet -- unabhaengig davon, wie lange das dauert oder wie oft
-- getickt wird, solange kein Timeout/Fehlschlag eintritt.

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

local transmitted = {}
local mock_modem = {
  isWireless = function() return true end,
  open = function() end,
  transmit = function(channel, reply_channel, message)
    table.insert(transmitted, message)
    return true
  end,
}
_G.peripheral = {
  find = function(kind) if kind == 'modem' then return mock_modem end return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}

-- Findet das zuletzt an eine VALVE-Node-ID gesendete Kommando und beantwortet
-- es per VALVE_ACK -- simuliert eine VALVE-Node-Antwort.
local function ack(router, integrator, applied, high)
  local entry = router._state.pending_valve_acks and router._state.pending_valve_acks[integrator]
  if not entry then error('no pending command for ' .. integrator) end
  router:handle_valve_ack({
    type = 'VALVE_ACK', command_id = entry.command_id,
    src = entry.dst, dst = entry.src,
    applied = applied, high = (high == nil) and entry.high or high,
  })
end

local function make_router()
  local tree = {
    { integrator = 'VALVE-A', reactor = 'R1', label = 'Reactor1' },
    { integrator = 'VALVE-B', reactor = 'R2', label = 'Reactor2' },
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

-- 1. Export darf NICHT laufen, solange irgendein betroffenes Ventil
--    (Zielpfad ODER Nebenpfad) noch unbestaetigt ist -- selbst nach
--    beliebig vielen Ticks und beliebig viel verstrichener Zeit (kein
--    Timer-basiertes Gate mehr).
do
  local router = make_router()
  local export_called = false
  local ok, reason = router:begin_transaction('R1', function() export_called = true end, 500)
  assert_eq(ok, true, 'begin_transaction should start')
  assert_eq(reason, 'started', 'begin_transaction reason mismatch')
  assert_eq(router._state.transaction.state, 'WAIT_BLOCK_ACKS', 'transaction should start in WAIT_BLOCK_ACKS')

  for _ = 1, 50 do
    router:tick(clock)
    clock = clock + 100
  end
  assert_true(not export_called, 'export must not run while block ACKs are still pending')
  assert_eq(router._state.transaction.state, 'WAIT_BLOCK_ACKS', 'should still be waiting on block ACKs')

  -- Beide Ventile bestaetigen "blockiert" (high=true).
  ack(router, 'VALVE-A', true, true)
  ack(router, 'VALVE-B', true, true)
  router:tick(clock)
  assert_eq(router._state.transaction.state, 'WAIT_OPEN_ACKS', 'should advance to WAIT_OPEN_ACKS once all blocks confirmed')
  assert_true(not export_called, 'export must not run before target path is confirmed open')

  -- Nur das Zielventil bestaetigt "offen" -- viele Ticks und viel Zeit
  -- vergehen, aber KEIN Timer darf den Export erzwingen ohne Bestaetigung.
  for _ = 1, 50 do
    router:tick(clock)
    clock = clock + 100
  end
  assert_true(not export_called, 'export must not run before the target valve ACK arrives, no matter how much time passes')

  ack(router, 'VALVE-A', true, false)
  router:tick(clock)
  assert_eq(router._state.transaction.state, 'WAIT_SETTLE', 'should advance to WAIT_SETTLE once target path confirmed open')
  assert_true(not export_called, 'export must not run before settle time elapses')

  clock = clock + 500
  router:tick(clock)
  assert_true(export_called, 'export should run once target confirmed open and settle elapsed')
  assert_eq(router._state.transaction.state, 'HOLD_OPEN', 'should move to HOLD_OPEN after export')
end

-- 2. Ein fehlgeschlagenes Blockieren eines NEBENPFADS (nicht des
--    Zielpfads) muss den Export ebenfalls verhindern -- vorher wurde nur
--    der Zielpfad ueberhaupt beobachtet.
do
  local router = make_router()
  local export_called = false
  router:begin_transaction('R1', function() export_called = true end, 500)
  assert_eq(router._state.transaction.state, 'WAIT_BLOCK_ACKS')

  -- Zielpfad-Nebenventil (VALVE-B, fuer R1 ein Nebenpfad) meldet explizit
  -- "nicht angewendet".
  ack(router, 'VALVE-A', true, true)
  ack(router, 'VALVE-B', false, true)
  router:tick(clock)

  assert_true(not export_called, 'export must never run when a side-path valve fails to confirm blocked')
  assert_eq(router._state.transaction, nil, 'a failed side-path block must abort the transaction')
end

-- 3. Phasen-Timeout: ein Ventil, das nie eine ACK-Antwort liefert (und nie
--    von check_pending_acks() aufgegeben wird), darf die Transaktion nicht
--    auf ewig in WAIT_BLOCK_ACKS haengen lassen -- irgendwann muss
--    sicherheitshalber abgebrochen werden.
do
  local router = make_router()
  local export_called = false
  router:begin_transaction('R1', function() export_called = true end, 500)
  ack(router, 'VALVE-A', true, true)
  -- VALVE-B bleibt absichtlich unbeantwortet.

  clock = clock + 20000
  router:tick(clock)

  assert_true(not export_called, 'export must never run after a phase timeout')
  assert_eq(router._state.transaction, nil, 'transaction should abort after the phase deadline elapses without confirmation')
end

-- 4. Kompletter Zyklus inklusive HOLD_OPEN -> WAIT_FINAL_ACKS -> Abschluss.
do
  local router = make_router()
  local export_called = false
  router:begin_transaction('R1', function() export_called = true end, 500)
  ack(router, 'VALVE-A', true, true)
  ack(router, 'VALVE-B', true, true)
  router:tick(clock)
  ack(router, 'VALVE-A', true, false)
  router:tick(clock)
  clock = clock + 500
  router:tick(clock)
  assert_true(export_called, 'export should have run')
  assert_eq(router._state.transaction.state, 'HOLD_OPEN')

  clock = clock + 600
  router:tick(clock)
  assert_eq(router._state.transaction.state, 'WAIT_FINAL_ACKS', 'should move to WAIT_FINAL_ACKS after hold time elapses')

  ack(router, 'VALVE-A', true, true)
  ack(router, 'VALVE-B', true, true)
  router:tick(clock)
  assert_eq(router._state.transaction, nil, 'transaction should be complete once the final block is confirmed')
end

print('redstone_router_valve_confirmation_gate_test.lua: ok')
