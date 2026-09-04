package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer FUEL-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 7 "Async-Lieferung verliert Request und
-- Ergebnis"). Vor diesem Fix setzte logistics_router.lua's _run_supply()
-- current_request SOFORT nach begin_transaction() wieder auf nil, waehrend
-- der spaetere (asynchrone) do_export()-Callback current_request.state
-- schrieb -- Nil-Zugriffsfehler im Callback -- und werteten exported/
-- errors/cycle_log aus, BEVOR der eigentliche Export ueberhaupt lief. Dieser
-- Test treibt logistics_router.lua mit einem kontrollierbaren Mock-
-- rs_router (isoliert von redstone_router.lua's eigener, in ROUTER-P0
-- separat getesteter Zustandsmaschine) und beweist: current_request bleibt
-- bis zum echten Abschluss (Erfolg, Fehler oder Abbruch) sichtbar, und
-- Exportstatistik/Zykluslog werden ausschliesslich im Abschluss-Callback
-- geschrieben.

local logistics_router = require('nodes.fuel.logistics_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_fake_rs_router()
  local fake = { calls = {}, next_started = true, next_reason = 'started' }
  function fake:route_count() return 1 end
  function fake:get_routing_state() return 'ROUTING_VALID' end
  function fake:refresh() end
  function fake:begin_transaction(target_id, action_fn, valve_open_ms, opts)
    table.insert(self.calls, { target_id = target_id, action_fn = action_fn, valve_open_ms = valve_open_ms, opts = opts })
    return self.next_started, self.next_reason
  end
  return fake
end

local function make_router(fake_rs, export_result_fn)
  local router = logistics_router.new({
    config = {
      logistics = { enabled = true, reactors = {}, valve_open_ms = 2000 },
      -- Einzelne Fuel-Familie: Auto-Auswahl (build_fuel_families()/
      -- pick_fuel_family()) hat hier nur einen Kandidaten, damit dieser
      -- Test unveraendert die vorher fest verdrahtete
      -- 'bigreactors:yellorium_ingot' liefert.
      reserve_items = { { item = 'bigreactors:yellorium_ingot', element = 'yellorium' } },
    },
  })
  router._state.bridge = {
    name = 'me_bridge',
    wrapped = {
      getItem = function(_query) return { amount = 1000 } end,
      exportItemToPeripheral = function(query, inlet_name)
        return export_result_fn(query, inlet_name)
      end,
    },
  }
  router._state.reactors = {
    {
      label = 'Reactor A', reactor_id = nil,
      inlet = { name = 'transporter_1' },
      request_below = 0.25, fill_amount = 64, min_in_me = 32, cfg = {},
    },
  }
  router._state.rs_router = fake_rs
  return router
end

-- 1. Erfolgreicher Async-Export: current_request bleibt bis zum Abschluss
--    sichtbar, korrekte Exportmenge landet erst NACH dem Abschluss-Callback
--    in total_exported/last_cycle.
do
  local fake_rs = make_fake_rs_router()
  local router = make_router(fake_rs, function() return 64 end)

  local result = router:run_cycle()
  assert_eq(result.exported, 0, 'run_cycle should report 0 exported synchronously (delivery is still async)')
  assert_true(router._state.current_request ~= nil, 'current_request must stay set while the transaction is in flight (Request bleibt bis Abschluss sichtbar)')
  assert_eq(router._state.current_request.label, 'Reactor A', 'current_request should identify the in-flight reactor')
  assert_eq(router._state.current_request.state, 'delivering', 'current_request.state should be delivering once the transaction started')
  assert_eq(#fake_rs.calls, 1, 'exactly one delivery should be started per cycle')

  local active_request = router._state.current_request
  router:run_cycle()
  assert_eq(#fake_rs.calls, 1, 'a later supply cycle must not overwrite/start over an in-flight delivery')
  assert_true(router._state.current_request == active_request,
    'current_request must remain the same object until the router reaches a terminal state')

  -- Simuliert redstone_router.lua's spaeteren EXPORT-Schritt. Die Lieferung
  -- bleibt bis zur finalen BLOCKED-Bestaetigung sichtbar.
  fake_rs.calls[1].action_fn()

  assert_true(router._state.current_request ~= nil,
    'current_request must remain visible until final BLOCKED confirmation')
  assert_eq(router._state.total_exported, 64, 'total_exported should reflect the real delivered amount (korrekte Exportmenge)')
  assert_eq(result.exported, 64, 'last_cycle (same table reference) should be updated in place once delivery completes')
  assert_eq(result.moves[1], 'ME→[Reactor A] bigreactors:yellorium_ingot x64 via transporter_1', 'cycle log entry should be written on completion, not on start')

  fake_rs.calls[1].opts.on_complete({ state = 'COMPLETE_SAFE' })
  assert_eq(router._state.current_request, nil,
    'current_request must clear after final BLOCKED confirmation')
  assert_eq(router._state.last_delivery.terminal_state, 'COMPLETE_SAFE')
end

-- 2. Callback-Fehler: exportItemToPeripheral wirft einen Fehler -- darf
--    weder den Node abstuerzen noch current_request haengen lassen.
do
  local fake_rs = make_fake_rs_router()
  local router = make_router(fake_rs, function() error('bridge offline') end)

  router:run_cycle()
  assert_true(router._state.current_request ~= nil, 'current_request should still be set before the callback runs')

  local ok = fake_rs.calls[1].action_fn()
  assert_true(ok == false, 'export failure must be returned to the router state machine')

  assert_true(router._state.current_request ~= nil,
    'failed export remains active while the router restores BLOCKED state')
  fake_rs.calls[1].opts.on_complete({ state = 'EXPORT_FAILED', reason = 'bridge offline' })

  assert_eq(router._state.current_request, nil, 'current_request must clear after failed export reaches a safe terminal state')
  assert_eq(router._state.total_exported, 0, 'a failed export must not be credited')
  assert_eq(router._state.total_errors, 1, 'a failed export must be counted as an error')
end

-- 3. ACK-Timeout / Transaktionsabbruch VOR dem Export (redstone_router.lua's
--    on_error-Pfad, z.B. Ventil-ACK-Timeout oder -Fehlschlag): darf
--    current_request nicht fuer immer auf "aktiv" haengen lassen, obwohl
--    nie exportiert wurde.
do
  local fake_rs = make_fake_rs_router()
  local export_called = false
  local router = make_router(fake_rs, function() export_called = true; return 64 end)

  router:run_cycle()
  assert_true(router._state.current_request ~= nil)
  local call = fake_rs.calls[1]
  assert_true(type(call.opts) == 'table' and type(call.opts.on_error) == 'function', 'begin_transaction must receive an on_error callback')

  call.opts.on_error('ack_timeout:VALVE-A|top')

  assert_true(not export_called, 'the export itself must never run once the transaction aborted before EXPORT')
  assert_eq(router._state.current_request, nil, 'current_request must clear once the transaction aborts, not just once it succeeds')
  assert_eq(router._state.total_exported, 0, 'an aborted transaction must not be credited as exported')
  assert_eq(router._state.total_errors, 1, 'an aborted transaction must be counted as an error')
end

-- 4. "Shutdown"/busy-Fall: kein Transport-Handle konnte gestartet werden --
--    current_request darf nicht haengen bleiben, kein Crash.
do
  local fake_rs = make_fake_rs_router()
  fake_rs.next_started = false
  fake_rs.next_reason = 'busy'
  local router = make_router(fake_rs, function() return 64 end)

  local result = router:run_cycle()
  assert_eq(router._state.current_request, nil, 'current_request must not remain set when begin_transaction never started')
  assert_eq(result.exported, 0)
  assert_eq(router._state.total_exported, 0)
end

print('fuel_logistics_async_delivery_lifecycle_test.lua: ok')
