package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_capacity = require('nodes.rt.rt2_capacity')
local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local function turbine(rpm, energy, coil_engaged, flow)
  return { rpm = rpm, energy = energy, coil_engaged = coil_engaged ~= false, current_flow = flow or 0 }
end

-- Eine Anlage, die `carries` von `total` Turbinen auf Zieldrehzahl haelt.
-- Alles darueber haengt bei vollem Flow darunter fest -- der Zustand, den
-- eine dampfbegrenzte Anlage tatsaechlich zeigt.
local function plant(total, carries, each)
  local f = {}
  for i = 1, total do
    if i <= carries then f[i] = turbine(900, each or 100, true, 1200)
    else f[i] = turbine(780, 0, false, rt2_turbine.MAX_FLOW) end
  end
  return f
end

-- Treibt den Suchlauf so lange, bis er fertig ist (oder die Geduld endet).
local function run_search(fleet, max_ticks)
  local state, now = rt2_capacity.new_state(), 1000
  for _ = 1, (max_ticks or 60) do
    state = rt2_capacity.update(state, fleet, { now_ms = now })
    if state.ready then return state, now end
    now = now + rt2_capacity.SETTLE_MS
  end
  return state, now
end

-- ── Der Suchlauf findet, was die Anlage wirklich traegt ──────────────────

do
  -- Alle fuenf tragbar -> der Suchlauf laeuft bis ans Ende durch.
  local s = run_search(plant(5, 5, 100))
  assert_true(s.ready, 'eine Anlage, die ihre ganze Flotte traegt, lernt fertig ein')
  assert_eq(s.reason, 'ALL_SUSTAINED')
  assert_eq(s.sustainable_turbines, 5)
  -- GEMESSEN, nicht hochgerechnet: 5 x 100 minus 5 % Reserve.
  assert_eq(s.max_output, 500 * (1 - rt2_capacity.SAFETY_MARGIN))
end

do
  -- Nur drei von fuenf tragbar. Frueher war das der Totalausfall: die
  -- 80-%-Schwelle (4 von 5) wurde nie erreicht, der Knoten lernte nie
  -- fertig. Jetzt IST "drei" das Ergebnis.
  local fleet = plant(5, 3, 100)
  local state, now = rt2_capacity.new_state(), 1000
  for _ = 1, 40 do
    state = rt2_capacity.update(state, fleet, { now_ms = now })
    if state.ready then break end
    -- gross genug, dass die nicht tragbare Stufe auch wirklich auflaeuft
    now = now + rt2_capacity.STEP_TIMEOUT_MS
  end
  assert_true(state.ready, 'eine dampfbegrenzte Anlage lernt trotzdem fertig ein')
  assert_eq(state.reason, 'LIMIT_FOUND')
  assert_eq(state.sustainable_turbines, 3, 'und kennt ihre tatsaechliche Grenze')
  -- Entscheidend: 3 x 100, NICHT (300/3) * 5 = 500 wie die alte Formel.
  assert_eq(state.max_output, 300 * (1 - rt2_capacity.SAFETY_MARGIN),
    'die Kapazitaet ist die gemessene Summe, keine Hochrechnung auf die Flotte')
end

do
  -- Nicht einmal eine einzige Turbine laesst sich halten. Daraus laesst
  -- sich nichts lernen, also wird auch nichts gelernt -- und das muss
  -- benannt werden, statt still zu haengen.
  local fleet = plant(5, 0)
  local state, now = rt2_capacity.new_state(), 1000
  for _ = 1, 10 do
    state = rt2_capacity.update(state, fleet, { now_ms = now })
    now = now + rt2_capacity.STEP_TIMEOUT_MS
  end
  assert_true(not state.ready, 'ohne eine einzige tragbare Turbine gibt es nichts zu lernen')
  assert_eq(state.reason, 'NO_STEAM')
  assert_eq(state.sustainable_turbines, 0)
end

-- ── Eine Stufe muss sich HALTEN, nicht nur kurz streifen ─────────────────

do
  local fleet = plant(3, 3, 100)
  local s = rt2_capacity.update(rt2_capacity.new_state(), fleet, { now_ms = 1000 })
  assert_eq(s.reason, 'TOPOLOGY_CHANGED', 'der erste Takt nimmt die Flottengroesse auf')
  s = rt2_capacity.update(s, fleet, { now_ms = 2000 })
  assert_eq(s.reason, 'SETTLING', 'die Stufe traegt -- aber erst seit einem Augenblick')
  assert_eq(s.sustainable_turbines, 0, 'ein Augenblick zaehlt nicht')

  -- Kurz aus dem Fenster gefallen -> die Einschwingzeit beginnt von vorn.
  s = rt2_capacity.update(s, plant(3, 0), { now_ms = 2000 + rt2_capacity.SETTLE_MS - 1 })
  assert_eq(s.sustainable_turbines, 0, 'eine unterbrochene Stufe zaehlt nicht')
  s = rt2_capacity.update(s, fleet, { now_ms = 2000 + rt2_capacity.SETTLE_MS })
  assert_eq(s.reason, 'SETTLING', 'nach der Unterbrechung laeuft die Einschwingzeit neu')
end

-- ── Was den gelernten Wert verwirft, und was nicht ───────────────────────

do
  local s = run_search(plant(2, 2, 100))
  assert_true(s.ready)
  local learned_max = s.max_output

  -- Umbau: andere Turbinenzahl -> der Suchlauf beginnt von vorn.
  local changed = rt2_capacity.update(s, plant(3, 3, 100), { now_ms = 99000 })
  assert_true(not changed.ready, 'eine geaenderte Turbinenzahl verwirft den Wert')
  assert_eq(changed.reason, 'TOPOLOGY_CHANGED')
  assert_eq(changed.released, rt2_capacity.START_COUNT, 'und der Suchlauf beginnt wieder unten')
  assert_eq(changed.max_output, 0, 'der alte Wert darf nicht stehenbleiben')

  -- Ein Takt ganz ohne Turbinen-Lesung ist KEIN Umbau, sondern eine
  -- fehlende Messung (Discovery-Aussetzer). Der wuerde sonst einen
  -- minutenlangen Suchlauf umsonst ausloesen.
  local blind = rt2_capacity.update(s, {}, { now_ms = 99000 })
  assert_true(blind.ready, 'ein Takt ohne Lesung darf die gelernte Anlage nicht wegwerfen')
  assert_eq(blind.max_output, learned_max)
  assert_eq(blind.reason, 'NO_TURBINES')

  -- Der Ausgangszustand selbst bleibt unangetastet (copy-on-write).
  assert_eq(s.max_output, learned_max, 'update() darf den uebergebenen Zustand nicht veraendern')
  assert_true(s.ready)
end

-- ── Saettigung sichtbar machen ───────────────────────────────────────────

do
  -- Volle Foerderung, trotzdem zu langsam: keine Reglerreserve mehr da.
  local s = rt2_capacity.update(rt2_capacity.new_state(), plant(5, 0), { now_ms = 1000 })
  s = rt2_capacity.update(s, plant(5, 0), { now_ms = 2000 })
  assert_eq(s.reason, 'FLOW_SATURATED', 'Saettigung muss benannt werden')
  assert_true(s.saturated > 0)

  -- Dieselbe Drehzahl, aber der Flow hat noch Luft: echtes Hochrampen.
  local ramping = { turbine(780, 0, false, 400) }
  local r = rt2_capacity.update(rt2_capacity.new_state(), ramping, { now_ms = 1000 })
  r = rt2_capacity.update(r, ramping, { now_ms = 2000 })
  assert_eq(r.reason, 'SPINNING_UP', 'mit Flow-Reserve ist es noch Hochlaufen')
  assert_eq(r.saturated, 0)
end

-- ── Persistenz ───────────────────────────────────────────────────────────

do
  local files = {}
  local write_config = function(path, data) files[path] = data; return true end
  local read_config = function(path) return files[path] end

  local learned = run_search(plant(2, 2, 100))
  assert_true(rt2_capacity.save(learned, { path = '/cache', write_config = write_config }),
    'save must succeed once ready')

  -- Neustart mit gleicher Anzahl: der Cache gilt. Umbenannte Peripherals
  -- sieht dieses Modul gar nicht -- es kennt nur die Anzahl.
  local back = rt2_capacity.load({ path = '/cache', read_config = read_config, turbine_count = 2 })
  assert_true(back ~= nil, 'a same-count reload must accept the cached value')
  assert_eq(back.max_output, learned.max_output)
  assert_eq(back.sustainable_turbines, learned.sustainable_turbines,
    'ohne die tragbare Anzahl waere der ganze Suchlauf beim Neustart umsonst')
  assert_eq(back.released, back.sustainable_turbines)

  -- Echter Umbau -> Cache verwerfen.
  assert_true(rt2_capacity.load({ path = '/cache', read_config = read_config, turbine_count = 3 }) == nil,
    'a turbine count mismatch must reject the cached value')

  -- Ein Cache aus der Zeit VOR dem Suchlauf enthaelt nur eine
  -- hochgerechnete Kapazitaet und keine tragbare Anzahl. Der Wert ist auf
  -- einer dampfbegrenzten Anlage um ein Vielfaches zu hoch, also wird er
  -- verworfen statt uebernommen.
  files['/alt'] = { ready = true, max_output = 25000, turbine_count = 25 }
  local old, why = rt2_capacity.load({ path = '/alt', read_config = read_config, turbine_count = 25 })
  assert_true(old == nil, 'ein alter Cache ohne gemessene Turbinenzahl darf nicht uebernommen werden')
  assert_true(tostring(why):find('alter Cache'), 'und der Grund muss genannt werden: ' .. tostring(why))
end

print('rt2_capacity_test.lua: ok')
