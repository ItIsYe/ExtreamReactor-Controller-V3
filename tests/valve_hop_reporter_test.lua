package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
-- nodes/valve/hop_reporter.lua: opt-in, read-only chest sensor. Must stay
-- disabled unless hop_chest is a real, wrappable inventory peripheral, and
-- must aggregate multi-slot stacks of the same item into one total.

local hop_reporter = require('nodes.valve.hop_reporter')

-- 1) No hop_chest configured: disabled, scan() returns nil.
do
  local r = hop_reporter.new({ hop_chest = nil, peripheral_api = {
    isPresent = function() return true end,
    wrap = function() return { list = function() return {} end } end,
  } })
  assert(r:is_enabled() == false)
  assert(r:scan() == nil)
end

-- 2) Configured but not present: disabled, no crash.
do
  local r = hop_reporter.new({ hop_chest = 'minecraft:chest_5', peripheral_api = {
    isPresent = function() return false end,
    wrap = function() error('must not wrap an absent peripheral') end,
  } })
  assert(r:is_enabled() == false)
end

-- 3) Configured, present, wrappable, but wrapped object has no list()
--    (wrong block type, e.g. the sorter itself): disabled.
do
  local r = hop_reporter.new({ hop_chest = 'minecraft:chest_5', peripheral_api = {
    isPresent = function() return true end,
    wrap = function() return {} end,
  } })
  assert(r:is_enabled() == false)
end

-- 4) Present + wrappable inventory: enabled, scan() aggregates slots by
--    item name (multiple stacks of the same item across slots must sum).
do
  local slots = {
    [1] = { name = 'minecraft:uranium_ingot', count = 32 },
    [5] = { name = 'minecraft:uranium_ingot', count = 16 },
    [9] = { name = 'minecraft:blutonium_ingot', count = 4 },
  }
  local r = hop_reporter.new({ hop_chest = 'minecraft:chest_5', peripheral_api = {
    isPresent = function() return true end,
    wrap = function() return { list = function() return slots end } end,
  } })
  assert(r:is_enabled() == true)
  local items = r:scan()
  assert(items['minecraft:uranium_ingot'] == 48)
  assert(items['minecraft:blutonium_ingot'] == 4)
end

-- 5) A failing list() call (peripheral detached mid-game) returns nil
--    instead of propagating an error.
do
  local r = hop_reporter.new({ hop_chest = 'minecraft:chest_5', peripheral_api = {
    isPresent = function() return true end,
    wrap = function() return { list = function() error('detached') end } end,
  } })
  assert(r:is_enabled() == true)
  assert(r:scan() == nil)
end

print('valve_hop_reporter_test.lua: ok')
