package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local files = {}
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function() return '/xreactor/config' end,
  makeDir = function() end,
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
      if files[p] == nil then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
}

package.loaded['nodes.rt.capacity_cache'] = nil
package.loaded['nodes.rt.capacity_learning'] = nil
local cache = require('nodes.rt.capacity_cache')
local learning = require('nodes.rt.capacity_learning')
local path = '/xreactor/config/rt_capacity_cache.lua'

local state = {
  ready = true, max_output = 1234, reason = 'MEASURED',
  topology_signature = 'turbine-A|turbine-B', topology_generation = 7,
  topology_changed_at = 555,
}
local ok, err = cache.save(state, { path = path, turbine_count = 2 })
if ok ~= true then error('capacity cache save failed: ' .. tostring(err)) end
if not tostring(files[path]):find('topology_signature', 1, true) then
  error('capacity cache must persist topology_signature')
end

local native_dofile = dofile
_G.dofile = function(p)
  if files[p] ~= nil then
    local loader, lerr = load(files[p], '=' .. p, 't', {})
    if not loader then error(lerr, 0) end
    return loader()
  end
  return native_dofile(p)
end
local loaded = cache.load({ path = path, turbine_count = 2 })
_G.dofile = native_dofile
if not loaded or loaded.topology_signature ~= state.topology_signature
    or loaded.topology_generation ~= state.topology_generation then
  error('saved topology identity must survive cache reload')
end

-- Copy-on-write: normal increase must leave previous committed table unchanged
-- so RT main can observe new > previous and persist it.
local previous = {
  ready = true, max_output = 100, at_target = 1, total_turbines = 1,
  reason = 'STABLE', topology_signature = 't1', topology_generation = 1,
}
local ctx = { capacity_learning = previous, log = function() end }
local updated = learning.update(ctx, {
  { id = 't1', rpm = 900, energy = 120, coil_engaged = true }
})
if updated == previous then error('capacity update must be copy-on-write') end
if previous.max_output ~= 100 or updated.max_output ~= 120 then
  error('previous/new capacity values must remain distinguishable for persistence')
end

-- Topology change with LOWER capacity still needs persistence. The old
-- comparison baseline is intentionally invalidated to 0 until the new layout
-- produces its first valid measurement.
previous = {
  ready = true, max_output = 100, at_target = 1, total_turbines = 1,
  reason = 'STABLE', topology_signature = 'old-turbine', topology_generation = 1,
}
ctx = { capacity_learning = previous, log = function() end }
updated = learning.update(ctx, {
  { id = 'new-turbine', rpm = 900, energy = 80, coil_engaged = true }
})
if previous.max_output ~= 0 then error('old topology baseline must be invalidated for lower-capacity persistence') end
if updated.ready ~= true or updated.max_output ~= 80 then error('new lower topology measurement should become ready') end
if updated.topology_signature ~= 'new-turbine' then error('new topology signature must be recorded') end

print('rt_capacity_cache_persistence_regression_test.lua: ok')
