package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_capacity = require('nodes.rt.rt2_capacity')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local function turbine(rpm, energy, coil_engaged)
  return { rpm = rpm, energy = energy, coil_engaged = coil_engaged ~= false }
end

-- Not enough turbines at target -> not ready.
do
  local s = rt2_capacity.update(rt2_capacity.new_state(), {
    turbine(900, 100), turbine(300, 0), turbine(300, 0)
  })
  assert_true(not s.ready, 'below MIN_FRACTION at target must not become ready')
end

-- Enough turbines at target -> ready, with the safety margin applied.
do
  local s = rt2_capacity.update(rt2_capacity.new_state(), {
    turbine(900, 100), turbine(905, 100)
  })
  assert_true(s.ready, 'all turbines at target must become ready')
  assert_eq(s.max_output, 200 * (1 - rt2_capacity.SAFETY_MARGIN), 'max_output must be the measured peak minus the safety margin')
end

-- A higher subsequent measurement updates max_output; a lower one never
-- decreases it (copy-on-write: the previous state object itself must be
-- untouched).
do
  local s1 = rt2_capacity.update(rt2_capacity.new_state(), { turbine(900, 100), turbine(900, 100) })
  local s2 = rt2_capacity.update(s1, { turbine(900, 120), turbine(900, 120) })
  assert_true(s2.max_output > s1.max_output, 'a higher measurement must raise max_output')
  assert_eq(s1.max_output, 100 * 2 * (1 - rt2_capacity.SAFETY_MARGIN), 'the earlier state object must not be mutated by a later update')

  local s3 = rt2_capacity.update(s2, { turbine(900, 50), turbine(900, 50) })
  assert_eq(s3.max_output, s2.max_output, 'a lower measurement must never decrease the learned max_output')
end

-- Turbine COUNT change invalidates the OLD learned value (the only thing
-- that should) -- it does not carry the stale max_output forward, even if
-- a fresh measurement on the new fleet happens to succeed immediately.
do
  local s1 = rt2_capacity.update(rt2_capacity.new_state(), { turbine(900, 100), turbine(900, 100) })
  assert_true(s1.ready, 'sanity: learned with 2 turbines')
  local old_max = s1.max_output

  -- New fleet size, and it happens to already be at target -> re-measures
  -- immediately with the NEW turbine count, not the stale 2-turbine value.
  local s2 = rt2_capacity.update(s1, { turbine(900, 100), turbine(900, 100), turbine(900, 100) })
  assert_true(s2.ready, 'a fresh measurement on the new fleet must be accepted on its own merits')
  assert_true(s2.max_output ~= old_max, 'the new measurement must not just carry the old (wrong-fleet-size) max_output forward')
  assert_eq(s2.max_output, 300 * (1 - rt2_capacity.SAFETY_MARGIN), 'the new max_output must reflect the new turbine count, not the old one')

  -- New fleet size, NOT yet re-measured (e.g. still spinning up) -> must
  -- drop to not-ready rather than keep reporting the old fleet's value.
  local s3 = rt2_capacity.update(s1, { turbine(100, 0), turbine(100, 0), turbine(100, 0) })
  assert_true(not s3.ready, 'a turbine count change with no valid fresh measurement yet must not stay ready on the old value')
  assert_eq(s3.max_output, 0, 'an invalidated-but-not-yet-remeasured state must not report the stale max_output')
  assert_eq(s3.reason, 'TOPOLOGY_CHANGED')
end

-- Regression (the actual production bug this module exists to make
-- impossible): a turbine fleet that keeps the SAME COUNT across a restart
-- but gets renamed peripherals must NOT invalidate learning. This module
-- never even sees names -- only count -- so there is nothing to get wrong
-- here, but assert the persistence contract explicitly.
do
  local files = {}
  local write_config = function(path, data) files[path] = data; return true end
  local read_config = function(path) return files[path] end

  local learned = rt2_capacity.update(rt2_capacity.new_state(), { turbine(900, 100), turbine(900, 100) })
  local ok = rt2_capacity.save(learned, { path = '/cache', write_config = write_config })
  assert_true(ok, 'save must succeed once ready')

  -- "Reboot": same turbine COUNT, different (irrelevant here) names.
  local reloaded = rt2_capacity.load({ path = '/cache', read_config = read_config, turbine_count = 2 })
  assert_true(reloaded ~= nil, 'a same-count reload must accept the cached value -- renamed peripherals are invisible to this module')
  assert_eq(reloaded.max_output, learned.max_output)

  -- A genuine hardware change (count differs) must reject the cache.
  local rejected = rt2_capacity.load({ path = '/cache', read_config = read_config, turbine_count = 3 })
  assert_true(rejected == nil, 'a turbine count mismatch must reject the cached value')
end

print('rt2_capacity_test.lua: ok')
