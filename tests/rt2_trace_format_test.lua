package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Das Format der Regler-Aufzeichnung. Es muss zwei Dinge leisten, an denen
-- alle bisherigen Logzeilen gescheitert sind:
--
-- 1. LEER heisst unbekannt, 0 heisst null. Genau diese Verwechslung hat
--    diese Anlage einen Tag gekostet: der Adapter lieferte fuer einen
--    fehlgeschlagenen Peripherieaufruf eine erfundene 0, der Regler hielt
--    seine Vorgabe fuer erledigt und schrieb nie.
-- 2. Sie muss die INTERESSANTEN Takte zeigen, nicht alle. Bei 50 Turbinen
--    und 10 Hz waeren es 500 Zeilen je Sekunde.

local rt2_trace = require('nodes.rt.rt2_trace')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local function split(row)
  local out = {}
  for field in (row .. ','):gmatch('([^,]*),') do out[#out + 1] = field end
  return out
end

-- Spaltennamen aus M.HEADER ableiten, statt Indizes von Hand zu zaehlen.
-- Die Indizes haben sich beim Erweitern des Formats schon zweimal
-- verschoben, und jedes Mal war es ein Test, der auf die falsche Spalte
-- zeigte -- nicht der Code. Nebenbei prueft das mit, dass der Kopf zur
-- Wirklichkeit passt: steht eine Spalte nicht im Kopf, schlaegt der
-- Zugriff hier fehl.
local COLUMNS = {}
do
  for line in rt2_trace.HEADER:gmatch('[^\n]+') do
    local kind, rest = line:match('^#%s*([TRUMD]),ms,(.*)$')
    if kind then
      local names = { 'kind', 'ms' }
      -- Der Kopf darf umgebrochen sein; Leerzeichen und Kommentar-Rauten
      -- fliegen raus.
      for name in rest:gsub('%s', ''):gmatch('([^,]+)') do
        names[#names + 1] = name
      end
      local map = {}
      for index, name in ipairs(names) do map[name] = index end
      COLUMNS[kind] = map
    end
  end
end

local function field(fields, kind, name)
  local map = COLUMNS[kind] or error('unbekannte Zeilenart ' .. tostring(kind), 2)
  local index = map[name] or error(
    ('Spalte %s gibt es in %s-Zeilen nicht -- steht sie im HEADER?'):format(name, kind), 2)
  return fields[index]
end

local function rows_of_kind(rows, kind)
  local out = {}
  for _, row in ipairs(rows) do
    if row:sub(1, #kind + 1) == kind .. ',' then out[#out + 1] = split(row) end
  end
  return out
end

-- pairs() ueberspringt nil, ein `rpm = nil` im Override waere also
-- wirkungslos -- genau die Falle, die den ersten Anlauf dieses Tests
-- gruen gemacht hat, obwohl er nichts pruefte.
local NIL = setmetatable({}, { __tostring = function() return 'NIL' end })

local function turbine(over)
  local t = {
    name = 'Turbine_1', rpm = 880, flow_is = 600, flow_act = 590, target_rpm = 900,
    flow_cmd = 640, reason = 'TRIM_UP', unchanged = false,
    coil_is = true, coil_cmd = true, model = false,
    write_ok = true, write_err = nil, coil_ok = true,
  }
  for k, v in pairs(over or {}) do
    -- Bewusst ein if: `(v ~= NIL) and v or nil` macht aus einem
    -- uebergebenen `false` ein nil (false or nil -> nil). Genau das hat
    -- hier zuerst einen Testfall entwertet, der write_ok = false setzen
    -- wollte.
    if v == NIL then t[k] = nil else t[k] = v end
  end
  return t
end

-- ── 1. Unbekannt bleibt unbekannt ────────────────────────────────────────

do
  local memory = {}
  local rows = rt2_trace.format_rows({
    ms = 1000, tick = 10, state = 'LEARNING',
    turbines = { turbine({ rpm = NIL, flow_is = NIL, flow_act = NIL }) },
  }, { full_sweep = true }, memory)

  local u = rows_of_kind(rows, 'U')[1]
  assert_true(u ~= nil, 'keine Turbinenzeile')
  assert_eq(field(u, 'U', 'rpm'), '', 'eine nicht lesbare Drehzahl muss LEER sein, nicht 0')
  assert_eq(field(u, 'U', 'flow_is'), '', 'eine nicht lesbare Obergrenze muss LEER sein, nicht 0')

  -- Und eine echte 0 muss als 0 erkennbar bleiben.
  local rows0 = rt2_trace.format_rows({
    ms = 2000, turbines = { turbine({ rpm = 0, flow_is = 0, flow_act = 0 }) },
  }, { full_sweep = true }, {})
  local u0 = rows_of_kind(rows0, 'U')[1]
  assert_eq(field(u0, 'U', 'rpm'), '0', 'eine gemessene 0 muss als 0 dastehen')
  assert_eq(field(u0, 'U', 'flow_is'), '0', 'ebenso bei der Obergrenze')
  assert_eq(field(u0, 'U', 'flow_act'), '0', 'und beim tatsaechlichen Durchsatz')
end

-- ── 2. Wiederholung wird unterdrueckt, Aenderung nicht ───────────────────

do
  local memory = {}
  local sample = { ms = 1000, turbines = { turbine() } }

  local first = rt2_trace.format_rows(sample, {}, memory)
  assert_eq(#rows_of_kind(first, 'U'), 1, 'die erste Zeile ist immer neu')

  local second = rt2_trace.format_rows(sample, {}, memory)
  assert_eq(#rows_of_kind(second, 'U'), 0,
    'ein unveraenderter Takt darf keine Turbinenzeile erzeugen -- sonst laeuft die Platte voll')

  local changed = { ms = 2000, turbines = { turbine({ reason = 'SETTLED' }) } }
  assert_eq(#rows_of_kind(rt2_trace.format_rows(changed, {}, memory), 'U'), 1,
    'ein geaenderter Grund MUSS eine Zeile erzeugen')
end

-- ── 3. Ein Befund wird immer geschrieben, auch unveraendert ──────────────
--
-- Gerade das Verharren ist die Meldung: eine Turbine, die dauerhaft auf 0
-- steht, obwohl ein Ziel vorgegeben ist, ist genau das gemeldete Bild.

do
  local memory = {}
  local silent = { ms = 1000, turbines = { turbine({ flow_cmd = 0, target_rpm = 900 }) } }
  rt2_trace.format_rows(silent, {}, memory)
  assert_eq(#rows_of_kind(rt2_trace.format_rows(silent, {}, memory), 'U'), 1,
    'Durchfluss 0 bei vorgegebenem Ziel muss in JEDEM Takt dastehen')

  local memory2 = {}
  local broken = { ms = 1000, turbines = { turbine({ write_ok = false, write_err = 'NO_FLOW_API' }) } }
  rt2_trace.format_rows(broken, {}, memory2)
  local again = rows_of_kind(rt2_trace.format_rows(broken, {}, memory2), 'U')
  assert_eq(#again, 1, 'ein fehlgeschlagenes Schreiben muss in JEDEM Takt dastehen')
  assert_eq(field(again[1], 'U', 'write_ok'), '0', 'write_ok=false muss als 0 dastehen')
  assert_eq(field(again[1], 'U', 'write_err'), 'NO_FLOW_API', 'und der Fehlertext mit')
end

-- ── 4. Die Sammelzeile zaehlt, was zaehlt ────────────────────────────────

do
  local turbines = {}
  for i = 1, 50 do
    turbines[i] = turbine({
      name = 'Turbine_' .. i,
      flow_cmd = (i <= 49) and 0 or 640,   -- 49 stehen
      unchanged = (i <= 49),
      model = (i % 2 == 0),
    })
  end
  local rows = rt2_trace.format_rows({
    ms = 5000, tick = 77, state = 'AUTONOM', master_pct = 60, max_active = 40,
    capacity = { ready = true, max_output = 1300000, sustainable_turbines = 40, at_target = 50 },
    turbines = turbines,
    dropped = { 'Turbine_3' },
  }, { max_turbine_rows = 12 }, {})

  local t = rows_of_kind(rows, 'T')[1]
  assert_true(t ~= nil, 'keine Sammelzeile')
  assert_eq(field(t, 'T', 'state'), 'AUTONOM', 'Zustand')
  assert_eq(field(t, 'T', 'n_turb'), '50', 'Turbinenzahl')
  assert_eq(field(t, 'T', 'n_flow0'), '49', 'davon mit Durchfluss 0 -- die Zahl, um die es geht')
  assert_eq(field(t, 'T', 'n_unchanged'), '49', 'davon ungeschrieben (unchanged)')
  assert_eq(field(t, 'T', 'n_model'), '25', 'davon modellgefuehrt')
  assert_eq(field(t, 'T', 'n_dropped'), '1', 'verworfene Kennlinien')

  -- Die Sturmbremse greift, und sie sagt es.
  assert_eq(#rows_of_kind(rows, 'U'), 12, 'die Obergrenze je Takt muss halten')
  assert_eq(field(t, 'T', 'n_suppressed'), '38', 'und die unterdrueckten Zeilen muessen gezaehlt werden')

  -- Ein VOLLER Durchgang wird dagegen nicht gekappt: ihn zu kuerzen hiesse,
  -- ihn nicht zu machen -- die abgeschnittenen Turbinen waeren genau die,
  -- ueber die man dann nichts weiss.
  local sweep = rt2_trace.format_rows({
    ms = 6000, turbines = turbines,
  }, { full_sweep = true, max_turbine_rows = 12 }, {})
  assert_eq(#rows_of_kind(sweep, 'U'), 50, 'ein voller Durchgang muss vollstaendig sein')
  assert_eq(field(rows_of_kind(sweep, 'T')[1], 'T', 'n_suppressed'), '0',
    'und dabei nichts als unterdrueckt melden')

  assert_eq(#rows_of_kind(rows, 'D'), 1, 'eine verworfene Kennlinie bekommt ihre eigene Zeile')
end

-- ── 5. Reaktorzeile ──────────────────────────────────────────────────────

do
  local rows = rt2_trace.format_rows({
    ms = 9000,
    reactors = { {
      name = 'Reactor_7', fill = 0.66, rods_is = 85, rods_cmd = 86,
      reason = 'TANK_LOW_WITHDRAW', temp = 1190, coolant = 1.0,
      tripped = false, write_ok = true,
    } },
  }, {}, {})
  local r = rows_of_kind(rows, 'R')[1]
  assert_true(r ~= nil, 'keine Reaktorzeile')
  assert_eq(field(r, 'R', 'name'), 'Reactor_7')
  assert_eq(field(r, 'R', 'fill'), '0.660', 'Fuellstand')
  assert_eq(field(r, 'R', 'rods_is'), '85', 'Ist-Stellung')
  assert_eq(field(r, 'R', 'rods_cmd'), '86', 'Soll-Stellung')
  assert_eq(field(r, 'R', 'reason'), 'TANK_LOW_WITHDRAW', 'Grund')
  assert_eq(field(r, 'R', 'tripped'), '0', 'nicht ausgeloest')
end

-- ── 6. Kommas in einem Grund zerreissen die Spalten nicht ────────────────

do
  local rows = rt2_trace.format_rows({
    ms = 1, turbines = { turbine({ write_err = 'bad argument #1, string expected' }) },
  }, { full_sweep = true }, {})
  local u = rows_of_kind(rows, 'U')[1]
  local expected_cols = 0
  for _ in pairs(COLUMNS.U) do expected_cols = expected_cols + 1 end
  assert_eq(#u, expected_cols, 'die Spaltenzahl muss stimmen, auch mit Komma im Fehlertext')
  local err_text = field(u, 'U', 'write_err')
  assert_true(err_text:find('bad argument #1', 1, true) ~= nil
    and err_text:find('string expected', 1, true) ~= nil,
    'der Text bleibt lesbar: ' .. tostring(err_text))
  assert_true(err_text:find(',', 1, true) == nil,
    'aber ohne Komma, sonst rutschen die Spalten')
end

-- ── 7. Obergrenze und tatsaechlicher Durchsatz sind ZWEI Spalten ─────────
--
-- Der Grund, warum die erste Feldaufzeichnung nicht auswertbar war: die
-- Spalte hiess "Durchfluss", enthielt aber die per setFluidFlowRateMax
-- gesetzte OBERGRENZE -- also den Stellwert, den der Regler selbst
-- geschrieben hatte, nicht den Messwert. Eine Vorgabe stieg dort um das
-- 13-fache, waehrend die Drehzahl fiel, und es war nicht entscheidbar, ob
-- ueberhaupt mehr Dampf floss.

do
  local rows = rt2_trace.format_rows({
    ms = 1000,
    turbines = { turbine({ flow_is = 1564, flow_act = 31 }) },
  }, { full_sweep = true }, {})
  local u = rows_of_kind(rows, 'U')[1]
  assert_eq(field(u, 'U', 'flow_is'), '1564', 'flow_is ist die Obergrenze')
  assert_eq(field(u, 'U', 'flow_act'), '31', 'flow_act ist der tatsaechliche Durchsatz -- sie muessen getrennt sein')
end

-- ── 8. Der volle Durchgang nennt die gebundenen Methoden ─────────────────
--
-- Ohne sie ist aus der Datei nicht erkennbar, WAS gelesen und WAS
-- geschrieben wurde.

do
  local rows = rt2_trace.format_rows({
    ms = 7000,
    turbines = { turbine({
      flow_method = 'getFluidFlowRateMax',
      flow_actual_method = 'getFluidFlowRate',
      set_flow_method = 'setFluidFlowRateMax',
    }) },
  }, { full_sweep = true, methods = true }, {})
  local m = rows_of_kind(rows, 'M')[1]
  assert_true(m ~= nil, 'der volle Durchgang muss die Methoden nennen')
  assert_eq(field(m, 'M', 'flow_method'), 'getFluidFlowRateMax', 'Lesemethode')
  assert_eq(field(m, 'M', 'flow_actual_method'), 'getFluidFlowRate', 'Messmethode')
  assert_eq(field(m, 'M', 'set_flow_method'), 'setFluidFlowRateMax', 'Schreibmethode')

  -- Nur wenn ausdruecklich angefordert: die Methoden aendern sich im
  -- Betrieb nicht, sie brauchen keinen 5s-Takt.
  assert_eq(#rows_of_kind(rt2_trace.format_rows({
    ms = 8000, turbines = { turbine({ flow_method = 'getFluidFlowRateMax' }) },
  }, { full_sweep = true }, {}), 'M'), 0,
    'Methodenzeilen gehoeren nur in den Methoden-Takt, nicht in jeden Durchgang')
end

print('rt2_trace_format_test.lua: ok')
