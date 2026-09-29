package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- core/refresh_gate.lua -- die Haltefrist, mit der nodes/fuel/main.lua den
-- ME-Bridge-Reservelesevorgang und den Statuspayload-Aufbau drosselt.
--
-- Anlass (Betrieb, 2026-09-29): "fuel braucht sehr lange bis er Daten hat
-- und wenn noetig reagiert". Der Statuspayload wurde von der slow-Coroutine
-- zweimal pro Sekunde neu gebaut, und jeder Aufbau machte bis zu vier
-- synchrone getItem()-Calls auf die ME Bridge -- acht je Sekunde fuer eine
-- Zahl, die alle fuenf Sekunden verschickt wird. CC:Tweaked hat nur einen
-- Strang: diese Zeit fehlte der Ventil-Logik und der Bedienung.

local refresh_gate = require('core.refresh_gate')

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: erwartet %s, bekommen %s",
      label, tostring(expected), tostring(actual)), 2)
  end
end

-- 1. Vor der ersten Lesung ist immer faellig.
do
  local g = refresh_gate.new()
  assert_eq(g:due(1000, 5000), true, "erste Lesung")
end

-- 2. Innerhalb der Frist nicht faellig, nach Ablauf faellig.
do
  local g = refresh_gate.new()
  g:mark(1000)
  assert_eq(g:due(1000, 5000), false, "gleicher Zeitpunkt")
  assert_eq(g:due(4999, 5000), false, "kurz vor Ablauf")
  assert_eq(g:due(6000, 5000), true, "nach Ablauf")
  assert_eq(g:due(6000, 5000), true, "faellig bleibt faellig ohne mark()")
end

-- 3. Genau auf der Frist ist faellig (>=, nicht >).
do
  local g = refresh_gate.new()
  g:mark(0)
  assert_eq(g:due(5000, 5000), true, "exakt auf der Frist")
end

-- 4. Zurueckspringende Uhr friert den Wert nicht ein.
--    Ohne die age<0-Pruefung waere now-last dauerhaft negativ und damit
--    immer kleiner als die Frist: der Wert wuerde nie wieder gelesen --
--    dieselbe Verklemmung wie im Durchflussregler (siehe
--    tests/rt2_clock_backwards_no_regulator_lock_test.lua).
do
  local g = refresh_gate.new()
  g:mark(500000)
  assert_eq(g:due(1000, 5000), true, "Uhr rueckwaerts")
  -- und nach dem Nachziehen laeuft die Frist wieder normal
  g:mark(1000)
  assert_eq(g:due(1200, 5000), false, "nach dem Nachziehen wieder gedrosselt")
  assert_eq(g:due(6001, 5000), true, "danach wieder faellig")
end

-- 5. Bindungswechsel schlaegt die Frist. Eine frisch gefundene (oder
--    verlorene) ME Bridge macht den alten Wert sofort wertlos, egal wie
--    jung er ist -- sonst stuende nach dem Binden bis zu status_interval
--    Sekunden lang weiter "Reserve 0".
do
  local g = refresh_gate.new()
  g:mark(1000, "meBridge_0")
  assert_eq(g:due(1200, 5000, "meBridge_0"), false, "gleiche Bindung, frisch")
  assert_eq(g:due(1200, 5000, "meBridge_1"), true, "andere Bindung")
  assert_eq(g:due(1200, 5000, nil), true, "Bindung verloren")
  g:mark(1000, nil)
  assert_eq(g:due(1200, 5000, "meBridge_0"), true, "Bindung neu gefunden")
end

-- 6. invalidate() erzwingt die naechste Lesung ohne Zeitangabe.
do
  local g = refresh_gate.new()
  g:mark(1000, "meBridge_0")
  assert_eq(g:due(1200, 5000, "meBridge_0"), false, "vor invalidate")
  g:invalidate()
  assert_eq(g:due(1200, 5000, "meBridge_0"), true, "nach invalidate")
end

-- 7. Frist 0 heisst: nie drosseln (die Drossel laesst sich abschalten).
do
  local g = refresh_gate.new()
  g:mark(1000)
  assert_eq(g:due(1000, 0), true, "Frist 0")
end

-- 8. Unsinnige Frist (nil/negativ) drosselt nicht, statt zu krachen.
do
  local g = refresh_gate.new()
  g:mark(1000)
  assert_eq(g:due(1000, nil), true, "Frist nil")
  assert_eq(g:due(1000, -5000), true, "Frist negativ")
end

print("OK refresh_gate_test")
