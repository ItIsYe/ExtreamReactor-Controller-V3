package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Uebernommen aus tests/water_rt_persistence_ack_honesty_test.lua (Block 1),
-- als die WATER-Node in v830 entfiel: deren SET_TARGET-Block und die RT-
-- Bloecke gibt es nicht mehr, die Lehre bleibt -- eine fehlgeschlagene
-- Persistenz darf nie als angewendet quittiert werden. Dafuer haelt
-- nodes/support/command_handler.lua's finish() ein optionales `extra`-
-- Argument bereit (z.B. `persisted = false` nach einem fehlgeschlagenen
-- Config-Write), ohne `ok=true` zu verfaelschen.

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

do
  local support_command_handler = require('nodes.support.command_handler')
  local devices = {}

  local result_no_extra = support_command_handler.finish(devices, true)
  assert_eq(result_no_extra.ok, true, 'finish(devices, true) must stay ok=true without extra')
  assert_eq(result_no_extra.persisted, nil, 'finish(devices, true) without extra must not invent a persisted field')

  local result_with_extra = support_command_handler.finish(devices, true, { persisted = false })
  assert_eq(result_with_extra.ok, true, 'finish(devices, true, {persisted=false}) must keep ok=true (RAM value was applied)')
  assert_eq(result_with_extra.persisted, false, 'finish() must merge the extra table into the result')
end

print('command_finish_persisted_extra_test.lua: ok')
