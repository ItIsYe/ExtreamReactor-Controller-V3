package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Das Einlernen -- zurueckgeholtes Originalverfahren aus rt2_capacity.lua
-- (bis v768), auf Betreiberwunsch.
--
--   "im learning modus muessen 80% der turbinen im ziel rpm bereich sein
--    +-15 rpm. das heisst die turbinen muessen auch unabhaengig vom master
--    waehrend des lernens -- aber auch nur waehrend des lernens -- auf 900
--    rpm gebracht werden. sobald das abgeschlossen ist geht dan wieder
--    ganz normale regelung."
--
-- Gemessen wird der hoechste Gesamtausstoss, den die Anlage jemals
-- nachweislich GLEICHZEITIG geliefert hat:
--
--   * ein Takt zaehlt nur bei >= 80 % der Flotte im Band 900 +/- 15 RPM,
--     gekuppelt und liefernd
--   * von den tauglichen Takten gilt der HOECHSTWERT, nicht der erste
--   * steigt er LEARN_STABLE_MS lang nicht mehr, ist die Anlage ausgemessen
--   * gemeldet wird er abzueglich LEARN_SAFETY_MARGIN
--
-- Was NICHT zurueckkommt: der eigene Zustand im Zustandsautomaten und der
-- gestaffelte Suchlauf (v754-v757). Beides war die Ursache der Haenger,
-- nicht das Messverfahren.

local orchestrator = require('nodes.rt.rt2_orchestrator')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- n Turbinen, davon stehen die ersten `in_band` im Zielband und gekuppelt.
local function fleet(n, in_band, energy, band_rpm)
  local t = {}
  for i = 1, n do
    local ok = i <= in_band
    t[i] = {
      name = 'T' .. i,
      rpm = ok and (band_rpm or orchestrator.TARGET_RPM) or 400,
      energy = ok and (energy or 100) or 0,
      coil_engaged = ok,
      current_flow = 1200,
    }
  end
  return t
end

local function with_margin(raw)
  return math.floor(raw * (1 - orchestrator.LEARN_SAFETY_MARGIN))
end

-- ══ 1. Waehrend des Einlernens gilt die MASTER-Vorgabe nicht ═══════════

do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local r = o.tick({ now_ms = 1000, hardware_ready = true, master_percent = 20,
    turbines = fleet(50, 0), reactor = {} })

  assert_true(r.capacity.learning, 'der Knoten lernt ein')
  assert_eq(r.effective_percent, 100, 'die MASTER-Vorgabe von 20 % ist uebersteuert')
  for _, t in ipairs(r.turbines) do
    assert_eq(t.target_rpm, orchestrator.TARGET_RPM, 'die GANZE Flotte faehrt auf Zieldrehzahl')
  end
  assert_true(not r.capacity.ready, 'MASTER bekommt dabei keine Zahl')
  assert_eq(r.capacity.required_at_target, 40, '80 % von 50 Turbinen sind 40')
end

-- ══ 2. Die Schwelle ist 80 %, das Band +/- 15 RPM ══════════════════════

do
  local o = orchestrator.new()
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(50, 0), reactor = {} })

  -- 39 von 50 = 78 % -- dieser Takt taugt nicht als Messwert.
  local r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = fleet(50, 39), reactor = {} })
  assert_eq(r.capacity.at_target, 39)
  assert_eq(r.capacity.best_output, 0, '78 % ergeben keinen Messwert')

  -- 40 von 50 = 80 % -- jetzt zaehlt er.
  r = o.tick({ now_ms = 3000, hardware_ready = true, turbines = fleet(50, 40), reactor = {} })
  assert_eq(r.capacity.best_output, 4000, '40 Turbinen zu je 100 RF/t')
  assert_true(r.capacity.learning, 'ein einzelner Messwert legt noch nichts fest')
end

do
  -- Das Band ist eng: 16 RPM daneben zaehlt nicht mehr.
  local o = orchestrator.new()
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(10, 0), reactor = {} })
  local too_slow = orchestrator.TARGET_RPM - orchestrator.LEARN_TOLERANCE_RPM - 1
  local r = o.tick({ now_ms = 2000, hardware_ready = true,
    turbines = fleet(10, 10, 100, too_slow), reactor = {} })
  assert_eq(r.capacity.at_target, 0, too_slow .. ' RPM liegt ausserhalb von 900 +/- 15')

  local just_in = orchestrator.TARGET_RPM - orchestrator.LEARN_TOLERANCE_RPM
  r = o.tick({ now_ms = 3000, hardware_ready = true,
    turbines = fleet(10, 10, 100, just_in), reactor = {} })
  assert_eq(r.capacity.at_target, 10, just_in .. ' RPM liegt gerade noch drin')
end

-- ══ 3. Der HOECHSTWERT gilt, nicht der erste taugliche Takt ════════════
--
-- Das ist der Kern des Verfahrens: ein Takt mitten im Hochlauf darf die
-- Anlage nicht kleiner machen, als sie ist.
do
  local o = orchestrator.new()
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(10, 0), reactor = {} })

  local r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = fleet(10, 8, 60), reactor = {} })
  assert_eq(r.capacity.best_output, 480, 'erster tauglicher Takt: 8 x 60')

  r = o.tick({ now_ms = 3000, hardware_ready = true, turbines = fleet(10, 10, 100), reactor = {} })
  assert_eq(r.capacity.best_output, 1000, 'ein besserer Takt hebt den Hoechstwert')

  r = o.tick({ now_ms = 4000, hardware_ready = true, turbines = fleet(10, 8, 60), reactor = {} })
  assert_eq(r.capacity.best_output, 1000, 'ein schwaecherer Takt senkt ihn nicht')
end

-- ══ 4. Ausgemessen ist die Anlage, wenn der Hoechstwert stehenbleibt ═══

do
  local o = orchestrator.new()
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(10, 0), reactor = {} })
  local full = fleet(10, 10, 100)

  local r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = full, reactor = {} })
  assert_true(r.capacity.learning, 'direkt nach dem Messwert laeuft es noch')

  r = o.tick({ now_ms = 2000 + orchestrator.LEARN_STABLE_MS - 1, hardware_ready = true,
    turbines = full, reactor = {} })
  assert_true(r.capacity.learning, 'kurz davor auch noch')

  r = o.tick({ now_ms = 2000 + orchestrator.LEARN_STABLE_MS + 1, hardware_ready = true,
    turbines = full, reactor = {} })
  assert_true(not r.capacity.learning, 'danach ist die Anlage ausgemessen')
  assert_eq(r.capacity.reason, 'MEASURED')
  assert_eq(r.capacity.max_output, with_margin(1000), 'gemeldet wird der Hoechstwert minus Reserve')
  assert_eq(r.capacity.sustainable_turbines, 10, 'so viele liefen, als er floss')
  assert_true(r.capacity.ready, 'und jetzt darf MASTER damit rechnen')
end

-- ══ 5. Danach wieder ganz normale Regelung ═════════════════════════════

do
  local o = orchestrator.new()
  local full = fleet(50, 50, 100)
  local ms = 1000
  local r
  for _ = 1, 40 do
    o.note_master_seen(ms)
    r = o.tick({ now_ms = ms, hardware_ready = true, master_percent = 20,
      turbines = full, reactor = {} })
    if r.capacity.ready then break end
    ms = ms + 1000
  end
  assert_true(r.capacity.ready, 'Vorbedingung: das Einlernen ist durch')

  o.note_master_seen(ms + 1000)
  r = o.tick({ now_ms = ms + 1000, hardware_ready = true, master_percent = 20,
    turbines = full, reactor = {} })
  assert_eq(r.effective_percent, 20, 'jetzt gilt die MASTER-Vorgabe wieder')
  local running = 0
  for _, t in ipairs(r.turbines) do
    if t.target_rpm > 0 then running = running + 1 end
  end
  assert_eq(running, 10, '20 % von 50 Turbinen sind 10 -- der Rest steht')
end

-- ══ 6. Die Notbremse: das Einlernen endet IMMER ════════════════════════
--
-- Betreibervorgabe (2026-09-29): "das Learning muss diese Zeit raus, es muss
-- so lange gewartet werden, bis die erforderlichen Turbinen da sind."
--
-- Frueher stand hier eine Notbremse auf Zeit: nach drei Minuten endete das
-- Einlernen in jedem Fall und der hoechste bis dahin geflossene Ausstoss
-- galt als Ergebnis. Das war der falsche Tausch -- der Messwert ist die
-- Grundlage, auf der MASTER die ganze Anlage aufteilt, und eine zu kleine
-- Zahl dort ist keine Ungenauigkeit, sondern eine dauerhaft zu klein
-- ausgelegte Anlage, die von aussen genauso aussieht wie eine richtige.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local starved = fleet(10, 3, 50)   -- nur 30 % schaffen das Band, nie mehr
  o.tick({ now_ms = 1000, hardware_ready = true, master_percent = 40,
    turbines = starved, reactor = {} })

  -- Auch nach einer sehr langen Zeit wird weiter gewartet.
  local r
  for _, elapsed in ipairs({ 60000, 180000, 600000, 3600000 }) do
    r = o.tick({ now_ms = 1000 + elapsed, hardware_ready = true,
      master_percent = 40, turbines = starved, reactor = {} })
    assert_true(r.capacity.learning,
      'nach ' .. (elapsed / 1000) .. 's wird immer noch gewartet')
    assert_eq(r.capacity.reason, 'LEARNING', 'und der Grund bleibt LEARNING')
  end
  assert_true(not r.capacity.ready,
    'ohne Messpunkt bekommt MASTER keine Zahl -- lieber keine als eine falsche')

  -- Sobald die geforderten Turbinen da sind, laeuft es ganz normal durch.
  local full = fleet(10, 10, 50)
  r = o.tick({ now_ms = 1000 + 3600000 + 1000, hardware_ready = true,
    master_percent = 40, turbines = full, reactor = {} })
  assert_eq(r.capacity.reason, 'LEARNING', 'der erste volle Takt ist der Messpunkt')
  r = o.tick({ now_ms = 1000 + 3600000 + 1000 + orchestrator.LEARN_STABLE_MS + 1,
    hardware_ready = true, master_percent = 40, turbines = full, reactor = {} })
  assert_true(not r.capacity.learning, 'danach ist das Einlernen fertig')
  assert_eq(r.capacity.reason, 'MEASURED', 'und die Zahl ist gemessen, nicht geschaetzt')
end

-- ══ 6b. Ein Zaehl-Aussetzer darf das Einlernen nicht zuruecksetzen ═════
--
-- Betriebsmeldung 2026-09-29: "kein Wert genommen". Eine der beiden
-- Ursachen lag hier: die Entprellung der Turbinenzahl
-- (TOPOLOGY_DEBOUNCE_MS) galt nur, wenn GERADE NICHT gelernt wurde --
-- "if (not state.learning) and ...". Waehrend des Einlernens setzte damit
-- jede Schwankung der Zahl sofort alles zurueck: best_output,
-- last_improved_ms, den ganzen Fortschritt. Ein Peripheral, das einen Takt
-- lang nicht antwortet, sieht aber genauso aus wie eine abgebaute Turbine.
-- Flackert die Zahl, faengt das Einlernen endlos von vorn an -- und seit es
-- keinen Abbruch auf Zeit mehr gibt, faellt das auch niemandem mehr durch
-- ein Ende auf.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local full = fleet(10, 10, 50)
  local missing = fleet(9, 9, 50)     -- eine Turbine antwortet kurz nicht

  o.tick({ now_ms = 1000, hardware_ready = true, master_percent = 40,
    turbines = full, reactor = {} })
  local r = o.tick({ now_ms = 2000, hardware_ready = true, master_percent = 40,
    turbines = full, reactor = {} })
  assert_eq(r.capacity.total_turbines, 10, 'zehn Turbinen sind bekannt')
  local best_before = r.capacity.best_output
  assert_true((best_before or 0) > 0, 'und es wurde schon etwas gemessen')

  -- Ein einzelner Aussetzer: entprellt, der Fortschritt bleibt stehen.
  r = o.tick({ now_ms = 2500, hardware_ready = true, master_percent = 40,
    turbines = missing, reactor = {} })
  assert_eq(r.capacity.reason, 'TOPOLOGY_PENDING', 'ein Aussetzer wird erst einmal entprellt')
  assert_eq(r.capacity.best_output, best_before,
    'und der bisher gemessene Hoechstwert darf dabei NICHT verloren gehen')
  assert_eq(r.capacity.total_turbines, 10, 'die bekannte Zahl bleibt ebenfalls stehen')

  -- Haelt die neue Zahl an, ist es ein echter Umbau -- dann wird sehr wohl
  -- neu vermessen.
  r = o.tick({ now_ms = 2500 + orchestrator.TOPOLOGY_DEBOUNCE_MS + 1,
    hardware_ready = true, master_percent = 40, turbines = missing, reactor = {} })
  assert_eq(r.capacity.reason, 'TOPOLOGY_CHANGED', 'eine anhaltende Aenderung ist ein Umbau')
  assert_eq(r.capacity.total_turbines, 9, 'und die neue Zahl gilt')
  assert_eq(r.capacity.best_output, 0, 'der alte Messwert ist dann zu Recht weg')
end

-- ══ 6c. Das ERSTE Erkennen wird nicht entprellt ═════════════════════════
--
-- Der Sprung von "noch keine Turbine bekannt" auf N ist kein Umbau,
-- sondern die erste Messung ueberhaupt. Ihn zu entprellen wuerde den
-- Knoten nach jedem Start drei Sekunden lang behaupten lassen, die Anlage
-- schwanke -- genau das ist mir beim Bauen der Entprellung passiert.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local r = o.tick({ now_ms = 1000, hardware_ready = true, master_percent = 40,
    turbines = fleet(50, 50, 100), reactor = {} })
  assert_true(r.capacity.reason ~= 'TOPOLOGY_PENDING',
    'die erste Erkennung darf nicht als Schwanken gelten')
  assert_eq(r.capacity.total_turbines, 50, 'die Flotte ist sofort bekannt')
  assert_eq(r.capacity.required_at_target, 40, '80 % von 50 Turbinen sind 40')
end

-- ══ 7. Saettigung ist eine Diagnose, keine Regelgroesse ════════════════
--
-- Eine Turbine, die vollen Durchfluss faehrt und TROTZDEM zu langsam ist,
-- hat keine Reglerreserve mehr: entweder fehlt Dampf, oder die Spulenlast
-- ist zu hoch. Das zaehlt der Knoten mit, damit ein unsichtbares Haengen
-- zu einem lesbaren Befund wird.
do
  local o = orchestrator.new()
  local rt2_turbine = require('nodes.rt.rt2_turbine')
  local stuck = fleet(10, 2, 100)
  for i = 3, 10 do
    stuck[i].rpm = 700
    stuck[i].current_flow = rt2_turbine.MAX_FLOW
  end
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = stuck, reactor = {} })
  local r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = stuck, reactor = {} })
  assert_eq(r.capacity.saturated, 8, 'acht Turbinen haengen bei vollem Durchfluss unter dem Ziel')
  assert_true(r.capacity.learning, 'und das Einlernen kommt so nicht weiter')
end

-- ══ 8. Eine geaenderte Turbinenzahl ist eine andere Anlage ═════════════

do
  local o = orchestrator.new()
  local full = fleet(10, 10, 100)
  local ms, r = 1000, nil
  for _ = 1, 40 do
    r = o.tick({ now_ms = ms, hardware_ready = true, turbines = full, reactor = {} })
    if r.capacity.ready then break end
    ms = ms + 1000
  end
  assert_eq(r.capacity.max_output, with_margin(1000))

  -- Eine Turbine abgebaut -- aber erst, wenn es ANHAELT. Ein Peripheral,
  -- das einen Takt lang nicht antwortet, darf den Wert nicht wegwerfen.
  r = o.tick({ now_ms = ms + 1000, hardware_ready = true, turbines = fleet(9, 9, 100), reactor = {} })
  assert_eq(r.capacity.reason, 'TOPOLOGY_PENDING', 'eine schwankende Anzahl wartet erst ab')
  assert_eq(r.capacity.max_output, with_margin(1000), 'der gelernte Wert bleibt so lange stehen')

  r = o.tick({ now_ms = ms + 1000 + orchestrator.TOPOLOGY_DEBOUNCE_MS + 1, hardware_ready = true,
    turbines = fleet(9, 9, 100), reactor = {} })
  assert_eq(r.capacity.reason, 'TOPOLOGY_CHANGED', 'haelt sie an, wird neu vermessen')
  assert_true(r.capacity.learning)
  assert_eq(r.capacity.total_turbines, 9)
  assert_eq(r.capacity.required_at_target, 8, '80 % von 9 aufgerundet sind 8')
end

-- ══ 9. Keine Turbinen gelesen ist KEIN Umbau ═══════════════════════════
--
-- Ein Discovery-Aussetzer darf die Messung nicht wegwerfen.
do
  local o = orchestrator.new()
  local full = fleet(10, 10, 100)
  local ms, r = 1000, nil
  for _ = 1, 40 do
    r = o.tick({ now_ms = ms, hardware_ready = true, turbines = full, reactor = {} })
    if r.capacity.ready then break end
    ms = ms + 1000
  end
  local learned = r.capacity.max_output

  r = o.tick({ now_ms = ms + 1000, hardware_ready = true, turbines = {}, reactor = {} })
  assert_eq(r.capacity.reason, 'NO_TURBINES')
  assert_eq(r.capacity.max_output, learned, 'der gelernte Wert bleibt unberuehrt')
end

-- ══ 10. Im SAFE wird nicht gemessen ════════════════════════════════════

do
  local o = orchestrator.new()
  local full = fleet(10, 10, 100)
  local ms, r = 1000, nil
  for _ = 1, 40 do
    r = o.tick({ now_ms = ms, hardware_ready = true, turbines = full, reactor = {} })
    if r.capacity.ready then break end
    ms = ms + 1000
  end
  local learned = r.capacity.max_output

  r = o.tick({ now_ms = ms + 1000, hardware_ready = true, safety_tripped = true,
    turbines = fleet(10, 0), reactor = {} })
  assert_eq(r.capacity.max_output, learned, 'eine Ausloesung wirft die Messung nicht weg')
end

print('rt2_learning_test.lua: ok')
