package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Uhr-Ruecksprung: os.epoch("utc") kann zurueckspringen (Welt neu geladen,
-- Server-Zeit korrigiert). Jede zeitabhaengige Stelle im RT muss das
-- behandeln, und zwar nach EINER Regel: ein Zeitstempel aus der Zukunft ist
-- wertlos und wird verworfen, nicht ausgesessen.
--
-- Der Regler hielt sich daran (rt2_unit.lua's Stellintervall,
-- rt2_turbine.lua's Stellsperre, rt2_orchestrator.lua's push_rpm_sample --
-- jeweils nach einem Vorfall im Feld). Zwei Stellen nicht:
--
--   rt2_master_link.is_connected()  -- ein toter MASTER galt unbegrenzt als
--                                      verbunden (negative Differenz ist
--                                      immer kleiner als das Zeitfenster)
--   monitor_ui.update()             -- der Schirm fror auf einem alten,
--                                      gesund aussehenden Bild ein

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ── 1. rt2_master_link ───────────────────────────────────────────────────
do
  local link = require('nodes.rt.rt2_master_link')
  local l = link.new({ timeout_ms = 20000 })
  l.note_seen(1000000)

  assert_true(l.is_connected(1005000) == true,
    'innerhalb des Zeitfensters muss der MASTER als verbunden gelten')
  assert_true(l.is_connected(1019999) == true, 'knapp innerhalb: verbunden')
  assert_true(l.is_connected(1020000) == false, 'genau am Zeitfenster: nicht mehr verbunden')
  assert_true(l.is_connected(1025000) == false, 'darueber: nicht verbunden')

  -- Der eigentliche Punkt: Uhr springt zurueck.
  assert_true(l.is_connected(1000000 - 1) == false,
    'eine Millisekunde Ruecksprung macht den Zeitstempel ungueltig')
  assert_true(l.is_connected(1000000 - 86400000) == false,
    'ein Tag Ruecksprung darf den MASTER NICHT einen Tag lang als verbunden fuehren')

  -- Und es heilt sich: die naechste MASTER-Nachricht setzt den Zeitstempel
  -- auf die neue Uhr.
  local after = 1000000 - 86400000
  l.note_seen(after)
  assert_true(l.is_connected(after + 1000) == true,
    'nach der naechsten MASTER-Nachricht muss die Verbindung wieder stehen')

  -- Nie gesehen bleibt nie gesehen.
  local fresh = link.new({ timeout_ms = 20000 })
  assert_true(fresh.is_connected(1000000) == false,
    'ohne je eine Nachricht gibt es keine Verbindung')
end

-- ── 2. Der Knoten faellt nach einem Ruecksprung nach AUTONOM ─────────────
--
-- Nicht nur die Hilfsfunktion, sondern die Wirkung auf den Zustand: ohne
-- den Schutz waere der Knoten im Zustand MASTER geblieben und haette der
-- eingefrorenen Leistungsvorgabe weiter gefolgt.
do
  local orchestrator = require('nodes.rt.rt2_orchestrator')
  local rt2_state = require('nodes.rt.rt2_state')
  local engine = orchestrator.new({ master_timeout_ms = 20000, reactors = { { name = 'r1' } } })

  local turbines = { { name = 't1', rpm = 900, energy = 1000, coil_engaged = true,
                       current_flow = 2000, active = true } }
  local reactors = { { name = 'r1', safety_tripped = false,
                       reactor = { fill_ratio = 0.7, current_rods = 80, active = true } } }

  engine.note_master_seen(1000000)
  local r = engine.tick({ now_ms = 1000100, hardware_ready = true,
    turbines = turbines, reactors = reactors })
  assert_true(r.state == rt2_state.states.MASTER,
    'mit frischer MASTER-Nachricht muss der Zustand MASTER sein, ist ' .. tostring(r.state))

  -- Uhr springt zurueck. Der gemerkte Zeitstempel liegt jetzt in der Zukunft.
  r = engine.tick({ now_ms = 1000000 - 3600000, hardware_ready = true,
    turbines = turbines, reactors = reactors })
  assert_true(r.state == rt2_state.states.AUTONOM,
    'nach dem Uhr-Ruecksprung muss der Knoten nach AUTONOM fallen, steht aber auf '
      .. tostring(r.state))
end

-- ── 3. monitor_ui.update() friert nicht ein ──────────────────────────────
do
  local monitor_ui = require('nodes.rt.monitor_ui')

  -- Minimaler ctx: update() steigt nach dem Intervall-Tor direkt in
  -- update_status_snapshot() ein, das viel mehr braucht. Fuer diesen Test
  -- genuegt es, das TOR zu pruefen -- erreicht der Aufruf den Rumpf, wird
  -- er mit einem Fehler aus dem Rumpf abbrechen, und genau daran
  -- unterscheiden wir "Tor offen" von "Tor zu".
  local function gate_open(now, last)
    monitor_ui.last_monitor_update = last
    local ctx = { config = { monitor_interval = 1 }, last_status_snapshot = 'ALT' }
    local prev_epoch = os.epoch
    os.epoch = function() return now end
    local ok, res = pcall(monitor_ui.update, { setBackgroundColor = function() end }, ctx)
    os.epoch = prev_epoch
    -- Tor zu  -> update() kehrt mit dem alten Schnappschuss zurueck.
    -- Tor offen-> update() laeuft in den Rumpf und scheitert dort am ctx.
    if ok and res == 'ALT' then return false end
    return true
  end

  assert_true(gate_open(1000500, 1000000) == false,
    'innerhalb des Intervalls darf nicht neu gezeichnet werden')
  assert_true(gate_open(1001000, 1000000) == true,
    'nach dem Intervall muss neu gezeichnet werden')
  assert_true(gate_open(1000000 - 3600000, 1000000) == true,
    'nach einem Uhr-Ruecksprung darf der Schirm NICHT einfrieren')
end

print('ok rt_clock_rollback_guards_test')
