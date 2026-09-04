package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test for the ME Bridge reserve tracking fix (nodes/fuel/
-- storage.lua). Before this fix, storage_bus discovery/read only looked
-- for tanks()/getFluidAmount() -- methods a dedicated fluid-tank block
-- has, but the real Advanced Peripherals ME Bridge does NOT expose. A
-- FUEL node with an ME Bridge configured as storage_bus therefore always
-- read a reserve of 0, even with a correctly wired and named bridge.
-- Real-world reserve is item-based (Uranium/Blutonium ingots+blocks in
-- the ME system), read via getItem({name=...}) and summed per
-- config.reserve_items (with unit_multiplier for e.g. blocks).

local storage = require('nodes.fuel.storage')
local support_runtime = require('nodes.support.runtime')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function noop_warn_once() end

local function make_devices(bus_name)
  return { storage_name = bus_name }
end

local utils = { safe_wrap = function(name) return _G.__test_wrapped[name] end, log = function() end }

-- 1. ME Bridge (getItem-based): sums configured items, applying
--    unit_multiplier for the uranium block.
do
  local calls = {}
  _G.__test_wrapped = {
    me_bridge_3 = {
      getItem = function(filter)
        calls[#calls + 1] = filter.name
        local amounts = {
          ['bigreactors:blutonium_ingot'] = 500,
          ['alltheores:uranium_ingot'] = 300,
          ['alltheores:uranium_block'] = 20, -- x9 => 180
        }
        return { name = filter.name, amount = amounts[filter.name] or 0 }
      end,
    },
  }
  _G.peripheral = { isPresent = function(name) return name == 'me_bridge_3' end }

  local devices = make_devices('me_bridge_3')
  storage.refresh(devices, utils)

  local config = {
    reserve_items = {
      { item = 'bigreactors:blutonium_ingot' },
      { item = 'alltheores:uranium_ingot' },
      { item = 'alltheores:uranium_block', unit_multiplier = 9 },
    },
  }
  local total = storage.read_fuel(config, noop_warn_once, support_runtime)
  assert_eq(total, 500 + 300 + 180, 'reserve must sum all configured ME items with unit_multiplier applied')
  assert_eq(#calls, 3, 'getItem must be queried once per configured reserve item')
end

-- 2. A dedicated fluid tank (no getItem) must still work via the legacy
--    tanks() path -- the ME Bridge fix must not break this.
do
  _G.__test_wrapped = {
    tank_0 = {
      tanks = function() return { { amount = 750 }, { amount = 250 } } end,
    },
  }
  _G.peripheral = { isPresent = function(name) return name == 'tank_0' end }

  local devices = make_devices('tank_0')
  storage.refresh(devices, utils)
  local total = storage.read_fuel({ reserve_items = {} }, noop_warn_once, support_runtime)
  assert_eq(total, 1000, 'fluid-tank fallback via tanks() must still work when the bridge has no getItem')
end

-- 3. ME Bridge present but reserve_items misconfigured (empty/missing)
--    must fall through to 0, not error out.
do
  _G.__test_wrapped = {
    me_bridge_3 = {
      getItem = function() error('must not be called when reserve_items is empty') end,
    },
  }
  _G.peripheral = { isPresent = function(name) return name == 'me_bridge_3' end }

  local devices = make_devices('me_bridge_3')
  storage.refresh(devices, utils)
  local total = storage.read_fuel({}, noop_warn_once, support_runtime)
  assert_eq(total, 0, 'no reserve_items configured must yield 0, not a crash')
end

print('fuel_storage_me_bridge_reserve_test.lua: ok')
