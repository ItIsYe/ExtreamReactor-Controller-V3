package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local discovery_runtime = require('nodes.rt.discovery_runtime')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local reactors = {
  { id = 'reactor:B', name = 'rb' },
  { id = 'reactor:A', name = 'ra' }
}
local turbines = {
  { id = 'turbine:C', name = 'tc' },
  { id = 'turbine:A', name = 'ta' }
}

local sig = discovery_runtime.build_binding_signature(reactors, turbines)
assert_eq(sig, 'reactor:A|reactor:B|turbine:A|turbine:C', 'signature mismatch')

local normalize_calls = 0
local module_build_calls = 0
local sync_calls = 0

local ctx = {
  config = { reactors = {}, turbines = {} },
  devices = {},
  registry = {
    get_bound_devices = function(_, kind)
      if kind == 'reactor' then return reactors end
      return turbines
    end,
    sync = function() sync_calls = sync_calls + 1 end,
    get_summary = function() return { total = 4 } end,
    state = { load_error = nil }
  },
  build_modules = function() module_build_calls = module_build_calls + 1 end,
}

-- normalize_bindings() hiess bis v816 cache() und legte dabei wrap-Handles
-- und einen Faehigkeiten-Cache an; beides ist entfallen (Selbstheilung
-- Stufe 1). Hier zaehlt nur, WANN sie laeuft.
local original_normalize = discovery_runtime.normalize_bindings
discovery_runtime.normalize_bindings = function(_)
  normalize_calls = normalize_calls + 1
end

discovery_runtime.refresh_bindings(ctx)
assert_eq(normalize_calls, 1, 'normalize_bindings should run on first refresh')
assert_eq(module_build_calls, 1, 'build_modules should run on first refresh')
assert_eq(ctx.config.reactors[1], 'rb', 'reactor names should be copied')
assert_eq(ctx.config.turbines[2], 'ta', 'turbine names should be copied')

-- Same signature should skip expensive refresh path.
discovery_runtime.refresh_bindings(ctx)
assert_eq(normalize_calls, 1, 'normalize_bindings should not rerun when signature unchanged')
assert_eq(module_build_calls, 1, 'build_modules should not rerun when signature unchanged')

-- Mutated signature should trigger refresh again.
ctx.registry.get_bound_devices = function(_, kind)
  if kind == 'reactor' then return { { id = 'reactor:Z', name = 'rz' } } end
  return turbines
end

discovery_runtime.refresh_bindings(ctx)
assert_eq(normalize_calls, 2, 'normalize_bindings should rerun when signature changes')
assert_eq(module_build_calls, 2, 'build_modules should rerun when signature changes')

-- avoid luacheck unused warning and verify no hidden interactions
assert_eq(sync_calls, 0, 'refresh_bindings must not sync registry directly')

discovery_runtime.normalize_bindings = original_normalize

print('rt_discovery_runtime_test.lua: ok')
