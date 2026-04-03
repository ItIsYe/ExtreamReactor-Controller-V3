package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local safety = require('core.safety')

local state = {}
local first = safety.evaluate_temperature_limit({
  fuel_temperature = 2050,
  casing_temperature = 1900,
  max_temperature = 2000,
  hysteresis = 50,
  trip_samples = 2,
  state = state
})
if first.triggered then
  error('first over-limit sample should be pending when trip_samples=2')
end
if first.source ~= 'getFuelTemperature' then
  error('fuel temperature should be selected when it is the hottest source')
end
if first.condition ~= 'TEMP_LIMIT_PENDING' then
  error('first over-limit sample should report TEMP_LIMIT_PENDING')
end

local second = safety.evaluate_temperature_limit({
  fuel_temperature = 2060,
  casing_temperature = 1910,
  max_temperature = 2000,
  hysteresis = 50,
  trip_samples = 2,
  state = state
})
if not second.triggered then
  error('persistent over-limit temperature should trigger safety state')
end
if second.over_limit_ticks ~= 2 then
  error('over-limit ticks must accumulate across persistent samples')
end

local reset = safety.evaluate_temperature_limit({
  fuel_temperature = 1940,
  casing_temperature = 1930,
  max_temperature = 2000,
  hysteresis = 50,
  trip_samples = 2,
  state = state
})
if reset.over_limit_ticks ~= 0 then
  error('over-limit counter should reset after cooling below hysteresis floor')
end

print("safety_temperature_limit_regression_test.lua: ok")
