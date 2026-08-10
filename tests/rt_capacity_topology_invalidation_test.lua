package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local learning = require('nodes.rt.capacity_learning')
local ctx = { capacity_learning = learning.new_state(), log = function() end }
local function turbine(id, energy)
  return { id = id, name = id, rpm = 900, energy = energy, coil_engaged = true }
end

local first = learning.update(ctx, { turbine('T1', 100), turbine('T2', 100) })
assert(first.ready == true and first.max_output == 200, 'initial topology should learn 200 output')
local generation = first.topology_generation

-- One turbine disappears permanently. The old 200 value must not survive; the
-- new one-turbine topology is measured independently as 100.
local second = learning.update(ctx, { turbine('T1', 100) })
assert(second.topology_generation == generation + 1, 'topology generation must increment after removal')
assert(second.topology_signature == 'T1', 'new topology signature must reflect the remaining turbine')
assert(second.ready == true and second.max_output == 100, 'removed turbine must invalidate the stale historical peak')

-- A non-topology performance dip must keep the existing learned maximum.
local third = learning.update(ctx, { turbine('T1', 80) })
assert(third.topology_generation == second.topology_generation, 'same topology must not create a new generation')
assert(third.max_output == 100, 'transient lower output on same topology must not reduce learned maximum')
print('rt_capacity_topology_invalidation_test.lua: ok')
