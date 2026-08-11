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
  local fake = { calls = {}, next_started = true, next_reason = 'started', active_phase = 'BLOCKING' }
  function fake:route_count() return 1 end
  function fake:get_routing_state() return 'ROUTING_VALID' end
  function fake:refresh() end
  function fake:begin_transaction(target_id, action_fn, valve_open_ms, opts)
    local id = opts and opts.transaction_id or 'tx-missing'
    table.insert(self.calls, { target_id = target_id, action_fn = action_fn, valve_open_ms = valve_open_ms, opts = opts, id = id })
    return self.next_started, self.next_reason, id
  end
  function fake:get_active_transaction()
    if #self.calls == 0 then return nil end
    return { transaction_id = self.calls[#self.calls].id, phase = self.active_phase, state = 'WAIT_BLOCK_ACKS' }
  end
  function fake:get_safety_latch() return nil end
  return fake
end

local function make_router(fake_rs, export_result_fn)
  local router = logistics_router.new({
    config = { logistics = { enabled = true, reactors = {}, valve_open_ms = 2000 } },
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
      label = 'Reactor A', reactor_id = 'RT-1:REACTOR-a', item = 'bigreactors:yellorium_ingot',
      inlet = { name = 'transporter_1' },
      request_below = 0.25, fill_amount = 64, min_in_me = 32, cfg = {},
    },
  }
  router.fuel_status.direct_heard['RT-1:REACTOR-a'] = {
    fuel_amount = 100, fuel_capacity = 1000, ts = os.epoch('utc'),
  }
  router._state.rs_router = fake_rs
  return router
end

-- 1. Erfolgreicher Async-Export: action_fn bewegt Material, aber die
-- Transaktion bleibt bis zur bestaetigten FINAL_BLOCK-Completion sichtbar.
do
  local fake_rs = make_fake_rs_router()
  local router = make_router(fake_rs, function() return 64 end)
  local result = router:run_cycle()
  assert_eq(result.exported, 0, 'async cycle must not claim export synchronously')
  local req = router._state.current_request
  assert_true(req ~= nil and req.transaction_id ~= nil, 'in-flight request needs a stable transaction id')
  assert_eq(req.phase, 'BLOCKING', 'initial router phase must be exposed')
  assert_eq(#fake_rs.calls, 1)
  assert_eq(fake_rs.calls[1].target_id, 'RT-1:REACTOR-a', 'global reactor identity must be the primary route target')
  assert_eq(fake_rs.calls[1].opts.target_aliases[1], 'Reactor A', 'display alias must remain a compatibility fallback')
  assert_eq(fake_rs.calls[1].opts.transaction_id, req.transaction_id, 'router and logistics must share the same transaction id')

  fake_rs.active_phase = 'OPENING'
  assert_eq(router:get_summary().current_request.phase, 'OPENING', 'summary must track router phase for same transaction')
  local action_ok = fake_rs.calls[1].action_fn()
  assert_true(action_ok == true, 'export callback should report success explicitly')
  assert_true(router._state.current_request ~= nil, 'export is not terminal until final block is confirmed')
  assert_eq(router._state.total_exported, 64)
  assert_eq(result.exported, 0, 'async callback must not mutate a potentially replaced last_cycle')
  assert_eq(#result.moves, 0, 'async callback must not append into cycle-owned moves table')

  fake_rs.calls[1].opts.on_complete({ state='COMPLETE_SAFE', transaction_id=req.transaction_id })
  assert_eq(router._state.current_request, nil, 'request clears only at terminal router completion')
  assert_eq(router._state.last_delivery.transaction_id, req.transaction_id)
  assert_eq(router._state.last_delivery.terminal_state, 'COMPLETE_SAFE')
end

-- 2. Exportfehler bleibt bis zur sicheren finalen Blockierung sichtbar.
do
  local fake_rs = make_fake_rs_router()
  local router = make_router(fake_rs, function() error('bridge offline') end)
  router:run_cycle()
  local call = fake_rs.calls[1]
  local ok, err = call.action_fn()
  assert_eq(ok, false, 'callback must report hardware/export failure to router')
  assert_true(router._state.current_request ~= nil, 'failed export still needs final-block completion')
  assert_eq(router._state.total_errors, 1)
  call.opts.on_complete({ state='EXPORT_FAILED', reason=err, transaction_id=call.id })
  assert_eq(router._state.current_request, nil)
  assert_eq(router._state.last_delivery.terminal_state, 'EXPORT_FAILED')
  assert_eq(router._state.total_errors, 1, 'same export failure must not be double-counted')
end

-- 3. Abbruch VOR Export uses on_error and terminates the request immediately.
do
  local fake_rs = make_fake_rs_router()
  local export_called = false
  local router = make_router(fake_rs, function() export_called=true; return 64 end)
  router:run_cycle()
  local call = fake_rs.calls[1]
  call.opts.on_error('ack_timeout:VALVE-A|top')
  assert_true(not export_called)
  assert_eq(router._state.current_request, nil)
  assert_eq(router._state.last_delivery.terminal_state, 'CANCELLED')
  assert_eq(router._state.total_errors, 1)
end

-- 4. Busy: no transaction started and no hanging request.
do
  local fake_rs = make_fake_rs_router(); fake_rs.next_started=false; fake_rs.next_reason='busy'
  local router = make_router(fake_rs, function() return 64 end)
  local result = router:run_cycle()
  assert_eq(router._state.current_request, nil)
  assert_eq(result.exported, 0)
end

print('fuel_logistics_async_delivery_lifecycle_test.lua: ok')
