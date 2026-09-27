package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Zwillings-Integrationstest gefallen, aber ein echter Regelfehler:
--
--   Die ganze Flotte drehte mit 897 RPM gegen ein Ziel von 900, der Reaktor
--   lieferte Dampf, jede Turbine stand auf SETTLED -- und der Knoten meldete
--   0 RF/t. Keine einzige Turbine lieferte etwas.
--
-- Die Ursache liegt zwischen zwei Zahlen, die einzeln richtig aussehen:
--
--   rt2_turbine.SETTLE_BAND_RPM = 4    -- ab hier stellt der Regler nichts mehr
--   rt2_turbine.COIL_ENGAGE_RPM = 900  -- ab hier kuppelt die Spule ein
--
-- Eine Turbine, die bei 896..899 einschwingt, ist fuer den Regler
-- angekommen und liegt fuer die Spule noch darunter. Sie kuppelt also nie
-- ein, und eine ungekuppelte Turbine liefert nichts -- dauerhaft, denn der
-- Regler hat keinen Grund mehr, etwas zu aendern. Ohne Last beschleunigt der
-- Rotor sogar, und der Regler nimmt Dampf weg, um die 900 zu halten: die
-- Anlage sieht in jeder Anzeige gesund aus und produziert nichts.
--
-- Die Ruhezone des Reglers und die Kupplungsschwelle muessen sich deshalb
-- ueberlappen.

local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end end

-- Jede Drehzahl, die der Regler als "am Ziel" ansieht, muss die Spule
-- einkuppeln -- sonst gibt es eine Drehzahl, bei der die Turbine steht und
-- keiner der beiden Regler etwas dagegen tut.
for rpm = rt2_turbine.FULL_TARGET_RPM - rt2_turbine.SETTLE_BAND_RPM,
          rt2_turbine.FULL_TARGET_RPM + rt2_turbine.SETTLE_BAND_RPM do
  local flow = rt2_turbine.compute_flow_decision({
    rpm = rpm, target_rpm = rt2_turbine.FULL_TARGET_RPM, current_flow = 1500,
  })
  assert_eq(flow.reason, 'SETTLED', 'Vorbedingung: der Regler ist bei ' .. rpm .. ' zufrieden')

  local coil = rt2_turbine.compute_coil_decision({
    rpm = rpm, target_rpm = rt2_turbine.FULL_TARGET_RPM, currently_engaged = false,
  })
  assert_eq(coil.engaged, true,
    'bei ' .. rpm .. ' RPM stellt der Regler nichts mehr -- dann MUSS die Spule kuppeln,'
      .. ' sonst liefert die Turbine fuer immer nichts')
end

-- Die Hysterese bleibt: eine gekuppelte Turbine loest erst deutlich
-- darunter wieder, sonst flatterte sie um die Schwelle.
do
  local hold = rt2_turbine.compute_coil_decision({
    rpm = rt2_turbine.FULL_TARGET_RPM - rt2_turbine.SETTLE_BAND_RPM,
    target_rpm = rt2_turbine.FULL_TARGET_RPM, currently_engaged = true,
  })
  assert_eq(hold.engaged, true, 'und bleibt dort gekuppelt')

  local released = rt2_turbine.compute_coil_decision({
    rpm = rt2_turbine.COIL_DISENGAGE_RPM - 1,
    target_rpm = rt2_turbine.FULL_TARGET_RPM, currently_engaged = true,
  })
  assert_eq(released.engaged, false, 'erst unter der Loeseschwelle gibt sie den Rotor frei')
end

-- Und der Hochlauf bleibt unbelastet: weit unter dem Ziel darf die Spule
-- nicht kuppeln, sonst bremst die Turbine sich beim Anfahren selbst.
do
  local ramping = rt2_turbine.compute_coil_decision({
    rpm = 400, target_rpm = rt2_turbine.FULL_TARGET_RPM, currently_engaged = false,
  })
  assert_eq(ramping.engaged, false, 'eine anfahrende Turbine beschleunigt ohne Last')
end

print('rt2_settled_turbine_couples_test.lua: ok')
