package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die Durchflussgrenze kommt vom GERAET, nicht aus einer Konstante.
--
-- Extreme Reactors riegelt je Bauart ab (TurbineVariant:
-- setMaxPermittedFlow -- Basic 1000, Reinforced 2000) und
-- setMaxIntakeRate() klemmt jeden Schreibwert stillschweigend darauf. Der
-- Regler hatte 2000 fest verdrahtet. An einer Basic-Turbine folgte daraus
-- eine Kette, die von aussen wie ein kaputter Regler aussieht -- siehe
-- adapters/turbine.lua's MAX_FLOW_METHODS.

local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_adapter = require('nodes.rt.rt2_adapter')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ── 1. read_turbine fuehrt die Grenze mit ────────────────────────────────
do
  local r = rt2_adapter.read_turbine('t', {
    rpm = 500, flow = 1000, energy = 1, coil_engaged = true, flow_limit = 1000 })
  assert_true(r.max_flow == 1000, 'die gelesene Bauartgrenze muss ankommen')

  local unknown = rt2_adapter.read_turbine('t', { rpm = 500, flow = 1000 })
  assert_true(unknown.max_flow == nil,
    'eine nicht lesbare Grenze ist nil -- nie eine erfundene Zahl')
end

-- ── 2. Der Regelschritt klemmt auf die Bauartgrenze ──────────────────────
do
  -- Weit unter dem Ziel, Durchfluss schon bei 1000: an einer BASIC darf
  -- nicht weiter aufgedreht werden.
  local d = rt2_turbine.compute_flow_decision({
    rpm = 400, target_rpm = 900, current_flow = 1000, max_flow = 1000 })
  assert_true(d.flow == 1000, string.format(
    'an einer Basic darf der Durchfluss 1000 nicht uebersteigen, es sind %s',
    tostring(d.flow)))

  -- Dieselbe Lage an einer Reinforced: da ist noch Luft.
  local rein = rt2_turbine.compute_flow_decision({
    rpm = 400, target_rpm = 900, current_flow = 1000, max_flow = 2000 })
  assert_true(rein.flow > 1000, 'an einer Reinforced muss weiter aufgedreht werden')
end

-- ── 3. Die Notfreigabe der Spule greift auch an einer Basic ──────────────
--
-- Der eigentliche Schaden: compute_coil_decision verlangt "Dampf am
-- Anschlag" (flow >= max_flow). Mit fest verdrahteten 2000 war das an einer
-- Basic NIE erfuellt -- eine Turbine, deren Spule den Hochlauf verhindert,
-- blieb fuer immer haengen.
do
  local input = {
    rpm = 800, target_rpm = 900, currently_engaged = true,
    current_flow = 1000,          -- Anschlag EINER BASIC
    rate_rpm_per_s = 0,           -- steigt nicht mehr
  }

  -- Ohne Angabe der Grenze gilt der Default 2000, und dann bleibt sie drin.
  local without = rt2_turbine.compute_coil_decision(input)
  assert_true(without.engaged == true and without.reason == 'HOLD_ENGAGED',
    'ohne Bauartgrenze bleibt die Spule drin -- das war der Fehler')

  -- Mit der echten Grenze wird sie freigegeben.
  input.max_flow = 1000
  local with = rt2_turbine.compute_coil_decision(input)
  assert_true(with.engaged == false and with.reason == 'RELEASE_STALLED', string.format(
    'mit der echten Bauartgrenze muss die Spule freigegeben werden, es kam %s/%s',
    tostring(with.engaged), tostring(with.reason)))
end

-- ── 4. Saettigung wird je Turbine gemessen ───────────────────────────────
do
  local rt2_orchestrator = require('nodes.rt.rt2_orchestrator')
  local engine = rt2_orchestrator.new({ reactors = { { name = 'r1' } } })
  local reactors = { { name = 'r1', safety_tripped = false,
    reactor = { fill_ratio = 0.1, current_rods = 70, active = true } } }

  -- Zwei Basic-Turbinen am Anschlag, zu langsam: beide sind gesaettigt.
  -- Mit der alten Rechnung (95 % von 2000 = 1900) waere keine erkannt
  -- worden, und die Meldung "fahren VOLLEN Durchfluss und erreichen
  -- trotzdem keine 900 RPM" waere ausgeblieben.
  local turbines = {
    { name = 't1', rpm = 600, energy = 0, coil_engaged = true, current_flow = 1000,
      max_flow = 1000, active = true },
    { name = 't2', rpm = 600, energy = 0, coil_engaged = true, current_flow = 1000,
      max_flow = 1000, active = true },
  }
  local r = engine.tick({ now_ms = 1000, hardware_ready = true,
    turbines = turbines, reactors = reactors })
  -- Der erste Takt meldet TOPOLOGY_CHANGED, also ein zweiter.
  r = engine.tick({ now_ms = 1100, hardware_ready = true,
    turbines = turbines, reactors = reactors })
  assert_true(r.capacity.saturated == 2, string.format(
    'beide Basic-Turbinen am Anschlag muessen als gesaettigt gelten, gezaehlt wurden %s',
    tostring(r.capacity.saturated)))
end

-- ── 5. Eine echte, GESAETTIGTE Basic-Anlage ──────────────────────────────
--
-- Gegen das quelltextnahe Anlagenmodell, mit der echten Klemmung in
-- set_max_intake_rate(). Eine Basic-Turbine mit kraeftiger Spule erreicht
-- die Zieldrehzahl auch bei vollem Dampf nicht -- genau der Fall, fuer den
-- die Bauartgrenze gebraucht wird. Vorher:
--
--   * Die Entscheidung rechnete 1000 + Schritt gegen einen Rueckmesswert
--     von 1000, "steht schon so an" wurde nie wahr, also wurde in JEDEM
--     Takt geschrieben.
--   * Die Saettigung wurde nicht erkannt (95 % von 2000 = 1900 wird an
--     einer Basic nie erreicht), also blieb die Meldung aus, die dem
--     Betreiber sagt, dass Dampf oder Spule das Problem sind.
do
  local harness = require('support.er_rt_harness')
  local h = harness.new({
    turbine_count = 2,
    turbine = { variant = 'basic', blades = 40, shaft_blocks = 10,
                coil_blocks = 40, coil = 'enderium' },
    reactor_headroom = 3.0,
    steam_capacity = 20000,
  })

  local inner = _G.peripheral.call
  local counts = {}
  _G.peripheral.call = function(name, method, ...)
    counts[method] = (counts[method] or 0) + 1
    return inner(name, method, ...)
  end

  h:run(400)
  for k in pairs(counts) do counts[k] = nil end
  h:run(60)

  -- Vorbedingung: der Durchfluss steht wirklich an der BASIC-Grenze.
  for _, name in ipairs(h.turbine_names) do
    local t = h.plant.turbines[name]
    assert_true(t.max_intake_rate == 1000, string.format(
      'Vorbedingung: %s muss am Basic-Anschlag 1000 stehen, steht auf %d',
      name, t.max_intake_rate))
  end

  -- Die Saettigung wird erkannt -- mit der alten Rechnung unmoeglich.
  assert_true(h.last.capacity.saturated == #h.turbine_names, string.format(
    'alle %d Turbinen am Anschlag muessen als gesaettigt gemeldet werden, es sind %s',
    #h.turbine_names, tostring(h.last.capacity.saturated)))

  -- Und es wird nicht mehr sinnlos geschrieben: die Entscheidung klemmt auf
  -- 1000, der Rueckmesswert ist 1000, der Dirty-Check greift.
  assert_true((counts.setFluidFlowRateMax or 0) == 0, string.format(
    'am Anschlag darf der Durchfluss nicht geschrieben werden, es waren %d Zugriffe'
      .. ' in 600 Takten', counts.setFluidFlowRateMax or 0))
end

print('ok rt2_per_turbine_flow_limit_test')
