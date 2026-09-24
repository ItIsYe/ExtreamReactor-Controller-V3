package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Gemeldet vom Betreiber: "nicht immer hoch runter hoch runter, sondern
-- irgendwann stabil bleiben."
--
-- Diese Datei prueft zweierlei: dass eine Turbine ihre eigene Kennlinie
-- richtig ausmisst (rt2_turbine_model.lua), und dass der Regler damit
-- tatsaechlich zur Ruhe kommt -- gegen eine Strecke mit Traegheit, also
-- gegen genau das, woran der alte, tastende Regler gescheitert ist.

local model = require('nodes.rt.rt2_turbine_model')
local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_near(a, e, tol, m)
  if math.abs(a - e) > tol then
    error((m or 'near') .. ': expected=' .. tostring(e) .. ' +/-' .. tostring(tol)
      .. ' actual=' .. tostring(a), 2)
  end
end

-- ══ 1. Die Messung findet die Kennlinie wieder ═══════════════════════════

do
  local SLOPE, INTERCEPT = 0.6, 0   -- 900 RPM bei 1500 mB/t
  local state, now = model.new_state(), 0

  -- Betriebspunkte, wie sie im Betrieb entstehen: der Durchfluss steht
  -- eine Weile still, der Rotor steht dazu passend still.
  for _, flow in ipairs({ 1400, 1440, 1470, 1490, 1500, 1510, 1530, 1560, 1580 }) do
    local rpm = SLOPE * flow + INTERCEPT
    -- Erster Messwert setzt den Anker, der zweite (spaeter) den Punkt.
    state = model.observe(state, { now_ms = now, flow = flow, rpm = rpm, coil_engaged = true })
    now = now + model.MIN_HOLD_MS + 100
    state = model.observe(state, { now_ms = now, flow = flow, rpm = rpm, coil_engaged = true })
    now = now + 100
  end

  local profile, why = model.derive(state)
  assert_true(profile, 'die Kennlinie muss sich ableiten lassen: ' .. tostring(why))
  assert_near(profile.slope, SLOPE, 0.01, 'die gemessene Steigung muss die echte sein')
  assert_near(model.flow_for(profile, 900), 1500, 5,
    'und daraus muss der Durchfluss fuer 900 RPM folgen')
  assert_true(profile.min_adjust_interval_ms >= model.INTERVAL_MIN_MS
    and profile.min_adjust_interval_ms <= model.INTERVAL_MAX_MS,
    'das abgeleitete Stellintervall muss geklemmt sein')
end

-- ══ 2. Was NICHT als Kennlinie durchgeht ═════════════════════════════════

do
  -- Zu wenige Punkte.
  assert_true(model.derive(model.new_state()) == nil, 'ohne Messwerte keine Kennlinie')

  -- Immer derselbe Durchfluss: eine laufende, ruhige Anlage liefert das
  -- stundenlang. Sie darf daraus keine Gerade machen -- und sie darf den
  -- einen Punkt auch nicht dreissigmal zaehlen, sonst sieht es nach
  -- vielen Messwerten aus, obwohl nur einer da ist.
  local state, now = model.new_state(), 0
  for _ = 1, 30 do
    state = model.observe(state, { now_ms = now, flow = 1500, rpm = 900, coil_engaged = true })
    now = now + model.MIN_HOLD_MS + 100
  end
  assert_eq(state.n, 1, 'derselbe Betriebspunkt zaehlt einmal, nicht dreissigmal')
  local profile, why = model.derive(state)
  assert_true(profile == nil, 'ein einziger Betriebspunkt ist keine Kennlinie')
  assert_true(tostring(why):find('zu wenige') ~= nil, 'und der Grund muss das sagen: ' .. tostring(why))

  -- Genug Punkte, aber alle dicht beieinander: die Gerade waere beliebig.
  local tight, tn = model.new_state(), 0
  for i = 1, 12 do
    local flow = 1500 + i
    tight = model.observe(tight, { now_ms = tn, flow = flow, rpm = 900, coil_engaged = true })
    tn = tn + model.MIN_HOLD_MS + 100
    tight = model.observe(tight, { now_ms = tn, flow = flow, rpm = 900, coil_engaged = true })
    tn = tn + 100
  end
  local tight_profile, tight_why = model.derive(tight)
  assert_true(tight_profile == nil, 'zwoelf Punkte auf zwoelf mB/t sind keine Kennlinie')
  assert_true(tostring(tight_why):find('eng beieinander') ~= nil,
    'und der Grund muss das sagen: ' .. tostring(tight_why))

  -- Ohne Last gilt eine andere Gerade -- offene Spule liefert gar nichts.
  local free, t = model.new_state(), 0
  for _, flow in ipairs({ 1000, 1100, 1200, 1300, 1400, 1500, 1600, 1700, 1800 }) do
    free = model.observe(free, { now_ms = t, flow = flow, rpm = flow * 0.9, coil_engaged = false })
    t = t + model.MIN_HOLD_MS + 100
    free = model.observe(free, { now_ms = t, flow = flow, rpm = flow * 0.9, coil_engaged = false })
    t = t + 100
  end
  assert_eq(free.n, 0, 'ohne gekuppelte Spule darf kein Messwert entstehen')

  -- Ein Rotor, der noch hochdreht, gehoert nicht zu diesem Durchfluss.
  local moving, m = model.new_state(), 0
  moving = model.observe(moving, { now_ms = m, flow = 1500, rpm = 500, coil_engaged = true })
  m = m + model.MIN_HOLD_MS + 100
  moving = model.observe(moving, { now_ms = m, flow = 1500, rpm = 800, coil_engaged = true })
  assert_eq(moving.n, 0, 'ein noch beschleunigender Rotor liefert keinen Betriebspunkt')
end

-- ══ 3. Persistenz, inklusive Klemmung beim Laden ═════════════════════════

do
  local stored
  local ok = model.save_units({ turbine_1 = { slope = 0.6, intercept = -12,
    min_adjust_interval_ms = 900, samples = 11, flow_spread = 180 } },
    { path = '/p', write_config = function(_, data) stored = data; return true end })
  assert_true(ok, 'speichern muss gelingen')

  local loaded = model.load_units({ path = '/p', read_config = function() return stored end })
  assert_true(loaded.turbine_1 ~= nil, 'und wieder ladbar sein')
  assert_near(loaded.turbine_1.slope, 0.6, 1e-9)
  assert_near(loaded.turbine_1.intercept, -12, 1e-9)

  -- Eine von Hand editierte Datei darf den Regler nicht aufweiten.
  local tampered = { units = { turbine_1 = { modelled = true, slope = 999,
    min_adjust_interval_ms = 5 } } }
  local rejected = model.load_units({ path = '/p', read_config = function() return tampered end })
  assert_true(rejected.turbine_1 == nil, 'eine unplausible Steigung darf nicht geladen werden')

  local slow = { units = { turbine_1 = { modelled = true, slope = 0.6,
    min_adjust_interval_ms = 999999 } } }
  local clamped = model.load_units({ path = '/p', read_config = function() return slow end })
  assert_eq(clamped.turbine_1.min_adjust_interval_ms, model.INTERVAL_MAX_MS,
    'ein ueberzogenes Stellintervall wird auf die Obergrenze geklemmt')
end

-- ══ 4. Der eigentliche Punkt: der Regler kommt zur Ruhe ══════════════════
--
-- Eine Strecke mit Traegheit, wie ein echter Rotor: der Durchfluss
-- bestimmt die ENDdrehzahl, aber der Rotor braucht Sekunden dorthin.
-- Genau daran ist der alte Regler gescheitert -- er hat auf eine
-- Drehzahl reagiert, in der seine vorige Verstellung noch gar nicht
-- steckte, und deshalb immer wieder ueberzogen.

local TICK_MS = 100
local K = 0.6          -- RPM je mB/t im Beharrungszustand, unter Last
local FREE_FACTOR = 1.15 -- ohne Last traegt derselbe Dampf mehr Drehzahl
local ALPHA = 0.06     -- Traegheit: ~1.6 s Zeitkonstante
local FULL = rt2_turbine.FULL_TARGET_RPM

-- Eine Turbine samt Regler. adaptive=false bildet den alten Regler nach:
-- keine Uhr, keine Drehzahlaenderung, kein Streckenmodell -- also genau
-- die Aufrufform, die compute_flow_decision vor dieser Aenderung hatte.
local function new_turbine(opts)
  opts = opts or {}
  local t = {
    rpm = opts.rpm or 0, flow = opts.flow or 0, coil = false, now = 0,
    last_change_ms = nil, last_rpm = nil,
    mstate = model.new_state(), profile = opts.profile,
    trace = {},
  }

  function t.step(target_rpm)
    local coil = rt2_turbine.compute_coil_decision({
      rpm = t.rpm, target_rpm = target_rpm, currently_engaged = t.coil,
    })
    t.coil = coil.engaged

    if opts.adaptive and not t.profile then
      t.mstate = model.observe(t.mstate, {
        now_ms = t.now, flow = t.flow, rpm = t.rpm, coil_engaged = t.coil,
      })
      t.profile = model.derive(t.mstate)
    end

    local rpm_rate
    if opts.adaptive and t.last_rpm then rpm_rate = (t.rpm - t.last_rpm) / (TICK_MS / 1000) end
    t.last_rpm = t.rpm

    local decision = rt2_turbine.compute_flow_decision({
      rpm = t.rpm, target_rpm = target_rpm, current_flow = t.flow,
      coil_engaged = t.coil,
      -- Die Ruhezone ist unabhaengig vom Rest gewachsen, also muss sie
      -- fuer den Vergleich mit dem alten Regler ausdruecklich aus sein --
      -- sonst waere "alt" gar nicht mehr alt.
      settle_band_rpm = (not opts.adaptive) and 0 or nil,
      now_ms = opts.adaptive and t.now or nil,
      last_change_ms = opts.adaptive and t.last_change_ms or nil,
      rpm_rate = rpm_rate,
      model = opts.adaptive and t.profile or nil,
    })
    if decision.flow ~= t.flow then t.last_change_ms = t.now end
    t.flow = decision.flow

    local steady = t.flow * K * (t.coil and 1.0 or FREE_FACTOR)
    t.rpm = t.rpm + (steady - t.rpm) * ALPHA
    t.now = t.now + TICK_MS
    t.trace[#t.trace + 1] = { rpm = t.rpm, flow = t.flow, target = target_rpm, reason = decision.reason }
    return decision
  end

  function t.run(ticks, target_rpm)
    for _ = 1, ticks do t.step(target_rpm) end
  end

  return t
end

-- Wie oft der Durchfluss in einem Abschnitt die Richtung wechselt, und
-- wie weit die Drehzahl dort hoechstens danebenlag.
local function stats(trace, from)
  local reversals, last_dir, worst = 0, 0, 0
  for i = math.max(2, from), #trace do
    local delta = trace[i].flow - trace[i - 1].flow
    local dir = (delta > 0 and 1) or (delta < 0 and -1) or 0
    if dir ~= 0 then
      if last_dir ~= 0 and dir ~= last_dir then reversals = reversals + 1 end
      last_dir = dir
    end
    local err = math.abs(trace[i].rpm - trace[i].target)
    if err > worst then worst = err end
  end
  return reversals, worst
end

-- ── 4a. Hochfahren und halten ────────────────────────────────────────────

do
  local TICKS = 1200 -- 120 s
  local old = new_turbine({ adaptive = false })
  local new = new_turbine({ adaptive = true })
  old.run(TICKS, FULL)
  new.run(TICKS, FULL)

  local half = math.floor(TICKS / 2)
  local old_rev, old_worst = stats(old.trace, half)
  local new_rev, new_worst = stats(new.trace, half)

  -- Wenn der alte Regler hier NICHT pendelte, wuerde der Vergleich nichts
  -- aussagen -- dann waere die Nachbildung zu gutmuetig.
  assert_true(old_rev > 10, string.format(
    'die Nachbildung muss das gemeldete Pendeln zeigen (Richtungswechsel alt=%d)', old_rev))

  assert_eq(new_rev, 0, string.format(
    'im eingeschwungenen Betrieb darf der Durchfluss gar nicht mehr hin- und herlaufen'
      .. ' (alt=%d neu=%d Richtungswechsel)', old_rev, new_rev))
  assert_true(new_worst <= rt2_turbine.SETTLE_BAND_RPM + 1, string.format(
    'und die Drehzahl soll praktisch auf dem Ziel stehen, war %.1f RPM daneben (alt %.1f)',
    new_worst, old_worst))

  -- Ueberschwinger beim Hochfahren: der alte Regler hat den Durchfluss so
  -- lange weiter aufgemacht, wie die Drehzahl unter dem Ziel lag, und
  -- dabei Dampf aufgestaut.
  local function peak(trace)
    local p = 0
    for _, s in ipairs(trace) do if s.rpm > p then p = s.rpm end end
    return p
  end
  assert_true(peak(new.trace) < peak(old.trace), string.format(
    'und beim Hochfahren darf er nicht mehr ueberschwingen (alt=%.0f neu=%.0f RPM)',
    peak(old.trace), peak(new.trace)))
end

-- ── 4b. Im Betrieb vermisst sich die Turbine selbst ──────────────────────
--
-- Stillstand allein lehrt nichts: eine Gerade braucht Punkte an
-- verschiedenen Stellen. Die liefert der normale Betrieb -- MASTER
-- verschiebt seine Leistungsvorgabe, und die Turbine steht danach bei
-- einem anderen Durchfluss still.

local learned_profile

do
  local t = new_turbine({ adaptive = true })
  t.run(400, FULL)
  for _, target in ipairs({ 820, 700, 880, 640, 760, 900, 680, 840, 720, 900 }) do
    t.run(300, target)
  end

  learned_profile = t.profile
  assert_true(learned_profile ~= nil,
    'nach mehreren Lastpunkten muss die Turbine ihre Kennlinie kennen'
      .. ' (Betriebspunkte=' .. tostring(t.mstate.n)
      .. ', Streuung=' .. string.format('%.0f', model.spread(t.mstate)) .. ' mB/t)')
  assert_near(learned_profile.slope, K, 0.08, string.format(
    'und sie muss die echte Kennlinie treffen (%.3f statt %.3f RPM je mB/t)',
    learned_profile.slope, K))
  assert_near(model.flow_for(learned_profile, FULL), FULL / K, 80,
    'und damit den Durchfluss fuer das volle Ziel')
end

-- ── 4c. Mit Kennlinie folgt sie einer neuen Vorgabe in einem Zug ─────────
--
-- Das ist der praktische Gewinn: MASTER verschiebt die Vorgabe, und statt
-- sich in Schritten von TRIM_STEP heranzutasten, stellt die Turbine den
-- Durchfluss, von dem sie WEISS, dass er die neue Drehzahl traegt.
--
-- Verglichen wird derselbe Regler mit und ohne Kennlinie -- nur so misst
-- der Vergleich die Kennlinie und nicht nebenbei die anderen Aenderungen.

do
  local NEW_TARGET = 700

  local function follow(profile)
    -- Beide starten eingeschwungen bei 900 unter Last.
    local t = new_turbine({ adaptive = true, profile = profile,
      rpm = FULL, flow = FULL / K })
    t.coil = true
    t.run(20, FULL)
    local from = #t.trace
    t.run(600, NEW_TARGET)

    local settled_after, moves, overshoot = nil, 0, 0
    for i = from + 1, #t.trace do
      if t.trace[i].flow ~= t.trace[i - 1].flow then moves = moves + 1 end
      local below = NEW_TARGET - t.trace[i].rpm
      if below > overshoot then overshoot = below end
      if not settled_after
          and math.abs(t.trace[i].rpm - NEW_TARGET) <= rt2_turbine.SETTLE_BAND_RPM + 1 then
        settled_after = i - from
      end
    end
    return settled_after, moves, overshoot, select(1, stats(t.trace, from))
  end

  -- Ohne Kennlinie: derselbe Regler, aber er muss sich herantasten. Das
  -- Lernen wird hier nicht gebraucht -- profile bleibt schlicht leer,
  -- bis genug Betriebspunkte da sind, und so lange dauert dieser Lauf
  -- nicht.
  local plain_ticks, plain_moves, plain_under, plain_rev = follow(nil)
  local model_ticks, model_moves, model_under, model_rev = follow(learned_profile)

  assert_true(model_ticks ~= nil, 'mit Kennlinie muss die neue Vorgabe erreicht werden')
  assert_true(plain_ticks ~= nil, 'und ohne Kennlinie ebenfalls -- sonst misst der Vergleich nichts')

  -- Der Gewinn liegt nicht in ein paar Takten, sondern darin, WIE dorthin
  -- gefahren wird: ein einziger Stellvorgang auf den Wert, von dem die
  -- Turbine weiss, dass er die neue Drehzahl traegt -- statt sich in
  -- vielen Schritten heranzutasten, dabei unter die Vorgabe zu fallen und
  -- wieder zurueckzukommen.
  assert_true(model_moves * 3 <= plain_moves, string.format(
    'mit Kennlinie darf es nur einen Bruchteil der Verstellungen brauchen (ohne=%d mit=%d)',
    plain_moves, model_moves))
  assert_eq(model_rev, 0, string.format(
    'und kein einziges Hin und Her (ohne=%d mit=%d Richtungswechsel)', plain_rev, model_rev))
  assert_true(model_under < plain_under, string.format(
    'und sie darf nicht unter die neue Vorgabe durchfallen (ohne=%.1f mit=%.1f RPM darunter)',
    plain_under, model_under))
  assert_true(model_ticks <= plain_ticks * 1.5, string.format(
    'das alles ohne merklich laenger zu brauchen (ohne=%d mit=%d Takte)',
    plain_ticks, model_ticks))
end

print('rt2_turbine_model_test.lua: ok')
