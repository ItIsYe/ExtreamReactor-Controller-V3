package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb, ueber Stunden und mehrere Fehlversuche verfolgt:
--
--   Drehzahl liest sich sauber, der Reaktor arbeitet, MASTER ist
--   unbeteiligt (Einlernen) -- und der Durchfluss steht auf 0.0.
--
-- Die Kette, die das erzeugt:
--
--   1. Der Durchfluss-RUECKMESSWERT einer Turbine ist unlesbar.
--      adapters/turbine.lua liefert dafuer seit v738 ausdruecklich nil
--      ("nil heisst jetzt nil, und der Aufrufer muss damit umgehen").
--   2. compute_flow_decision() machte daraus sofort wieder eine 0.
--   3. JEDER Halte-Zweig gibt current_flow zurueck -- entschied also 0:
--      SETTLED, SETTLING, HOLD, RAMP_COASTING, MODEL_COASTING.
--   4. Die Oberflaeche zeigt die ENTSCHEIDUNG, nicht den Messwert.
--      Deshalb stand dort "FLOW 0.0".
--   5. Die Schmutzpruefung im Orchestrator kann diese 0 nicht
--      unterdruecken -- sie hat keinen Messwert zum Vergleichen. Die 0
--      wurde also wirklich an die Hardware geschrieben.
--
-- Damit war der in v738 behobene Fehler eine Ebene tiefer zurueck, und
-- er wirkte schlimmer als das Original.

local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ══ 1. Auf Zieldrehzahl, Rueckmesswert unlesbar ════════════════════════
--
-- Der schlimmste Fall: die Turbine laeuft genau richtig, und genau
-- deshalb greift der Halte-Zweig -- und stellte den Dampf ab.

do
  local d = rt2_turbine.compute_flow_decision({
    rpm = 900, target_rpm = 900, current_flow = nil, coil_engaged = true,
  })
  -- Ohne bekannten Durchfluss gibt es nichts zu halten -- die richtige
  -- Antwort ist nicht "0 stellen", sondern GAR NICHT stellen.
  assert_eq(d.unchanged, true, string.format(
    'eine Turbine auf Zieldrehzahl darf nicht gestellt werden, nur weil ihr'
      .. ' Rueckmesswert fehlt (Durchfluss %s, Grund %s, unchanged %s)',
    tostring(d.flow), tostring(d.reason), tostring(d.unchanged)))
end

-- ══ 2. Der Regler nimmt seinen eigenen letzten Wert ════════════════════

do
  local d = rt2_turbine.compute_flow_decision({
    rpm = 900, target_rpm = 900, current_flow = nil, last_commanded_flow = 1200,
    coil_engaged = true,
  })
  assert_eq(d.reason, 'SETTLED', 'mit bekanntem Bezugspunkt haelt er ganz normal')
  assert_eq(d.flow, 1200, 'und zwar auf dem zuletzt gestellten Wert')
  assert_true(d.unchanged == nil, 'und stellt ihn auch tatsaechlich')
end

-- ══ 3. Auch die Wartesperre darf nicht auf 0 fallen ════════════════════

do
  local d = rt2_turbine.compute_flow_decision({
    rpm = 400, target_rpm = 900, current_flow = nil,
    now_ms = 1000, last_change_ms = 900,   -- innerhalb des Stellintervalls
    coil_engaged = false,
  })
  assert_eq(d.unchanged, true, string.format(
    'die Wartesperre darf ohne Rueckmesswert nichts stellen (%s/%s/%s)',
    tostring(d.flow), tostring(d.reason), tostring(d.unchanged)))
end

-- ══ 4. Mit Rueckmesswert bleibt alles wie bisher ═══════════════════════
--
-- Die Aenderung darf nur den Fall "unbekannt" betreffen.

do
  local settled = rt2_turbine.compute_flow_decision({
    rpm = 900, target_rpm = 900, current_flow = 1200, coil_engaged = true,
  })
  assert_eq(settled.reason, 'SETTLED')
  assert_eq(settled.flow, 1200)
  assert_true(settled.unchanged == nil,
    'mit Messwert bleibt es eine normale Entscheidung, kein Aussetzen')

  local ramping = rt2_turbine.compute_flow_decision({
    rpm = 400, target_rpm = 900, current_flow = 300, coil_engaged = false,
  })
  assert_eq(ramping.reason, 'RAMP_UP')
  assert_eq(ramping.flow, 300 + rt2_turbine.TRIM_STEP)

  -- Ein echter Rueckmesswert von 0 ist etwas anderes als "unbekannt" und
  -- muss weiterhin als 0 gelten.
  local real_zero = rt2_turbine.compute_flow_decision({
    rpm = 400, target_rpm = 900, current_flow = 0, coil_engaged = false,
  })
  assert_eq(real_zero.flow, rt2_turbine.TRIM_STEP,
    'eine echte 0 ist ein Messwert, kein fehlender -- von dort wird hochgefahren')
end

-- ══ 5. Die Schutzentscheidungen bleiben unberuehrt ═════════════════════

do
  assert_eq(rt2_turbine.compute_flow_decision({ rpm = nil, target_rpm = 900 }).flow, 0)
  assert_eq(rt2_turbine.compute_flow_decision({ rpm = 500, target_rpm = 0 }).flow, 0)
  assert_eq(rt2_turbine.compute_flow_decision({ rpm = 2000, target_rpm = 900 }).flow, 0)
end

print('rt2_unreadable_flow_commands_zero_test.lua: ok')
