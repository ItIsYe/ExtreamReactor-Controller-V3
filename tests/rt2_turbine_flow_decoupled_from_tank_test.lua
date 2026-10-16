package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die Architekturregel, ausdruecklich vom Betreiber gesetzt:
--
--   "Nur weil der Dampftank vom Reaktor leer ist, darf das nicht die
--    Turbinen-Flusssteuerung beeinflussen. Wenn der Tank leer ist, soll
--    der Reaktor nur nachregeln, nichts anderes."
--
-- Sie steht so schon in rt2_unit.lua und rt2_reactor.lua: der Reaktor
-- regelt AUSSCHLIESSLICH aus seinem eigenen Dampftank, MASTER bewegt nur
-- Turbinen-Vorgaben, und die Rueckkopplung laeuft ueber den DAMPF, nicht
-- ueber Code.
--
-- Gebrochen wurde sie durch das gestaffelte Einlernen (v754-v757, wieder
-- entfernt): "die Turbinen erreichen ihre Zieldrehzahl nicht" ist eine
-- Folge von wenig Dampf, und daraufhin wurde die Turbinen-Freigabe
-- gedrosselt. Damit regelte der Tankstand die Turbinen -- auf einem
-- Umweg, aber er tat es. Das Ergebnis im Betrieb: 50 Turbinen, eine lief.
--
-- Diese Datei haelt fest, dass die Turbinenentscheidungen eines Takts
-- NICHT davon abhaengen, wie voll der Reaktortank ist.

local orchestrator = require('nodes.rt.rt2_orchestrator')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local function fleet(n, rpm, flow)
  local f = {}
  for i = 1, n do
    f[i] = { name = 'T' .. i, rpm = rpm, current_flow = flow,
             coil_engaged = false, energy = 0, active = true }
  end
  return f
end

-- Derselbe Takt, einmal mit leerem und einmal mit vollem Reaktortank.
local function decisions_for(fill, turbine_count)
  local o = orchestrator.new({ reactor_name = 'R1' })
  local out
  -- Ueber mehrere Minuten simulierter Zeit: eine Drosselung, die erst
  -- nach einer Frist zuschlaegt, muss in diesem Fenster auffallen. Mit
  -- ein paar Takten a einer Sekunde waere der Test blind dafuer gewesen
  -- (erste Fassung -- sie lief gegen den fehlerhaften Stand gruen durch).
  for tick = 1, 30 do
    local result = o.tick({
      now_ms = tick * 10000,
      hardware_ready = true,
      reactors = { { name = 'R1', reactor = { fill_ratio = fill, current_rods = 85, active = true } } },
      turbines = fleet(turbine_count, 300, 2000),
    })
    out = result
  end
  return out
end

-- ══ 1. Leerer Tank aendert an den Turbinen NICHTS ══════════════════════

for _, count in ipairs({ 25, 50 }) do
  local empty = decisions_for(0.0, count)
  local full  = decisions_for(1.0, count)

  assert_eq(#empty.turbines, count)
  assert_eq(#full.turbines, count)

  for index = 1, count do
    local a, b = empty.turbines[index], full.turbines[index]
    assert_eq(a.target_rpm, b.target_rpm, string.format(
      'Turbine %d von %d: die Zieldrehzahl darf nicht vom Reaktortank abhaengen', index, count))
    assert_eq(a.flow_decision.flow, b.flow_decision.flow, string.format(
      'Turbine %d von %d: der Durchfluss darf nicht vom Reaktortank abhaengen', index, count))
    assert_eq(a.coil_decision.engaged, b.coil_decision.engaged, string.format(
      'Turbine %d von %d: die Kupplung darf nicht vom Reaktortank abhaengen', index, count))
  end
end

-- ══ 2. Keine Turbine wird wegen Dampfmangels abgestellt ════════════════
--
-- Der Fall aus dem Betrieb: eine dampfarme Anlage, deren Turbinen bei
-- vollem Durchfluss unter der Zieldrehzahl haengen. Genau hier hat die
-- Staffelung zugeschlagen und 49 von 50 auf Ziel 0 gesetzt.

do
  local result = decisions_for(0.0, 50)
  local parked = 0
  for _, t in ipairs(result.turbines) do
    if (t.target_rpm or 0) <= 0 then parked = parked + 1 end
  end
  assert_eq(parked, 0,
    'bei leerem Tank wird KEINE Turbine abgestellt -- das waere der Tankstand,'
      .. ' der die Turbinen regelt (' .. parked .. ' von 50 abgestellt)')
end

-- ══ 3. Der Reaktor dagegen regelt sehr wohl ════════════════════════════
--
-- Die andere Haelfte der Regel: leerer Tank heisst, der Reaktor faehrt
-- die Staebe aus. Genau das und nichts anderes.

do
  local empty = decisions_for(0.0, 50)
  local full  = decisions_for(1.0, 50)
  local rods_empty = empty.reactors[1].rods
  local rods_full  = full.reactors[1].rods
  assert_true(rods_empty < rods_full, string.format(
    'leerer Tank -> Staebe weiter AUSgefahren als bei vollem Tank (leer=%s voll=%s)',
    tostring(rods_empty), tostring(rods_full)))
end

print('rt2_turbine_flow_decoupled_from_tank_test.lua: ok')
