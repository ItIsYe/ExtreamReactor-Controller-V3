package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Ungleich stehende Staebe muessen sich wieder ausgleichen.
--
-- Diese Eigenschaft war nie aufgeschrieben, und genau deshalb ist sie in
-- v808 verlorengegangen: der Stab-Schreibweg schreibt in JEDEM Takt, und
-- das zieht alle Staebe eines Reaktors auf denselben Wert. Ein Dirty-Check
-- ("steht schon so an, nicht schreiben") hat das entfernt -- und zwar
-- unsichtbar, weil er gegen adapters/reactor.lua's control_rod_level
-- verglich, und das ist der MITTELWERT ueber alle Staebe
-- (read_control_rods -> detail.average), nicht die Stellung eines einzelnen.
--
-- Die Folge: stehen die Staebe ungleich, kann der Mittelwert genau auf dem
-- Sollwert liegen, obwohl kein einzelner Stab dort steht. Der Regler sagt
-- dann dauerhaft "passt" und schreibt nie wieder. Von aussen sieht das aus
-- wie ein Regler, der aufgehoert hat zu regeln.
--
-- Wie es dazu kommt: ein von Hand verstellter Stab, ein zur Haelfte
-- fehlgeschlagener Schreibvorgang (apply_rod_level meldet "partial rod
-- write"), ein frisch zusammengesetztes Multiblock.

local rt2_adapter = require('nodes.rt.rt2_adapter')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- WICHTIG: der Messwert wird mitgegeben, genau wie rt2_engine.tick() es tut.
-- Ohne ihn laeuft dieser Test an einem etwaigen Dirty-Check VORBEI und
-- besteht auch auf einer Fassung, die den Ausgleich nicht mehr leistet --
-- genau so ist mir die erste Version dieses Tests durchgegangen.
local function apply(reactor, decision)
  return rt2_adapter.apply_reactor(reactor.adapter, 'r1', 'RT', decision,
    { current_rods = reactor.average(), fill_ratio = 0.7, active = true })
end

-- Ein Reaktor mit mehreren Staeben, der sich wie die echte Peripherie
-- verhaelt: geschrieben wird auf ALLE Staebe, gelesen wird der MITTELWERT.
local function new_reactor(levels)
  local self = { rods = {} }
  for i, v in ipairs(levels) do self.rods[i] = v end

  function self.average()
    local sum = 0
    for _, v in ipairs(self.rods) do sum = sum + v end
    return sum / #self.rods
  end

  function self.uniform()
    for _, v in ipairs(self.rods) do
      if v ~= self.rods[1] then return false end
    end
    return true
  end

  self.adapter = {
    apply_rod_level = function(_, level)
      local normalized = math.floor((tonumber(level) or 0) + 0.5)
      for i = 1, #self.rods do self.rods[i] = normalized end
      return true
    end,
  }
  return self
end

-- ── 1. Der Mittelwert kann luegen ────────────────────────────────────────
--
-- Zuerst festhalten, WARUM der Dirty-Check falsch war: dieser Reaktor
-- meldet genau die Sollstellung, obwohl kein einzelner Stab dort steht.
do
  local r = new_reactor({ 70, 100 })
  assert_true(r.average() == 85, 'der Mittelwert ist 85')
  assert_true(r.uniform() == false, 'kein Stab steht auf 85')
end

-- ── 2. Ein Takt gleicht sie aus ──────────────────────────────────────────
do
  local r = new_reactor({ 70, 100 })
  -- Die Entscheidung lautet "steht schon richtig" (DEADBAND gibt die
  -- gemessene Stellung zurueck) -- genau der Fall, den ein Dirty-Check
  -- weggespart hat.
  apply(r, { rods = r.average(), reason = 'DEADBAND' })
  assert_true(r.uniform(), string.format(
    'nach einem Takt muessen alle Staebe gleich stehen, sie stehen auf %s/%s',
    tostring(r.rods[1]), tostring(r.rods[2])))
  assert_true(r.rods[1] == 85, 'und zwar auf der gemeldeten Stellung')
end

-- ── 3. Auch die anderen "nichts tun"-Gruende gleichen aus ────────────────
--
-- RATE_LIMITED und CONVERGING geben ebenfalls die aktuelle Stellung zurueck.
-- Sie bedeuten "nicht weiter verstellen", nicht "nicht schreiben".
do
  for _, reason in ipairs({ 'RATE_LIMITED', 'CONVERGING', 'DEADBAND' }) do
    local r = new_reactor({ 80, 90, 100 })
    apply(r, { rods = r.average(), reason = reason })
    assert_true(r.uniform(), 'auch ' .. reason .. ' muss die Staebe ausgleichen')
  end
end

-- ── 4. Eine Sicherheitsausloesung fahrt ALLE Staebe ein ──────────────────
--
-- Der wichtigste Fall: bei einer Ausloesung darf kein Stab zurueckbleiben.
-- Ein Reaktor, dessen Mittelwert schon auf 100 liegt, weil ein Stab auf 100
-- und ein anderer darueber... geht nicht -- aber ein Mittelwert von 100 bei
-- ungleichen Staeben ist durchaus moeglich, sobald mehr als zwei Staebe im
-- Spiel sind und einer klemmt.
do
  local r = new_reactor({ 100, 100, 100, 100 })
  r.rods[1] = 70   -- einer haengt zurueck
  apply(r, { rods = 100, reason = 'SAFETY_FULL_INSERT', safety_tripped = true })
  for i, v in ipairs(r.rods) do
    assert_true(v == 100, string.format(
      'bei einer Ausloesung muss Stab %d voll eingefahren sein, er steht auf %s',
      i, tostring(v)))
  end
end

-- ── 5. Es bleibt auch ueber viele Takte ausgeglichen ─────────────────────
--
-- Gegenprobe gegen die naechste Spar-Idee: 100 Takte mit unveraenderter
-- Entscheidung duerfen die Staebe nicht auseinanderlaufen lassen, und ein
-- Eingriff von aussen muss im naechsten Takt weg sein.
do
  local r = new_reactor({ 90, 90 })
  for tick = 1, 100 do
    if tick == 50 then r.rods[2] = 70 end     -- Eingriff von aussen
    apply(r, { rods = r.average(), reason = 'DEADBAND' })
    assert_true(r.uniform(), string.format(
      'Takt %d: die Staebe muessen gleich stehen', tick))
  end
end

print('ok rt2_uneven_control_rods_test')
