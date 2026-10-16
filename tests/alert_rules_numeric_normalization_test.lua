package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Zahlen kommen ueber Funk auch als Strings an. Die Meldungsregeln duerfen
-- daran nicht scheitern und muessen mit dem Zahlenwert rechnen. (Bis v832
-- pruefte dieser Test den Dampf-Fehlbetrag von REACTOR_RODS_STUCK -- die
-- Regel ist seit v833 gestrichen, sie konnte unter dem neuen RT-Regler nie
-- ausloesen.)

_G.os = _G.os or {}
os.epoch = function() return 10000 end
local constants = require('shared.constants')

local rules = require('core.alert_rules').new({
  alert_raise_after_s = 0,
  alert_clear_after_s = 0,
  alert_cooldown_s = 0,
})

local ok, alerts_or_err = pcall(function()
  return (rules:evaluate({
    now = 10000,
    power_target = '500',
    nodes = {
      { id = 'ENERGY-1', role = constants.roles.ENERGY_NODE, stored = '50', capacity = '1000' },
      { id = 'RT-1', role = constants.roles.RT_NODE, assignment_state = 'active', capacity_max = '400' },
      { id = 'RT-2', role = constants.roles.RT_NODE, assignment_state = 'standby', capacity_max = '50' },
    },
  }))
end)
if not ok then
  error('alert rules must normalize string numbers instead of crashing: ' .. tostring(alerts_or_err))
end
local by_code = {}
for _, alert in ipairs(alerts_or_err or {}) do by_code[alert.code] = alert end
if not by_code.ENERGY_LOW then
  error('stored/capacity as strings (5 %) must still raise ENERGY_LOW')
end
if not tostring(by_code.ENERGY_LOW.message):find('5.0', 1, true) then
  error('ENERGY_LOW must compute with the numeric value, got: ' .. tostring(by_code.ENERGY_LOW.message))
end

print('alert_rules_numeric_normalization_test.lua: ok')
