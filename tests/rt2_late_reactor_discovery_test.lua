package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb gemeldet: mit ZWEI Reaktoren wurde nur einer geregelt,
-- der andere nicht -- waehrend die Turbinen sauber liefen.
--
-- Ursache: die Einheitenliste des Orchestrators entstand EINMAL beim
-- Start aus opts.reactors. Die Discovery bindet den zweiten Reaktor aber
-- erst spaeter (sie laeuft nach init() weiter). Jeder Takt brachte dann
-- zwar zwei Messwerte mit, es gab aber nur EINE Einheit:
--
--     for index, unit in ipairs(self.reactors) do ... end
--
-- lief einmal, es entstand eine Entscheidung, und der zweite Reaktor
-- wurde nie angefasst. Die Turbinen waren nicht betroffen -- die baut
-- der Orchestrator je Takt frisch aus input.turbines auf.
--
-- Warum die bestehenden Zwei-Reaktor-Tests das nicht gefunden haben:
-- sie uebergeben beide Reaktoren schon an orchestrator.new(). Genau der
-- Fall, der in der Anlage NICHT eintritt. Diese Datei geht deshalb den
-- Weg der Anlage: erst einer bekannt, dann zwei.

local orch = require('nodes.rt.rt2_orchestrator')
local rt2_reactor = require('nodes.rt.rt2_reactor')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local NOW = 1758000000000

local function reactor(name, fill, tripped)
  return { name = name, safety_tripped = tripped == true,
    reactor = { fill_ratio = fill, current_rods = 85, active = true } }
end

local function tick(engine, reactors, now)
  return engine.tick({
    now_ms = now or NOW, hardware_ready = true,
    turbines = { { name = 'T1', rpm = 900, energy = 5000,
      coil_engaged = true, current_flow = 1500, active = true } },
    reactors = reactors,
  })
end

local function by_name(result)
  local out = {}
  for _, d in ipairs(result.reactors) do
    if d.name then out[d.name] = d end
  end
  return out
end

-- ══ 1. Der gemeldete Fall: spaeter entdeckter zweiter Reaktor ═══════════

do
  local engine = orch.new({ reactors = { { name = 'R1' } } })
  assert_eq(#engine.reactors, 1, 'der Knoten startet mit einem bekannten Reaktor')

  local result = tick(engine, { reactor('R1', 0.9), reactor('R2', 0.9) })
  assert_eq(#result.reactors, 2,
    'sobald die Discovery den zweiten Reaktor meldet, MUSS er eine eigene'
      .. ' Entscheidung bekommen -- sonst bleibt er ungeregelt stehen')

  local d = by_name(result)
  assert_true(d.R1 ~= nil and d.R2 ~= nil, 'und zwar beide namentlich')
  assert_true(d.R2.rods ~= nil, 'der zweite Reaktor braucht eine Stabstellung')
end

-- ══ 2. Jeder regelt aus SEINEM eigenen Tank ═════════════════════════════
--
-- Der Kern der Mehr-Reaktor-Vorgabe: keine Absprache, jeder nach seinem
-- Dampftank. Ein voller Tank fahrt die Staebe ein, ein leerer aus --
-- gleichzeitig, am selben Knoten, in entgegengesetzte Richtung.

do
  local engine = orch.new({ reactors = { { name = 'R1' } } })
  tick(engine, { reactor('R1', 0.5), reactor('R2', 0.5) })

  local now = NOW + 5000
  local result = tick(engine, { reactor('R1', 1.0), reactor('R2', 0.0) }, now)
  local d = by_name(result)
  assert_true(d.R1.rods > d.R2.rods, string.format(
    'der volle Tank muss WEITER einfahren als der leere (R1=%s bei Fuellstand 1.0,'
      .. ' R2=%s bei 0.0) -- sonst regeln sie nicht unabhaengig',
    tostring(d.R1.rods), tostring(d.R2.rods)))
end

-- ══ 3. Die Zuordnung haelt, auch wenn die Reihenfolge kippt ═════════════
--
-- Die Discovery sortiert nicht stabil. Wuerde ueber die Position gepaart,
-- bekaeme ein Reaktor die Staebe des anderen -- schlimmer als gar nicht
-- zu regeln.

do
  local engine = orch.new({ reactors = { { name = 'R1' } } })
  tick(engine, { reactor('R1', 0.5), reactor('R2', 0.5) })

  local now = NOW + 5000
  -- Gleiche Reaktoren, vertauschte Reihenfolge, klar verschiedene Taenke.
  local d = by_name(tick(engine, { reactor('R2', 0.0), reactor('R1', 1.0) }, now))
  assert_true(d.R1.rods > d.R2.rods,
    'nach einem Reihenfolgewechsel muss jeder Reaktor weiter seinen EIGENEN'
      .. ' Tank sehen -- gepaart wird ueber den Namen, nicht ueber die Position')
end

-- ══ 4. Ein ausgeloester Reaktor faehrt allein ein ═══════════════════════

do
  local engine = orch.new({ reactors = { { name = 'R1' } } })
  tick(engine, { reactor('R1', 0.5), reactor('R2', 0.5) })

  local d = by_name(tick(engine, { reactor('R1', 0.5), reactor('R2', 0.5, true) }, NOW + 5000))
  assert_eq(d.R2.rods, rt2_reactor.ROD_MAX, 'der ausgeloeste Reaktor faehrt voll ein')
  assert_true(d.R1.rods < rt2_reactor.ROD_MAX,
    'der andere laeuft weiter -- die Flotte haengt am Dampf beider')
end

-- ══ 5. Ein abgebauter Reaktor bekommt keine Entscheidungen mehr ════════

do
  local engine = orch.new({ reactors = { { name = 'R1' } } })
  tick(engine, { reactor('R1', 0.5), reactor('R2', 0.5) })
  assert_eq(#engine.reactors, 2)

  local result = tick(engine, { reactor('R1', 0.5) }, NOW + 5000)
  assert_eq(#result.reactors, 1, 'ein verschwundener Reaktor faellt aus der Liste')
  assert_true(by_name(result).R2 == nil, 'und bekommt keine Entscheidung mehr')
end

-- ══ 6. Der Ein-Reaktor-Aufruf ohne Namen bleibt gueltig ═════════════════
--
-- Die Altform (input.reactor statt input.reactors) darf nicht kaputtgehen.

do
  local engine = orch.new({ reactor_name = nil })
  local result = engine.tick({
    now_ms = NOW, hardware_ready = true,
    turbines = { { name = 'T1', rpm = 900, energy = 5000,
      coil_engaged = true, current_flow = 1500, active = true } },
    reactor = { fill_ratio = 0.9, current_rods = 85, active = true },
    safety_tripped = false,
  })
  assert_eq(#result.reactors, 1, 'ein namenloser Einzelreaktor behaelt genau eine Einheit')
  assert_true(result.reactor_decision ~= nil, 'und die Ein-Reaktor-Sicht bleibt befuellt')
end

print('rt2_late_reactor_discovery_test.lua: ok')
