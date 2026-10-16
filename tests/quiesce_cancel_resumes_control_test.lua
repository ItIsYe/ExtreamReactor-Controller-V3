package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: ein STORNIERTER Update-Quiesce liess die Rolle fuer immer
-- stehen.
--
-- core/update_handshake.lua's reset() storniert einen Quiesce-Request
-- ausdruecklich nur, solange die Rolle noch laeuft ("Only cancel a request
-- while the role is still running") -- installer/auto_update.lua's
-- recover_unexpected() tut genau das, wenn im Zustand QUIESCE_REQUESTED
-- etwas schiefgeht, und rebootet dabei NICHT.
--
-- on_quiesce() setzt bei RT und FUEL aber eine Sperre, die den kompletten
-- Betrieb unterdrueckt: RT's rt_update_quiescing laesst control_tick()
-- sofort zurueckkehren (weder v1 noch v2 regelt noch), FUEL's
-- _state.quiesce laesst begin_transaction() mit "quiescing" scheitern
-- (keine Lieferung mehr). Diese Sperren hatten keinen Rueckweg: nach einem
-- abgebrochenen Update stand die Node bis zum naechsten Reboot -- bei RT
-- mit Flow 0 auf ALLEN Turbinen und eingehaengten Coils, waehrend Anzeige
-- und Drehzahlmessung normal weiterliefen (der Status-Snapshot liest die
-- Hardware unabhaengig von control_tick()).
--
-- Die Bestaetigung ist bei RT umso unwahrscheinlicher, je groesser die
-- Anlage ist: apply_update_quiesce() verlangt von JEDER Turbine einen
-- bestaetigten Readback (Flow 0, inaktiv, Coil eingehaengt) -- mit 50
-- Turbinen deutlich haeufiger unvollstaendig als mit 25.

local support_runtime = require('nodes.support.runtime')
local update_handshake = require('core.update_handshake')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected)
      .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- Treibt run_fast_loop() ueber genau `cycles` Zyklen und beendet sie dann
-- per Fehler (die Schleife selbst hat keinen normalen Ausgang ausser dem
-- bestaetigten Quiesce). `on_cycle(n)` darf den Handshake zwischendurch
-- veraendern -- genau so sieht eine Stornierung im Feld aus.
local function drive_fast_loop(quiesce_opts, cycles, on_cycle)
  local os_start_timer, os_pull_event = os.startTimer, os.pullEvent
  local timer_id = 0
  os.startTimer = function() timer_id = timer_id + 1; return timer_id end
  local pulls = 0
  os.pullEvent = function()
    pulls = pulls + 1
    if pulls > cycles then error('STOP-TEST', 0) end
    if on_cycle then on_cycle(pulls) end
    return 'timer', timer_id
  end
  local services = { tick = function() end }
  local comms = { handle_event = function() end }
  local ok, err = pcall(support_runtime.run_fast_loop, {
    receive_timeout = 1, services = services, comms = comms,
    quiesce_opts = quiesce_opts,
  })
  os.startTimer, os.pullEvent = os_start_timer, os_pull_event
  return ok, err
end

-- 1. Quiesce angefordert, on_quiesce() bestaetigt NICHT (genau der Fall, der
--    bei 50 Turbinen eintritt), dann storniert der Updater den Request:
--    on_quiesce_cancelled() muss genau einmal laufen -- das ist der einzige
--    Weg zurueck in den Regelbetrieb.
do
  local handshake = update_handshake.new()
  update_handshake.request_quiesce(handshake)

  local attempts, cancels = 0, 0
  local opts = {
    handshake = handshake,
    on_quiesce = function() attempts = attempts + 1; return false end,
    on_quiesce_cancelled = function() cancels = cancels + 1 end,
  }
  drive_fast_loop(opts, 6, function(cycle)
    -- Der Updater bricht nach zwei erfolglosen Zyklen ab (auto_update.lua's
    -- recover_unexpected() -> reset()), ohne zu rebooten.
    if cycle == 3 then assert_true(update_handshake.reset(handshake), 'reset abgelehnt') end
  end)

  assert_true(attempts >= 2, 'on_quiesce wurde nicht wiederholt versucht: ' .. attempts)
  assert_eq(cancels, 1, 'Stornierung wurde nicht (oder mehrfach) gemeldet')
  assert_eq(handshake.state, update_handshake.STATE.IDLE, 'Handshake-Zustand nach reset')
end

-- 2. Kein Quiesce-Request -> niemals ein Storno-Callback. Die Ruecknahme
--    darf kein periodisches Ereignis werden (sie setzt bei RT den
--    Node-Zustand auf RUNNING zurueck).
do
  local handshake = update_handshake.new()
  local cancels = 0
  drive_fast_loop({
    handshake = handshake,
    on_quiesce = function() return false end,
    on_quiesce_cancelled = function() cancels = cancels + 1 end,
  }, 5)
  assert_eq(cancels, 0, 'Storno ohne vorherigen Quiesce-Request gemeldet')
end

-- 3. Bestaetigter Quiesce beendet die Schleife weiterhin sauber -- der
--    Rueckweg darf den eigentlichen Update-Pfad nicht aufweichen.
do
  local handshake = update_handshake.new()
  update_handshake.request_quiesce(handshake)
  local cancels = 0
  local ok = drive_fast_loop({
    handshake = handshake,
    on_quiesce = function() return true end,
    on_quiesce_cancelled = function() cancels = cancels + 1 end,
  }, 10)
  assert_true(ok, 'run_fast_loop endete nicht sauber nach bestaetigtem Quiesce')
  assert_eq(handshake.state, update_handshake.STATE.RUNTIME_STOPPED, 'Endzustand')
  assert_eq(cancels, 0, 'bestaetigter Quiesce darf nicht als Storno gelten')
end

-- 4. RT verdrahtet den Rueckweg tatsaechlich und verlaesst die Sperre.
do
  local src = io.open('xreactor/nodes/rt/main.lua'):read('*a')
  assert_true(src:find('on_quiesce_cancelled = update_quiesce_resume', 1, true),
    'RT verdrahtet on_quiesce_cancelled nicht')
  local body = src:match('local function update_quiesce_resume%(%)(.-)\nend')
  assert_true(body ~= nil, 'update_quiesce_resume() fehlt')
  assert_true(body:find('rt_update_quiescing = false', 1, true),
    'update_quiesce_resume() loest die Regelsperre nicht')
end

-- 5. FUEL: ein UNBESTAETIGTER Quiesce (fehlende Ventil-ACKs -- genau der
--    Fall, in dem der Updater aufgibt) laesst sich zurueckholen und erlaubt
--    danach wieder Lieferungen. Ein BESTAETIGTER bleibt bestehen: ab da
--    gehoert die Hardware dem gestoppten Runtime-Zustand, Erholung heisst
--    Reboot -- dieselbe Grenze, die update_handshake.reset() selbst zieht.
do
  local clock = 1000000
  local os_epoch = os.epoch
  os.epoch = function() return clock end
  local peripheral_prev = _G.peripheral
  local modem = {
    isWireless = function() return true end,
    open = function() end,
    transmit = function() return true end,
  }
  _G.peripheral = {
    find = function(kind) if kind == 'modem' then return modem end end,
    isPresent = function() return false end,
    wrap = function() return nil end,
  }

  local rr = require('nodes.fuel.redstone_router')
  local function make()
    local r = rr.new({
      config = { logistics = { redstone_tree = { { integrator = 'V1', reactor = 'R1' } } } },
      comms = { get_peers = function() return { V1 = { down = false, stale = false } } end },
      log = function() end, warn_once = function() end,
    })
    r:refresh()
    return r
  end

  local router = make()
  assert_eq(router:begin_quiesce('UPDATE_QUIESCE'), false,
    'Quiesce ohne Ventil-ACK darf nicht bestaetigt sein')
  local ok_busy, reason = router:begin_transaction('R1', function() end, 100)
  assert_eq(ok_busy, false, 'Lieferung waehrend Quiesce erlaubt')
  assert_eq(reason, 'quiescing', 'Sperrgrund')

  assert_true(router:cancel_quiesce('TEST'), 'cancel_quiesce lehnte eine offene Sperre ab')
  assert_eq(router._state.quiesce, nil, 'Quiesce-Zustand nicht geloescht')
  local _, reason2 = router:begin_transaction('R1', function() end, 100)
  assert_true(reason2 ~= 'quiescing',
    'FUEL bleibt nach Storno gesperrt: ' .. tostring(reason2))

  local confirmed = make()
  confirmed._state.quiesce = { state = 'CONFIRMED' }
  assert_eq(confirmed:cancel_quiesce('TEST'), false,
    'bestaetigter Quiesce wurde zurueckgenommen')
  assert_true(confirmed._state.quiesce ~= nil, 'bestaetigter Quiesce-Zustand geloescht')

  _G.peripheral = peripheral_prev
  os.epoch = os_epoch
end

print('quiesce_cancel_resumes_control_test: OK')
