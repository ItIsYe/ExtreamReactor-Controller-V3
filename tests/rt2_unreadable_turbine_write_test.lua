package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Livetest node-101: 25 Turbinen bei 967-1256 RPM, Durchfluss durchgehend
-- am Maximum (2000), Spule bei allen geloest, keinerlei Reaktion. Die
-- Oberflaeche sah dabei voellig normal aus.
--
-- Ursache, nachgemessen: adapters/turbine.lua's read_number() liefert bei
-- einem fehlgeschlagenen Peripherieaufruf den String "n/a".
-- rt2_adapter.read_turbine() machte daraus eine 0 -- "unbekannt" wurde zu
-- "steht auf 0". Der Regler entschied bei fehlender Drehzahl korrekt auf
-- Durchfluss 0, der Orchestrator verglich das gegen diese erfundene 0,
-- hielt die Vorgabe fuer bereits gesetzt und uebersprang das Schreiben.
-- Im Mod standen weiter 2000 an, die Rotoren liefen lastfrei hoch, und
-- nichts korrigierte das je wieder.
--
-- Die Oberflaeche blieb plausibel, weil monitor_ui.build_turbine_status()
-- einen ZWEITEN Leseweg hat (peripheral.wrap + zwischengespeicherte
-- Faehigkeiten), den adapters/turbine.inspect() nicht benutzt.
--
-- Diese Datei haelt die ganze Kette fest: Adapter -> Orchestrator ->
-- was tatsaechlich an der Hardware ankommt.

local adapter = require('nodes.rt.rt2_adapter')
local orch    = require('nodes.rt.rt2_orchestrator')
local turb    = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- Ein Takt durch die echte Kette; zurueck kommt, was geschrieben wurde.
local function tick_once(rpm_raw, flow_raw, opts)
  opts = opts or {}
  local engine = orch.new({ reactors = { { name = 'R1' } } })
  -- Genau die Form, die adapters/turbine.inspect() bei (teilweise)
  -- fehlgeschlagenen Aufrufen zurueckgibt.
  local reading = adapter.read_turbine('T1', {
    name = 'T1', rpm = rpm_raw, flow = flow_raw, energy = opts.energy or 'n/a',
    coil_engaged = opts.coil == true, active = true,
  })
  local result = engine.tick({
    now_ms = 1758000000000, hardware_ready = true,
    turbines = { reading },
    reactors = { { name = 'R1', safety_tripped = false,
      reactor = { fill_ratio = 0.5, current_rods = 85, active = true } } },
  })
  local flow_written, coil_written
  adapter.apply_turbine({
    set_flow   = function(_, v) flow_written = v end,
    set_coils  = function(_, v) coil_written = v end,
    set_active = function() end,
  }, 'T1', 'RT', result.turbines[1])
  return flow_written, coil_written, result.turbines[1].flow_decision.reason, reading
end

-- ══ 1. Unbekannt bleibt unbekannt ════════════════════════════════════════

do
  local reading = adapter.read_turbine('T1', {
    name = 'T1', rpm = 'n/a', flow = 'n/a', energy = 'n/a', coil_engaged = false, active = true })
  assert_eq(reading.rpm, nil, 'eine unlesbare Drehzahl ist nil')
  assert_eq(reading.current_flow, nil,
    'und ein unlesbarer Durchfluss ebenfalls -- keine erfundene 0, sonst haelt'
      .. ' der Dirty-Check ihn fuer einen echten Rueckmesswert')
end

-- ══ 2. Ein unlesbarer Wert darf das Schreiben nie unterdruecken ══════════
--
-- Die Matrix aus dem Befund. Entscheidend sind die beiden unteren Zeilen:
-- dort wurde vorher NICHTS geschrieben.

do
  local cases = {
    { 'alles lesbar',        1256,  2000 },
    { 'Drehzahl unlesbar',  'n/a',  2000 },
    { 'Durchfluss unlesbar', 1256, 'n/a' },
    { 'beides unlesbar',    'n/a', 'n/a' },
  }
  for _, c in ipairs(cases) do
    local flow, coil = tick_once(c[2], c[3])
    assert_true(flow ~= nil, c[1] .. ': der Durchfluss MUSS geschrieben werden')
    assert_true(coil ~= nil, c[1] .. ': die Spule MUSS geschrieben werden')
  end
end

-- ══ 3. Und zwar in die sichere Richtung ══════════════════════════════════

do
  -- Ohne Drehzahl weiss niemand, wie schnell der Rotor laeuft -> kein Dampf.
  local flow, coil, reason = tick_once('n/a', 'n/a')
  assert_eq(flow, 0, 'ohne Drehzahlmessung muss der Dampf auf null')
  assert_eq(reason, 'NO_RPM_READING')
  assert_eq(coil, false, 'und die Spule bleibt, wie sie war (hier: geloest)')

  -- Ueberdrehzahl: sofort zu, egal was der Rueckmesswert behauptet.
  local over = turb.compute_flow_decision({
    rpm = turb.OVERSPEED_RPM + 100, target_rpm = 900, current_flow = 0,
    now_ms = 1758000000000, last_change_ms = 1758000000000 })
  assert_eq(over.flow, 0)
  assert_eq(over.reason, 'OVERSPEED',
    'die Ueberdrehzahl-Abschaltung darf nicht am Stellintervall haengenbleiben')
end

-- ══ 4. Schutzentscheidungen gehen IMMER raus ═════════════════════════════
--
-- Auch dann, wenn der Rueckmesswert sagt, es staende schon so an. Eine
-- Bremsung darf nicht an einer Ersparnis scheitern -- und der
-- Rueckmesswert kann alt, geraten oder schlicht falsch sein.

do
  -- Turbine steht real auf 0 und soll auf 0: ohne Drehzahl trotzdem schreiben.
  local flow = tick_once('n/a', 0)
  assert_eq(flow, 0, 'NO_RPM_READING muss geschrieben werden, auch wenn 0 schon ansteht')

  -- Abgewaehlter Slot (Ziel 0) -- hier ueber die reine Entscheidung geprueft,
  -- weil der Zustand des Knotens sonst das Ziel bestimmt.
  local parked = turb.compute_flow_decision({
    rpm = 1256, target_rpm = 0, current_flow = 0,
    now_ms = 1758000000000, last_change_ms = 1758000000000 })
  assert_eq(parked.reason, 'TARGET_ZERO')
end

-- ══ 5. Die Ersparnis bleibt, wo sie hingehoert ═══════════════════════════
--
-- Bei einer gesunden, eingeschwungenen Turbine soll weiterhin nicht jeder
-- Takt geschrieben werden -- das war der Zweck der Sache.

do
  local engine = orch.new({ reactors = { { name = 'R1' } } })
  local now, writes = 1758000000000, 0
  for _ = 1, 100 do
    local reading = adapter.read_turbine('T1', {
      name = 'T1', rpm = 900, flow = 1500, energy = 5000, coil_engaged = true, active = true })
    local result = engine.tick({
      now_ms = now, hardware_ready = true, turbines = { reading },
      reactors = { { name = 'R1', safety_tripped = false,
        reactor = { fill_ratio = 0.5, current_rods = 85, active = true } } } })
    adapter.apply_turbine({
      set_flow = function() writes = writes + 1 end,
      set_coils = function() end, set_active = function() end,
    }, 'T1', 'RT', result.turbines[1])
    now = now + 500
  end
  assert_eq(writes, 0,
    'eine Turbine, die genau auf ihrem Ziel steht, wird nicht jeden Takt neu beschrieben')
end

print('rt2_unreadable_turbine_write_test.lua: ok')
