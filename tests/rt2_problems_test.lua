package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreiber (2026-10-16): "Drehzahlmeldung raus. Das ist ja ein RT-Problem,
-- dann muss angezeigt werden, dass die RT ein Problem hat, dass man dann auf
-- dem RT-Monitor weiterschauen muss."
--
-- MASTER meldete bis v832 jede Turbine unter 800 U/min und jede gekuppelte
-- Spule darunter -- auch die, die der Regler absichtlich abstellt und alle
-- 5 Minuten wechselt. Jetzt entscheidet die RT-Node selbst
-- (nodes/rt/rt2_problems.lua), schickt die Zeilen an MASTER und zeigt sie
-- auf ihrem eigenen Schirm.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function read(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local c = f:read('*a'); f:close(); return c
end

local problems = require('nodes.rt.rt2_problems')

-- ══ 1. Leistung zu niedrig: erst nach der Entprellzeit ══════════════════

local function turbines(spec)
  local out = {}
  for i, t in ipairs(spec) do
    out[i] = { name = 'turbine_' .. i, target_rpm = t[1], rpm = t[2], flow_reason = t[3] }
  end
  return out
end

do
  local st = problems.new()
  local base = { state = 'MASTER', learning = false, power_target = 10000, actual_output = 4000,
    turbines = turbines({ { 900, 905 }, { 900, 300 }, { 0, 600 }, { 900, 850 } }) }
  local function at(ms, over)
    local input = {}
    for k, v in pairs(base) do input[k] = v end
    for k, v in pairs(over or {}) do input[k] = v end
    input.now_ms = ms
    return problems.update(st, input)
  end
  assert_eq(#at(0), 0, 'Beginn: noch nichts')
  assert_eq(#at(problems.LOW_OUTPUT_MS - 1), 0, 'vor Ablauf der Entprellzeit nichts')
  local lines = at(problems.LOW_OUTPUT_MS)
  assert_true(lines[1] and lines[1]:find('liefert 40%% vom Soll') ~= nil, 'Leistungszeile: ' .. tostring(lines[1]))
  assert_true(lines[1]:find('4.0k von 10.0k RF/t', 1, true) ~= nil, 'Ist und Soll lesbar: ' .. lines[1])
  assert_eq(#lines, 3, 'dazu die zwei Turbinen, die laufen sollen und unter dem Zielband stehen')
  assert_eq(lines[2], '- turbine_2: 300/900 U/min')
  assert_eq(lines[3], '- turbine_4: 850/900 U/min', '850 liegt 50 unter dem Ziel, also mehr als das Band (40)')
  assert_true(not table.concat(lines, '|'):find('turbine_3'), 'eine abgestellte Turbine (Ziel 0) ist kein Hinweis')
  assert_true(not table.concat(lines, '|'):find('turbine_1'), 'eine Turbine am Ziel ist kein Hinweis')

  -- Kurz genug Leistung (Turbinenwechsel) beendet das Problem nicht ...
  local t0 = problems.LOW_OUTPUT_MS
  assert_eq(#at(t0 + 1000, { actual_output = 9000 }), 3, '90 % fuer eine Sekunde: steht weiter an')
  assert_eq(#at(t0 + 1000 + problems.LOW_OUTPUT_CLEAR_MS - 1, { actual_output = 9000 }), 3,
    'erst nach LOW_OUTPUT_CLEAR_MS am Stueck ist es behoben')
  -- ... und eine Unterbrechung setzt die Rueckfallzeit zurueck.
  local t1 = t0 + 30000
  assert_eq(#at(t1), 3, 'wieder zu wenig')
  assert_eq(#at(t1 + 1, { actual_output = 9000 }), 3, 'reicht wieder -- die Rueckfallzeit beginnt neu')
  assert_eq(#at(t1 + problems.LOW_OUTPUT_CLEAR_MS, { actual_output = 9000 }), 3, 'eine ms vor ihrem Ende')
  assert_eq(#at(t1 + 1 + problems.LOW_OUTPUT_CLEAR_MS, { actual_output = 9000 }), 0, 'jetzt behoben')
  assert_eq(#at(t1 + 2 + problems.LOW_OUTPUT_CLEAR_MS), 0,
    'wieder zu wenig: die Entprellung beginnt von vorn')
end

do
  local st = problems.new()
  local function lines_for(over)
    local input = { state = 'MASTER', learning = false, power_target = 10000, actual_output = 1000, turbines = {} }
    for k, v in pairs(over) do input[k] = v end
    input.now_ms = 0; problems.update(st, input)
    input.now_ms = problems.LOW_OUTPUT_MS; return problems.update(st, input)
  end
  assert_eq(#lines_for({ learning = true }), 0, 'beim Einlernen faehrt die Flotte absichtlich anders')
  st = problems.new(); assert_eq(#lines_for({ state = 'AUTONOM' }), 0, 'ohne MASTER gibt es kein Soll')
  st = problems.new(); assert_eq(#lines_for({ power_target = 0 }), 0, 'Soll 0: nichts zu liefern')
  st = problems.new(); assert_eq(#lines_for({ actual_output = 8500 }), 0, 'genau 85 % ist in Ordnung')
end

-- ══ 2. Je Turbine: Drehzahl nicht lesbar, Ueberdrehzahl ═════════════════

do
  local st = problems.new()
  local function at(ms, spec)
    return problems.update(st, { now_ms = ms, state = 'MASTER', power_target = 0, turbines = turbines(spec) })
  end
  assert_eq(#at(0, { { 900, nil }, { 900, 1400, 'OVERSPEED' } }), 0)
  assert_eq(#at(problems.NO_RPM_MS - 1, { { 900, nil }, { 900, 1400, 'OVERSPEED' } }), 0, 'kurz: nichts')
  local lines = at(problems.NO_RPM_MS, { { 900, nil }, { 900, 1400, 'OVERSPEED' } })
  assert_eq(lines[1], 'Turbine turbine_1: Drehzahl nicht lesbar')
  assert_eq(lines[2], 'Turbine turbine_2: Ueberdrehzahl 1400 U/min')
  assert_eq(#at(problems.NO_RPM_MS + 100, { { 900, 880 }, { 900, 900, 'SETTLED' } }), 0, 'beides vorbei')
  -- Eine Turbine, die verschwindet, nimmt ihren Zeitpunkt mit.
  at(problems.NO_RPM_MS + 200, { { 900, nil } })
  at(problems.NO_RPM_MS + 300, {})
  assert_eq(next(st.since), nil, 'keine Zeitpunkte fuer verschwundene Turbinen')
end

do
  local st = problems.new()
  local spec = {}
  for i = 1, 20 do spec[i] = { 900, nil } end
  problems.update(st, { now_ms = 0, turbines = turbines(spec) })
  local lines = problems.update(st, { now_ms = problems.NO_RPM_MS, turbines = turbines(spec) })
  assert_eq(#lines, problems.MAX_LINES, 'hoechstens MAX_LINES Zeilen gehen an MASTER')
end

-- ══ 3. Zwilling: Normalbetrieb ohne Meldung, echte Fehler mit ═══════════

local harness = require('support.er_rt_harness')
local rt2_orchestrator = require('nodes.rt.rt2_orchestrator')

local function master(h, percent)
  return function(self)
    self.engine.note_master_seen(self.clock_ms)
    self.engine.handle_command({ target = 'SET_SETPOINTS', value = { power_target_percent = percent } })
  end
end

do
  -- 50 % Vorgabe ueber drei Rotationen: die halbe Flotte steht, alle 5
  -- Minuten faehrt eine Turbine an und eine wird abgebremst. Genau das gab
  -- bis v832 jedes Mal Drehzahl- und Spulenwarnungen.
  local h = harness.new({ turbine_count = 6 })
  local seconds = math.ceil(rt2_orchestrator.ROTATE_INTERVAL_MS / 1000 * 3) + 400
  local worst, parked_seen = nil, false
  for _ = 1, seconds * 10 do
    h:step(master(h, 50))
    local p = h.engine.status_fields().problems
    assert_true(type(p) == 'table', 'status_fields().problems ist immer eine Liste')
    if #p > 0 and not worst then worst = table.concat(p, ' | ') end
    for _, tr in ipairs(h.last.turbines or {}) do
      if (tr.target_rpm or 0) <= 0 then parked_seen = true end
    end
  end
  assert_true(parked_seen, 'der Fall prueft nur etwas, wenn Turbinen abgestellt werden')
  assert_true(h.last.capacity.learning ~= true, 'das Einlernen ist durch')
  assert_eq(worst, nil, 'Normalbetrieb mit Abstellen und Rotation meldet kein Problem')

  -- Jetzt bricht der Dampf ein: der Reaktor liefert nur noch ein Fuenftel.
  h.plant.reactor.max_steam_per_tick = math.floor(h.plant.reactor.max_steam_per_tick / 5)
  local first_ms, start_ms, gaps = nil, h.clock_ms, 0
  for _ = 1, 900 * 10 do
    h:step(master(h, 50))
    local n = #h.engine.status_fields().problems
    if not first_ms and n > 0 then first_ms = h.clock_ms end
    if first_ms and n == 0 then gaps = gaps + 1 end
  end
  -- Der Fall, an dem der erste Entwurf scheiterte: beim Turbinenwechsel
  -- liefert die abbremsende Turbine kurz Strom. Das darf das Problem nicht
  -- jedes Mal fuer Minuten verschwinden lassen.
  assert_eq(gaps, 0, 'einmal da, bleibt das Problem stehen, solange der Dampf fehlt')
  local p = h.engine.status_fields().problems
  assert_true(first_ms ~= nil, 'zu wenig Dampf muss als Problem kommen: ' .. h:describe())
  -- Lief beim Einbruch schon eine kurze Delle (Turbinenwechsel, unter
  -- LOW_OUTPUT_CLEAR_MS), zaehlt sie mit -- frueher als das kann es nicht kommen.
  assert_true(first_ms - start_ms >= problems.LOW_OUTPUT_MS - problems.LOW_OUTPUT_CLEAR_MS,
    'erst nach der Entprellzeit, kam aber nach ' .. tostring((first_ms - start_ms) / 1000) .. ' s')
  assert_true(p[1]:find('vom Soll', 1, true) ~= nil, 'Leistungszeile zuerst: ' .. tostring(p[1]))
  assert_true(#p >= 2 and p[2]:find('U/min', 1, true) ~= nil, 'mit den Turbinen unter Ziel als Hinweis')
end

do
  -- Eine Turbine laesst sich nicht mehr lesen (Kabel ab, Chunk).
  local h = harness.new({ turbine_count = 3 })
  h:run(120, master(h, 100))
  assert_eq(#h.engine.status_fields().problems, 0, 'vorher alles gut')
  local real_call = _G.peripheral.call
  _G.peripheral.call = function(name, method, ...)
    if name == 'turbine_2' and method == 'getRotorSpeed' then error('nicht erreichbar', 0) end
    return real_call(name, method, ...)
  end
  h:run(problems.NO_RPM_MS / 1000 + 2, master(h, 100))
  _G.peripheral.call = real_call
  local joined = table.concat(h.engine.status_fields().problems, ' | ')
  assert_true(joined:find('Turbine turbine_2: Drehzahl nicht lesbar', 1, true) ~= nil, joined)
end

-- ══ 4. Verdrahtung: Status an MASTER, eigener Schirm ════════════════════

do
  local main = read('xreactor/nodes/rt/main.lua')
  assert_true(main:find('payload.problems = v2.problems or {}', 1, true) ~= nil, 'die Zeilen gehen an MASTER, immer als Liste')
  assert_true(main:find('monitor_ctx.rt_problems   = v2.problems or {}', 1, true) ~= nil, 'und auf den eigenen Schirm')
  local mh = read('xreactor/master/message_handlers.lua')
  assert_true(mh:find('rt.problems = type(payload.problems) == "table" and payload.problems or {}', 1, true) ~= nil,
    'MASTER uebernimmt sie bei jeder Meldung neu')

  -- Der Statusbanner des RT-Monitors zeigt das Problem zuerst.
  local pages = require('nodes.rt.mockup_pages')
  local texts = {}
  local mon = setmetatable({ getSize = function() return 60, 30 end, isColor = function() return true end },
    { __index = function() return function() end end })
  local mux = require('core.mockup_ui') -- dieselbe Tabelle, die mockup_pages benutzt
  local real_banner = mux.banner
  mux.banner = function(_, _, _, _, text, status) texts[#texts + 1] = { text = text, status = status } end
  local ok, err = pcall(pages.render_overview, mon, {
    node_id = 'RT-1', problems = { 'liefert 40% vom Soll', '- turbine_2: 300/900 U/min' },
    capacity_ready = true, target_power = 1000, snapshot = { snapshot = { actual_output = 1000 } },
  })
  mux.banner = real_banner
  assert_true(ok, 'render_overview: ' .. tostring(err))
  assert_true(texts[1] and texts[1].text == '> PROBLEM: liefert 40% vom Soll (+1)', 'Banner: ' .. tostring(texts[1] and texts[1].text))
  assert_eq(texts[1].status, 'WARNING')
end

print('rt2_problems_test.lua: ok')
