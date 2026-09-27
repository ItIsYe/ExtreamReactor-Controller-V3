package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreibervorgabe, und sie ist die richtige Lehre aus diesem Tag:
--
--   "Diese Kennlinie kann eine ganze Flotte lahmlegen -- das muss
--    abgesichert werden."
--
-- rt2_turbine_model prueft die ZAHLEN einer Kennlinie beim Ableiten und
-- beim Laden (Steigung, Achsenabschnitt). Das faengt den groben Unsinn,
-- aber nicht den stillen Fall: eine Kennlinie mit unauffaelligen Werten,
-- die trotzdem zu wenig Durchfluss vorgibt. Die Turbine haengt dann
-- dauerhaft unter ihrem Ziel, ohne dass eine einzelne Zahl falsch
-- aussieht.
--
-- Und das trifft eine Flotte GEMEINSAM, denn ihre Kennlinien entstehen
-- im selben Zustand und liegen in derselben Datei. Geprueft wird deshalb
-- zusaetzlich die WIRKUNG.

local orchestrator = require('nodes.rt.rt2_orchestrator')
local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- Eine Kennlinie, deren Zahlen alle Pruefungen bestehen, die aber viel zu
-- wenig Durchfluss vorgibt: 300 mB/t fuer 900 RPM, wo die Turbine in
-- Wahrheit 1200 braucht.
local function weak_model()
  return { slope = 3.0, intercept = 0, min_adjust_interval_ms = 400 }
end

local function fleet(n, rpm, flow)
  local f = {}
  for i = 1, n do
    f[i] = { name = 'T' .. i, rpm = rpm, current_flow = flow,
             coil_engaged = true, energy = 10, active = true }
  end
  return f
end

-- Verworfen wird im Takt des Ereignisses; die Liste ist je Takt neu.
-- Deshalb ueber ALLE Takte sammeln, nicht nur den letzten ansehen.
local function run(o, ticks, step_ms, rpm, flow)
  local result, dropped = nil, {}
  for tick = 1, ticks do
    result = o.tick({
      now_ms = tick * step_ms,
      hardware_ready = true,
      reactors = { { name = 'R1', reactor = { fill_ratio = 0.7, current_rods = 85, active = true } } },
      turbines = fleet(20, rpm, flow or 300),
    })
    for _, name in ipairs(result.dropped_turbine_models or {}) do
      dropped[#dropped + 1] = name
    end
  end
  return result, dropped
end

-- ══ 1. Eine widerlegte Kennlinie wird verworfen ════════════════════════

do
  local models = {}
  for i = 1, 20 do models['T' .. i] = weak_model() end
  local o = orchestrator.new({ reactor_name = 'R1', turbine_models = models })

  -- Die Turbinen bleiben dauerhaft weit unter ihrem Ziel (450 statt 900)
  -- und fahren dabei NICHT am Anschlag -- es liegt also nicht am Dampf.
  local _, dropped = run(o, 12, math.floor(orchestrator.MODEL_DISTRUST_MS / 4), 450)

  assert_true(#dropped > 0,
    'eine Kennlinie, die ihre Turbine nachweislich nicht ans Ziel bringt,'
      .. ' muss verworfen werden -- sonst legt sie die Flotte dauerhaft lahm')

  -- Und danach faehrt die Turbine wieder auf der Rampe, nicht auf dem Modell.
  local after = run(o, 2, 1000, 450)
  after = after or {}
  local model_driven = 0
  for _, t in ipairs(after.turbines) do
    local reason = t.flow_decision and t.flow_decision.reason or ''
    if reason:sub(1, 5) == 'MODEL' then model_driven = model_driven + 1 end
  end
  assert_eq(model_driven, 0, 'nach dem Verwerfen fuehrt kein Modell mehr')
end

-- ══ 2. Bei DAMPFMANGEL wird die Kennlinie NICHT verworfen ══════════════
--
-- Faehrt die Turbine bereits volle Foerderung und ist trotzdem zu
-- langsam, fehlt Dampf -- und die Kennlinie kann nichts dafuer. Ohne
-- diese Unterscheidung wuerfe eine dampfarme Anlage ihre gueltigen
-- Kennlinien weg und muesste ewig neu lernen.

do
  local models = {}
  for i = 1, 20 do models['T' .. i] = { slope = 0.75, intercept = 0, min_adjust_interval_ms = 400 } end
  local o = orchestrator.new({ reactor_name = 'R1', turbine_models = models })

  local _, dropped = run(o, 12, math.floor(orchestrator.MODEL_DISTRUST_MS / 4), 450,
    rt2_turbine.MAX_FLOW)
  assert_eq(#dropped, 0,
    'bei vollem Durchfluss ist die Drehzahl eine Dampffrage, keine Kennlinienfrage')
end

-- ══ 3. Eine Turbine AM ZIEL behaelt ihre Kennlinie ═════════════════════

do
  local models = {}
  for i = 1, 20 do models['T' .. i] = { slope = 0.75, intercept = 0, min_adjust_interval_ms = 400 } end
  local o = orchestrator.new({ reactor_name = 'R1', turbine_models = models })
  local _, dropped = run(o, 12, math.floor(orchestrator.MODEL_DISTRUST_MS / 4), 900)
  assert_eq(#dropped, 0,
    'wer sein Ziel haelt, hat eine gute Kennlinie')
end

print('rt2_model_cannot_paralyse_fleet_test.lua: ok')
