package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local safety = require("core.safety")

local state = {}

local glitch = safety.evaluate_coolant_limit({
  coolant_amount = nil,
  coolant_amount_max = nil,
  coolant_ratio = nil,
  source = "UNAVAILABLE",
  min_water = 0.2,
  hysteresis = 0.05,
  trip_samples = 3,
  invalid_grace_samples = 2,
  state = state
})
if glitch.triggered then
  error("single missing coolant sample must not trigger safety")
end
if glitch.condition ~= "COOLANT_UNAVAILABLE_GRACE" then
  error("expected grace condition for first invalid sample")
end

local pending = safety.evaluate_coolant_limit({
  coolant_amount = 100,
  coolant_amount_max = 1000,
  coolant_ratio = 0.1,
  source = "getCoolantAmount/getCoolantAmountMax",
  min_water = 0.2,
  hysteresis = 0.05,
  trip_samples = 3,
  invalid_grace_samples = 2,
  state = state
})
if pending.triggered then
  error("first low coolant sample must only be pending")
end
if pending.condition ~= "COOLANT_LOW_PENDING" then
  error("expected pending low coolant condition")
end

safety.evaluate_coolant_limit({
  coolant_amount = 90,
  coolant_amount_max = 1000,
  coolant_ratio = 0.09,
  source = "getCoolantAmount/getCoolantAmountMax",
  min_water = 0.2,
  hysteresis = 0.05,
  trip_samples = 3,
  invalid_grace_samples = 2,
  state = state
})
local trip = safety.evaluate_coolant_limit({
  coolant_amount = 80,
  coolant_amount_max = 1000,
  coolant_ratio = 0.08,
  source = "getCoolantAmount/getCoolantAmountMax",
  min_water = 0.2,
  hysteresis = 0.05,
  trip_samples = 3,
  invalid_grace_samples = 2,
  state = state
})
if not trip.triggered or trip.condition ~= "COOLANT_LOW_PERSISTENT" then
  error("persistent low coolant must trigger safety")
end

local recover_pending = safety.evaluate_coolant_limit({
  coolant_amount = 220,
  coolant_amount_max = 1000,
  coolant_ratio = 0.22,
  source = "getCoolantAmount/getCoolantAmountMax",
  min_water = 0.2,
  hysteresis = 0.05,
  trip_samples = 3,
  invalid_grace_samples = 2,
  state = state
})
if recover_pending.low_ticks ~= 3 then
  error("hysteresis must prevent immediate cooldown reset before recovery threshold")
end

local recovered = safety.evaluate_coolant_limit({
  coolant_amount = 260,
  coolant_amount_max = 1000,
  coolant_ratio = 0.26,
  source = "getCoolantAmount/getCoolantAmountMax",
  min_water = 0.2,
  hysteresis = 0.05,
  trip_samples = 3,
  invalid_grace_samples = 2,
  state = state
})
if recovered.low_ticks ~= 0 or recovered.condition ~= "COOLANT_OK" then
  error("coolant state must recover once ratio clears hysteresis threshold")
end

print("safety_coolant_limit_regression_test.lua: ok")
