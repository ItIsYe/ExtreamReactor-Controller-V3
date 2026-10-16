package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_safety = require('nodes.rt.rt2_safety')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local LIMITS = {
  max_temperature = 2000, temperature_hysteresis = 50, temperature_trip_samples = 3,
  min_water = 0.2, coolant_hysteresis = 0.05, coolant_trip_samples = 3,
  coolant_invalid_grace_samples = 3,
}

-- Normal operation must never trip.
do
  local state = rt2_safety.new_state()
  for _ = 1, 10 do
    local r = rt2_safety.evaluate(state, { temperature = 800, coolant_ratio = 0.9,
      coolant_amount = 9000, coolant_amount_max = 10000 }, LIMITS)
    assert_true(not r.tripped, 'normal temperature and coolant must never trip')
  end
end

-- Temperature over the limit must trip, but only after the configured
-- number of consecutive samples -- a single spike must not SCRAM the node.
do
  local state = rt2_safety.new_state()
  local first = rt2_safety.evaluate(state, { temperature = 2500, coolant_ratio = 0.9,
    coolant_amount = 9000, coolant_amount_max = 10000 }, LIMITS)
  assert_true(not first.tripped, 'a single over-limit temperature sample must not trip (debounce)')
  local second = rt2_safety.evaluate(state, { temperature = 2500, coolant_ratio = 0.9,
    coolant_amount = 9000, coolant_amount_max = 10000 }, LIMITS)
  assert_true(not second.tripped, 'two over-limit samples must still not trip with trip_samples=3')
  local third = rt2_safety.evaluate(state, { temperature = 2500, coolant_ratio = 0.9,
    coolant_amount = 9000, coolant_amount_max = 10000 }, LIMITS)
  assert_true(third.tripped, 'the third consecutive over-limit sample must trip')
  assert_eq(third.reason, 'TEMP_LIMIT_PERSISTENT')
end

-- Coolant below the minimum must trip the same way.
do
  local state = rt2_safety.new_state()
  local tripped = false
  for _ = 1, 5 do
    local r = rt2_safety.evaluate(state, { temperature = 800, coolant_ratio = 0.05,
      coolant_amount = 500, coolant_amount_max = 10000 }, LIMITS)
    tripped = tripped or r.tripped
  end
  assert_true(tripped, 'a sustained low coolant ratio must trip')
end

-- Temperature wins the reason when both conditions hold, so the operator
-- sees the more urgent one first.
do
  local state = rt2_safety.new_state()
  local last
  for _ = 1, 5 do
    last = rt2_safety.evaluate(state, { temperature = 2500, coolant_ratio = 0.05,
      coolant_amount = 500, coolant_amount_max = 10000 }, LIMITS)
  end
  assert_true(last.tripped)
  assert_eq(last.reason, 'TEMP_LIMIT_PERSISTENT', 'temperature must take precedence over coolant in the reported reason')
end

-- Recovery: once the readings are healthy again, the trip must clear
-- (SAFE must not latch forever on its own -- only a manual SCRAM latches).
do
  local state = rt2_safety.new_state()
  for _ = 1, 5 do
    rt2_safety.evaluate(state, { temperature = 2500, coolant_ratio = 0.9,
      coolant_amount = 9000, coolant_amount_max = 10000 }, LIMITS)
  end
  local recovered
  for _ = 1, 5 do
    recovered = rt2_safety.evaluate(state, { temperature = 800, coolant_ratio = 0.9,
      coolant_amount = 9000, coolant_amount_max = 10000 }, LIMITS)
  end
  assert_true(not recovered.tripped, 'a temperature back below the hysteresis band must clear the trip')
end

-- A missing temperature reading must not be treated as "hot" (that would
-- SCRAM a healthy node on a transient peripheral read failure), and a
-- missing coolant reading must not trip within the grace window.
do
  local state = rt2_safety.new_state()
  local r = rt2_safety.evaluate(state, {}, LIMITS)
  assert_true(not r.tripped, 'entirely missing readings must not trip on the first tick')
end

print('rt2_safety_test.lua: ok')
