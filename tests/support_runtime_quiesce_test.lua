package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer INSTALL-P0.2 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 4). Vor diesem Fix hatte nodes/
-- support/runtime.lua's run_event_loop() (gemeinsame Hauptschleife von RT/
-- VALVE/FUEL/REPROCESSOR/WATER) UEBERHAUPT KEINEN kontrollierten Weg, die
-- Schleife zu verlassen -- ein Auto-Update konnte Dateien ersetzen, WAEHREND
-- die Rolle weiter Hardware steuerte.
--
-- Dieser Test treibt die ECHTE run_event_loop()-Funktion mit einer
-- gemockten os.pullEvent/os.startTimer-Eventquelle und einem echten core/
-- update_handshake.lua-Objekt: (1) ohne quiesce_opts aendert sich am
-- bisherigen Verhalten nichts (Schleife laeuft weiter, bis ein Fehler die
-- Sequenz beendet), (2) mit QUIESCE_REQUESTED wird on_quiesce() bei jedem
-- Zyklus erneut versucht, bis es true liefert, und ERST DANN endet die
-- Schleife sauber mit RUNTIME_STOPPED.

local support_runtime = require('nodes.support.runtime')
local update_handshake = require('core.update_handshake')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function fresh_services()
  local ticks = 0
  return { tick = function() ticks = ticks + 1 end }, function() return ticks end
end

-- 1. on_quiesce() wird wiederholt versucht, bis es true liefert; erst dann
--    endet die Schleife sauber (kein crash_screen, keine Endlosschleife) und
--    der Handshake landet bei RUNTIME_STOPPED.
do
  local os_start_timer = os.startTimer
  local os_pull_event = os.pullEvent
  local timer_id = 0
  os.startTimer = function() timer_id = timer_id + 1; return timer_id end

  -- Jeder "Zyklus" besteht aus genau einem Timer-Event (schliesst die innere
  -- Warteschleife sofort), damit services:tick() und die Quiesce-Pruefung
  -- bei jedem Aufruf von run_event_loop() einmal durchlaufen. Harte Grenze
  -- (statt einer unbegrenzten Schleife): schlaegt der Quiesce-Exit fehl
  -- (Regression auf den Vorfix-Code, der quiesce_opts komplett ignoriert),
  -- soll dieser Test SCHNELL und mit klarer Fehlermeldung fehlschlagen,
  -- statt die gesamte Testsuite per Endlosschleife aufzuhaengen.
  local pulls = 0
  os.pullEvent = function()
    pulls = pulls + 1
    if pulls > 50 then
      -- "terminate" im Text sorgt dafuer, dass run_event_loop() sauber
      -- zurueckkehrt (is_terminate()-Pfad) statt crash_screen() zu betreten
      -- (das seinerseits ueber denselben gemockten os.pullEvent laeuft) --
      -- die folgenden Assertions greifen dann mit einer klaren Meldung.
      error('terminate: run_event_loop() did not exit after 50 cycles -- quiesce_opts is being ignored (regression)')
    end
    return 'timer', timer_id
  end

  local services, get_ticks = fresh_services()
  local comms = { handle_event = function() end }
  local handshake = update_handshake.new()
  update_handshake.request_quiesce(handshake)

  local quiesce_attempts = 0
  local quiesce_opts = {
    handshake = handshake,
    on_quiesce = function()
      quiesce_attempts = quiesce_attempts + 1
      return quiesce_attempts >= 3  -- erst beim dritten Versuch "sicher"
    end,
  }

  support_runtime.run_event_loop(1, services, comms, nil, quiesce_opts)

  os.startTimer = os_start_timer
  os.pullEvent = os_pull_event

  assert_eq(quiesce_attempts, 3, 'on_quiesce must be retried until it confirms a safe state')
  assert_eq(handshake.state, update_handshake.STATE.RUNTIME_STOPPED,
    'the handshake must reach RUNTIME_STOPPED once on_quiesce confirms safety')
  assert_true(get_ticks() >= 3, 'services:tick() must keep running normally during the quiesce retries')
end

-- 2. Ohne quiesce_opts (bestehende Aufrufer wie z.B. Tests, die die 4-Arg-
--    Form nutzen) darf sich am Verhalten nichts aendern: die Schleife laeuft
--    weiter, bis sie durch einen Fehler (hier: absichtlich nach N Zyklen
--    geworfen, um den Test zu beenden) verlassen wird -- KEIN stiller
--    Quiesce-Exit ohne konfigurierten Handshake.
do
  local os_start_timer = os.startTimer
  local os_pull_event = os.pullEvent
  local timer_id = 0
  os.startTimer = function() timer_id = timer_id + 1; return timer_id end

  local cycles = 0
  os.pullEvent = function()
    cycles = cycles + 1
    if cycles > 3 then error('terminate: test boundary') end
    return 'timer', timer_id
  end

  local services = { tick = function() end }
  local comms = { handle_event = function() end }

  -- run_event_loop() faengt den Fehler intern per xpcall und ruft bei einem
  -- Nicht-"terminate"-Fehler crash_screen() auf -- hier absichtlich mit
  -- "terminate" im Fehlertext, damit die Funktion sauber (ohne crash_screen-
  -- Interaktion) zurueckkehrt, sobald die Testgrenze erreicht ist.
  support_runtime.run_event_loop(1, services, comms, nil, nil)

  os.startTimer = os_start_timer
  os.pullEvent = os_pull_event

  assert_true(cycles > 3, 'without quiesce_opts the loop must keep running normally (no silent early exit)')
end

print('support_runtime_quiesce_test.lua: ok')
