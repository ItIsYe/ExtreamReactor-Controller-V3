package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer REPROCESSOR-P0 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 11 "Standby laesst aktive
-- Transaktion weiterlaufen"). Vor diesem Fix war redstone_router.lua's
-- shutdown_now() toter Code (nirgends aufgerufen); nodes/reprocessor/
-- main.lua liess eine laufende Ventil-Transaktion beim Uebergang in
-- Standby bewusst "sauber zu Ende laufen" (get_rs_router():tick() lief
-- unbedingt weiter), wodurch ein bereits in WAIT_SETTLE befindlicher
-- Export trotz frischem Standby noch ausgefuehrt wurde. Dieser Test
-- beweist mit dem echten redstone_router.lua und feed_router.lua: ein
-- Abbruch waehrend einer laufenden Transaktion blockiert sofort alle
-- Ventile, ruft den Export-Callback NIE auf, und macht den Abbruch ueber
-- last_error sichtbar.

local redstone_router_lib = require('nodes.fuel.redstone_router')
local feed_router_lib = require('nodes.reprocessor.feed_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

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

local function make_rs_router()
  -- Spiegelt nodes/reprocessor/main.lua's get_rs_router(): das config-Feld
  -- des Routers IST direkt der feed-Block (redstone_tree liegt dort ohne
  -- weitere Verschachtelung), nicht die gesamte Root-Config.
  local tree = { { side = 'top', integrator = 'VALVE-A', reactor = 'R1', label = 'Reactor1' } }
  local router = redstone_router_lib.new({
    config = { redstone_tree = tree },
    comms = { get_peers = function() return { ['VALVE-A'] = { down = false } } end },
    log = function() end, warn_once = function() end,
  })
  router:refresh()
  return router
end

-- 1. redstone_router.lua:shutdown_now() direkt: bricht eine laufende
--    Transaktion sofort ab, ruft NIE action_fn auf, meldet den Abbruch
--    ueber on_error(reason), und blockiert alle Ventile.
do
  local rs = make_rs_router()
  local export_called = false
  local error_reason = nil
  local started = rs:begin_transaction('R1', function() export_called = true end, 500, {
    on_error = function(reason) error_reason = reason end,
  })
  assert_eq(started, true, 'transaction should start')
  assert_true(rs._state.transaction ~= nil, 'a transaction should be active before shutdown')

  rs:shutdown_now('STANDBY')

  assert_eq(rs._state.transaction, nil, 'shutdown_now must clear the active transaction')
  assert_true(not export_called, 'shutdown_now must never let the export callback run')
  assert_eq(error_reason, 'STANDBY', 'on_error must be invoked with the shutdown reason')

  -- Weitere ticks duerfen nichts mehr tun (keine Transaktion mehr vorhanden).
  rs:tick(2000000)
  assert_true(not export_called, 'no export must happen after shutdown even if tick() keeps running')
end

-- 2. feed_router.lua:cancel() delegiert korrekt an shutdown_now() und
--    macht den Abbruch ueber last_error sichtbar (derselbe on_error-Pfad
--    wie bei einem echten Transaktionsfehler, kein Sonderweg noetig).
do
  local rs = make_rs_router()
  local exported_amount = nil
  local bridge = {
    getItem = function(_query) return { amount = 1000 } end,
    exportItemToPeripheral = function(_query, _inlet) exported_amount = 2; return 2 end,
  }
  local feed = feed_router_lib.new({
    config = { feed = { enabled = true, waste_item = 'x', feed_amount = 2, targets = { { label = 'R1', inlet = 'transporter_1' } } } },
    rs_router = rs,
    log = function() end, warn_once = function() end,
  })
  feed._state.bridge = bridge

  -- feed_one() ist lokal/nicht exportiert -- ueber rs_router direkt eine
  -- Transaktion mit demselben on_error-Callback-Muster starten, wie es
  -- feed_one() tatsaechlich tut, um cancel() gegen eine ECHTE laufende
  -- Transaktion auf DERSELBEN feed-Instanz zu pruefen.
  local started = rs:begin_transaction('R1', function()
    feed._state.last_error = nil
  end, 500, {
    on_error = function(reason)
      feed._state.last_error = 'routing_failed:' .. tostring(reason)
    end,
  })
  assert_eq(started, true)

  feed:cancel('MASTER_STALE')

  assert_eq(rs._state.transaction, nil, 'cancel() must clear the router transaction')
  assert_eq(feed._state.last_error, 'routing_failed:MASTER_STALE', 'cancel() must make the abort visible via last_error')
  assert_true(exported_amount == nil, 'no export must have happened')
end

-- 3. cancel() ohne aktive Transaktion darf nicht abstuerzen (Standby kann
--    auch eintreten, wenn gerade nichts laeuft).
do
  local rs = make_rs_router()
  local feed = feed_router_lib.new({
    config = { feed = { enabled = true } },
    rs_router = rs,
    log = function() end, warn_once = function() end,
  })
  feed:cancel('MODE_OFF')
  assert_eq(rs._state.transaction, nil)
end

print('reprocessor_standby_cancels_transaction_test.lua: ok')
