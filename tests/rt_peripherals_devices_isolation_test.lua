-- Regression test for the RT ctx.peripherals/ctx.devices aliasing bug:
-- nodes/rt/main.lua used to build ctx.peripherals and ctx.devices from the
-- SAME table. discovery_runtime.M.cache() writes ctx.peripherals.reactors/
-- .turbines as a name->wrapped-peripheral map, which silently overwrote
-- ctx.devices.reactors/.turbines (the registry entry list every ipairs()
-- consumer -- monitor_ui.lua, state_handlers.lua, M.build_modules() --
-- expects) whenever the two were the same table. This test exercises the
-- REAL M.refresh_bindings()/M.cache() (unlike rt_discovery_runtime_test.lua,
-- which stubs M.cache out) and asserts ctx.devices.reactors/.turbines stay
-- an ipairs-able entry list, and ctx.peripherals stays a separate table.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Minimal CC:Tweaked `peripheral` global for normalize_bound_names().
peripheral = {
  getMethods = function(name) return { "x" } end,
  getType = function(name)
    if name:find("reactor", 1, true) then return "BiggerReactors_Reactor" end
    return "BiggerReactors_Turbine"
  end,
}

local discovery_runtime = require('nodes.rt.discovery_runtime')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local reactor_entries = { { id = 'REACTOR-1', name = 'reactor_0', kind = 'reactor', bound = true } }
local turbine_entries = {
  { id = 'TURBINE-1', name = 'turbine_0', kind = 'turbine', bound = true },
  { id = 'TURBINE-2', name = 'turbine_1', kind = 'turbine', bound = true },
}

-- ctx.devices and ctx.peripherals are DELIBERATELY two distinct tables here
-- (mirroring the fixed main.lua), not the same object.
local devices = { reactors = {}, turbines = {} }
local peripherals = { reactors = {}, turbines = {} }

local ctx = {
  config = { reactors = {}, turbines = {} },
  devices = devices,
  peripherals = peripherals,
  utils = {
    cache_peripherals = function(names)
      local out = {}
      for _, name in ipairs(names or {}) do
        out[name] = { wrapped = name }
      end
      return out
    end,
  },
  capability_cache = { reactors = {}, turbines = {} },
  build_capabilities = function(name) return {} end,
  binding = {
    detect_kind = function(type_name, _method_set)
      if type_name == "BiggerReactors_Reactor" then return "reactor" end
      return "turbine"
    end,
  },
  log = function() end,
  registry = {
    get_bound_devices = function(_, kind)
      if kind == 'reactor' then return reactor_entries end
      return turbine_entries
    end,
  },
  build_modules = function() end,
  refresh_module_peripherals = function() end,
}

discovery_runtime.refresh_bindings(ctx)

-- ctx.devices.reactors/.turbines must stay the ipairs-able registry entry
-- list -- this is what broke when ctx.peripherals was the same table.
assert_eq(#devices.reactors, 1, 'devices.reactors must still be the entry list')
assert_eq(devices.reactors[1].id, 'REACTOR-1', 'devices.reactors entries must keep their id')
assert_eq(#devices.turbines, 2, 'devices.turbines must still be the entry list')
assert_eq(devices.turbines[2].id, 'TURBINE-2', 'devices.turbines entries must keep their id')

-- ctx.peripherals.reactors/.turbines must hold the name-keyed wrapped map,
-- and must NOT have clobbered ctx.devices.
assert_eq(peripherals.reactors.reactor_0.wrapped, 'reactor_0', 'peripherals.reactors must hold the wrapped map')
assert_eq(peripherals.turbines.turbine_0.wrapped, 'turbine_0', 'peripherals.turbines must hold the wrapped map')
assert_eq(devices.reactors.reactor_0, nil, 'devices.reactors must not be aliased to the peripheral map')
assert_eq(devices.turbines.turbine_0, nil, 'devices.turbines must not be aliased to the peripheral map')

print('rt_peripherals_devices_isolation_test.lua: ok')
