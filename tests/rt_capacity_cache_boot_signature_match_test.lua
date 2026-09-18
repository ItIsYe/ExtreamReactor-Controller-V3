package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (production log 2026-09-18, disk6.zip): every single RT
-- restart logged "Capacity cache rejected: hardware topology changed" and
-- MASTER then reported "Profile ... base power is unavailable; target
-- unchanged at 0.00" until capacity_learning fully relearned from zero --
-- even though the physical turbine set never actually changed between
-- boots.
--
-- Root cause: main.lua's load_capacity_cache() built its boot-time
-- topology_signature from config.turbines -- plain name strings, no .id
-- field. capacity_learning.M.update() (called every status tick via
-- status_snapshot.lua) builds the SAME signature from the registry-bound
-- turbine entries, which always carry a .id (the hashed device key from
-- core/registry.lua) -- and M.topology_signature() prefers turbine.id over
-- turbine.name. Boot-time and runtime signatures were therefore computed
-- from two structurally different identity bases and could never match,
-- so the persisted cache was discarded unconditionally on every boot.
--
-- Fix: load_capacity_cache() (and save_capacity_cache()'s turbine_count)
-- now build the topology from devices.turbines -- the same registry
-- entries (id + name) that capacity_learning.M.update() uses at runtime.
--
-- main.lua is a boot script (runs parallel.waitForAny() unconditionally),
-- so it cannot be require()'d in a test process. This asserts against the
-- fixed source text (same pattern as rt_main_state_context_guard_test.lua)
-- and proves the underlying mismatch functionally at the capacity_cache/
-- capacity_learning level, using the same fs/textutils sim as
-- rt_capacity_cache_persistence_regression_test.lua.

local files = { ['/xreactor'] = '<dir>', ['/xreactor/config'] = '<dir>' }
local function serialize(value)
  if type(value) == 'string' then return string.format('%q', value) end
  if type(value) == 'number' or type(value) == 'boolean' then return tostring(value) end
  if type(value) ~= 'table' then return 'nil' end
  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = '[' .. serialize(key) .. ']=' .. serialize(item)
  end
  table.sort(parts)
  return '{' .. table.concat(parts, ',') .. '}'
end
_G.textutils = {
  serialize = serialize,
  unserialize = function(content)
    local loader = load('return ' .. content, '=capacity_cache', 't', {})
    if not loader then return nil end
    local ok, value = pcall(loader)
    return ok and value or nil
  end,
}
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function() return '/xreactor/config' end,
  makeDir = function(p) files[p] = '<dir>' end,
  delete = function(p) files[p] = nil end,
  move = function(src, dst)
    if files[src] == nil then error('missing source ' .. tostring(src), 0) end
    files[dst] = files[src]; files[src] = nil
  end,
  open = function(p, mode)
    if mode == 'w' then
      local buffer = ''
      return { write = function(v) buffer = buffer .. tostring(v) end,
        close = function() files[p] = buffer end }
    elseif mode == 'r' then
      if files[p] == nil or files[p] == '<dir>' then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
}
local native_dofile = dofile
_G.dofile = function(p)
  if files[p] ~= nil then
    local loader, lerr = load(files[p], '=' .. p, 't', {})
    if not loader then error(lerr, 0) end
    return loader()
  end
  return native_dofile(p)
end

package.loaded['nodes.rt.capacity_cache'] = nil
package.loaded['nodes.rt.capacity_learning'] = nil
local capacity_cache = require('nodes.rt.capacity_cache')
local capacity_learning = require('nodes.rt.capacity_learning')

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- 1) Source-text guard: load_capacity_cache()/save_capacity_cache() must no
-- longer build their topology/turbine_count from config.turbines.
local handle = assert(io.open('xreactor/nodes/rt/main.lua', 'r'))
local content = handle:read('*a')
handle:close()

local load_start = content:find('local function load_capacity_cache%(%)')
assert_true(load_start, 'load_capacity_cache() not found in main.lua')
local load_end = content:find('\nend\n', load_start, true)
local load_body = content:sub(load_start, load_end)
assert_true(load_body:find('devices%.turbines'),
  'load_capacity_cache() must build its boot-time topology from devices.turbines (the registry-bound entries), not config.turbines')
assert_true(not load_body:find('config%.turbines'),
  'load_capacity_cache() must no longer read config.turbines -- that only carries plain names, no .id, and can never match the runtime signature')

-- 2) Functional proof: a topology built the OLD way (name-only, no .id --
-- what config.turbines produced) and the NEW way (id+name, what
-- devices.turbines/the registry produces) yield DIFFERENT signatures for
-- the exact same physical turbines -- this is exactly why the old code
-- could never match a cache saved from real runtime data.
local registry_style_turbines = {
  { id = 'TURBINE-aaaa1111', name = 'BigReactors-Turbine_244' },
  { id = 'TURBINE-bbbb2222', name = 'BigReactors-Turbine_248' },
}
local name_only_topology = {}
for _, t in ipairs(registry_style_turbines) do
  name_only_topology[#name_only_topology + 1] = { name = t.name }
end

local old_boot_signature = capacity_learning.topology_signature(name_only_topology)
local runtime_signature = capacity_learning.topology_signature(registry_style_turbines)
assert_true(old_boot_signature ~= runtime_signature,
  'name-only (old boot-time) and id-based (runtime) signatures must differ for the same turbines -- '
  .. 'this mismatch is exactly what caused the cache to be rejected on every single boot')

-- 3) Round-trip proof: a cache saved with the runtime (id-based) signature
-- must be ACCEPTED when reloaded with a boot-time topology built the FIXED
-- way (id+name from devices.turbines-style entries) -- not rejected.
local path = '/xreactor/config/rt_capacity_cache.lua'
local learning = capacity_learning.new_state()
learning.ready = true
learning.max_output = 12345
learning.topology_signature = runtime_signature
local saved, save_err = capacity_cache.save(learning, { path = path, turbine_count = #registry_style_turbines })
assert_true(saved, 'capacity_cache.save() must succeed: ' .. tostring(save_err))

local fixed_boot_topology = {}
for _, t in ipairs(registry_style_turbines) do
  fixed_boot_topology[#fixed_boot_topology + 1] = { id = t.id, name = t.name }
end
local loaded = capacity_cache.load({
  path = path,
  topology_signature = capacity_learning.topology_signature(fixed_boot_topology),
  log = function() end,
})
assert_true(loaded ~= nil, 'a cache saved with the runtime (id-based) signature must be accepted when reloaded with the fixed (id-based) boot-time signature')
assert_true(loaded.max_output == 12345, 'the loaded cache must carry through the previously learned max_output')

-- ...and the OLD (name-only) boot-time signature would have rejected the
-- exact same cache -- proving the bug this fix closes.
local rejected = capacity_cache.load({
  path = path,
  topology_signature = old_boot_signature,
  log = function() end,
})
assert_true(rejected == nil, 'the old name-only boot-time signature must reject a cache saved with the id-based runtime signature -- this was the bug')

_G.dofile = native_dofile

print('rt_capacity_cache_boot_signature_match_test.lua: ok')
