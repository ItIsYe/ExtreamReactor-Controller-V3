package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die erste Leistungsvorgabe nach einem MASTER-Reconnect darf nicht
-- abgelehnt werden.
--
-- Der Zustand MASTER/AUTONOM wird nur im REGELTAKT neu entschieden. Eine
-- Vorgabe, die mit der ersten Nachricht nach einem Reconnect ankommt, traf
-- also noch auf AUTONOM und wurde mit INVALID_STATE abgelehnt -- obwohl der
-- Zeitstempel der Verbindung in derselben Zustellung schon gesetzt war.
--
-- MASTER liest ein INVALID_STATE als Modus-Desync, verwirft seine Annahme
-- ueber den Modus und schickt SET_MODE nach (master/message_handlers.lua).
-- Das heilt sich, kostet aber eine Runde und eine WARN-Zeile fuer einen
-- voellig normalen Vorgang.

local orchestrator = require('nodes.rt.rt2_orchestrator')
local rt2_state = require('nodes.rt.rt2_state')
local rt2_command_handler = require('nodes.rt.rt2_command_handler')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local function new_engine()
  return orchestrator.new({ master_timeout_ms = 20000, reactors = { { name = 'r1' } } })
end

local SETPOINTS = { target = 'SET_SETPOINTS', value = { power_target_percent = 60 } }

-- ── 1. Frisch verbunden, Zustandsmaschine noch nicht getickt ─────────────
do
  local engine = new_engine()
  assert_true(engine.current_state() == rt2_state.states.INIT,
    'Vorbedingung: der Knoten steht noch auf INIT')

  engine.note_master_seen(1000000)
  local result = engine.handle_command(SETPOINTS, 1000050)
  assert_true(result.ok == true, string.format(
    'die Vorgabe muss angenommen werden, abgelehnt mit %s/%s',
    tostring(result.error), tostring(result.reason_code)))
  assert_true(engine.master_percent == 60,
    'und der Prozentsatz muss uebernommen werden, er steht auf '
      .. tostring(engine.master_percent))
end

-- ── 2. Ohne lebende Verbindung bleibt es bei der Ablehnung ───────────────
do
  local engine = new_engine()
  -- MASTER lange nicht gesehen: die Verbindung ist abgelaufen.
  engine.note_master_seen(1000000)
  local result = engine.handle_command(SETPOINTS, 1000000 + 25000)
  assert_true(result.ok == false and result.reason_code == 'INVALID_STATE',
    'ohne lebende MASTER-Verbindung muss die Vorgabe abgelehnt werden')

  -- Nie gesehen: ebenso.
  local fresh = new_engine()
  local never = fresh.handle_command(SETPOINTS, 1000000)
  assert_true(never.ok == false and never.reason_code == 'INVALID_STATE',
    'ohne je eine MASTER-Nachricht wird abgelehnt')
end

-- ── 3. Ohne Uhrangabe bleibt das alte Verhalten ──────────────────────────
do
  local engine = new_engine()
  engine.note_master_seen(1000000)
  local result = engine.handle_command(SETPOINTS)
  assert_true(result.ok == false and result.reason_code == 'INVALID_STATE',
    'ohne now_ms gilt allein der Zustand der Zustandsmaschine')
end

-- ── 4. SAFE bleibt gesperrt, auch bei lebender Verbindung ────────────────
--
-- Der wichtigste Teil: eine lebende MASTER-Verbindung darf die SAFE-Sperre
-- NICHT aufweichen.
do
  local result = rt2_command_handler.handle(SETPOINTS,
    { state = rt2_state.states.SAFE, master_connected = true })
  assert_true(result.ok == false and result.reason_code == 'SAFE_MODE',
    'in SAFE wird die Vorgabe abgelehnt, egal wie lebendig die Verbindung ist')
end

-- ── 5. Der Zustand MASTER allein genuegt weiterhin ───────────────────────
do
  local result = rt2_command_handler.handle(SETPOINTS,
    { state = rt2_state.states.MASTER })
  assert_true(result.ok == true,
    'im Zustand MASTER wird auch ohne Verbindungsangabe angenommen')
end

-- ── 6. Ungueltige Werte werden weiter abgelehnt ──────────────────────────
do
  for _, bad in ipairs({ -1, 101, 'viel' }) do
    local result = rt2_command_handler.handle(
      { target = 'SET_SETPOINTS', value = { power_target_percent = bad } },
      { state = rt2_state.states.AUTONOM, master_connected = true })
    assert_true(result.ok == false and result.reason_code == 'INVALID_VALUE',
      'ein ungueltiger Prozentsatz bleibt ungueltig: ' .. tostring(bad))
  end
end

-- ── 7. Die Vorgabe wirkt im naechsten Takt ───────────────────────────────
--
-- Nicht nur die Quittung, sondern die Wirkung: bei 50 % laeuft die Haelfte
-- der Flotte.
do
  local engine = new_engine()
  engine.note_master_seen(1000000)
  local ok = engine.handle_command(
    { target = 'SET_SETPOINTS', value = { power_target_percent = 50 } }, 1000050)
  assert_true(ok.ok == true, 'Vorbedingung: die Vorgabe wird angenommen')

  local turbines = {}
  for i = 1, 4 do
    turbines[i] = { name = 't' .. i, rpm = 900, energy = 1000, coil_engaged = true,
                    current_flow = 2000, active = true }
  end
  local reactors = { { name = 'r1', safety_tripped = false,
    reactor = { fill_ratio = 0.7, current_rods = 80, active = true } } }

  local r = engine.tick({ now_ms = 1000100, hardware_ready = true,
    turbines = turbines, reactors = reactors })
  assert_true(r.state == rt2_state.states.MASTER,
    'der Knoten muss jetzt im Zustand MASTER sein, steht auf ' .. tostring(r.state))

  -- Waehrend des Einlernens gilt 100 % (Kalibrierung hat Vorrang), danach
  -- die Vorgabe. Hier zaehlt, dass master_percent angekommen ist.
  assert_true(r.master_percent == 50, string.format(
    'die Vorgabe muss im Takt ankommen, es sind %s', tostring(r.master_percent)))
end

print('ok rt2_setpoints_on_reconnect_test')
