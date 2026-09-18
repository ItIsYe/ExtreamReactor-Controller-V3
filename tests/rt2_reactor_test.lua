package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_reactor = require('nodes.rt.rt2_reactor')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- Safety override always wins and always means full insertion (0% power),
-- regardless of what the tank is doing.
do
  local r = rt2_reactor.compute_rod_level({ fill_ratio = 0.1, current_rods = 20, safety_override = true })
  assert_eq(r.rods, 100, 'safety override must force full rod insertion')
end

-- Missing steam reading must fail SAFE (full insertion), not hold or guess.
do
  local r = rt2_reactor.compute_rod_level({ fill_ratio = nil, current_rods = 50 })
  assert_eq(r.rods, 100, 'a missing steam reading must fail toward full insertion, not hold the last rod level')
end

-- Inside the deadband: no movement.
do
  local r = rt2_reactor.compute_rod_level({ fill_ratio = 0.51, target_fill = 0.5, current_rods = 60 })
  assert_eq(r.rods, 60, 'inside the deadband, rods must not move')
  assert_eq(r.reason, 'DEADBAND')
end

-- Tank too full (more steam than needed) -> INSERT rods (increase level)
-- -> less power. This is the rod-convention sign check: getting this
-- backwards (treating a fuller tank as "withdraw more") would silently
-- run the reactor at the wrong end of its power range.
do
  local r = rt2_reactor.compute_rod_level({ fill_ratio = 0.9, target_fill = 0.5, current_rods = 50 })
  assert_true(r.rods > 50, 'a tank fuller than target must INSERT rods (raise the level), reducing power')
  assert_eq(r.reason, 'TANK_FULL_INSERT')
end

-- Tank too low (need more steam) -> WITHDRAW rods (decrease level) -> more power.
do
  local r = rt2_reactor.compute_rod_level({ fill_ratio = 0.1, target_fill = 0.5, current_rods = 50 })
  assert_true(r.rods < 50, 'a tank emptier than target must WITHDRAW rods (lower the level), increasing power')
  assert_eq(r.reason, 'TANK_LOW_WITHDRAW')
end

-- Rod movement per step is capped -- a huge fill error must not snap rods
-- straight to an extreme in one control step.
do
  local r = rt2_reactor.compute_rod_level({ fill_ratio = 0.0, target_fill = 0.5, current_rods = 100 })
  assert_true(r.rods > 0, 'even a maximal fill error must be capped by MAX_STEP per control step')
  assert_true(100 - r.rods <= rt2_reactor.MAX_STEP + 0.0001, 'the step down must never exceed MAX_STEP')
end

-- Rods must clamp at the physical 0/100 bounds regardless of how large the error is.
do
  local r = rt2_reactor.compute_rod_level({ fill_ratio = 0.0, target_fill = 0.5, current_rods = 2 })
  assert_true(r.rods >= 0, 'rods must never go below 0')
end
do
  local r = rt2_reactor.compute_rod_level({ fill_ratio = 1.0, target_fill = 0.5, current_rods = 98 })
  assert_true(r.rods <= 100, 'rods must never exceed 100')
end

print('rt2_reactor_test.lua: ok')
