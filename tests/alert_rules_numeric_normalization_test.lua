package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.os = _G.os or {}
os.epoch = function() return 10000 end

local rules = require('core.alert_rules').new({
  alert_raise_after_s = 0,
  alert_clear_after_s = 0,
  alert_cooldown_s = 0,
  steam_deficit_pct = 0.9,
  rod_stuck_secs = 0,
})

local ok, alerts_or_err = pcall(function()
  local alerts, clears = rules:evaluate({
    now = 10000,
    nodes = {
      {
        id = 'RT-1',
        role = 'RT_NODE',
        steam = '10000',
        reactors = {
          { id = 'BigReactors-Reactor_4', steam_production = '7500', rods_level = 70 },
        },
      },
    },
  })
  return alerts, clears
end)

if not ok then
  error('alert rules should normalize string steam values instead of crashing: ' .. tostring(alerts_or_err))
end

local alerts = alerts_or_err
if type(alerts) ~= 'table' or #alerts < 1 then
  error('expected at least one alert after normalized steam deficit evaluation')
end

print('alert_rules_numeric_normalization_test.lua: ok')
