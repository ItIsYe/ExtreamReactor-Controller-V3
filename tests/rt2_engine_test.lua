package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- fs/textutils stand-ins for core.utils.load_config/write_config (used by
-- rt2_engine's capacity-cache persistence) -- same minimal fake as
-- registry_dirty_test.lua/rt_capacity_cache_persistence_regression_test.lua.
local files = { ['/xreactor_config'] = '<dir>' }
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function() return '/xreactor_config' end,
  makeDir = function(p) files[p] = '<dir>' end,
  delete = function(p) files[p] = nil end,
  move = function(src, dst) files[dst] = files[src]; files[src] = nil end,
  open = function(p, mode)
    if mode == 'w' then
      local buffer = ''
      return { write = function(v) buffer = buffer .. tostring(v) end, close = function() files[p] = buffer end }
    elseif mode == 'r' then
      if files[p] == nil or files[p] == '<dir>' then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
}
_G.textutils = {
  serialize = function(value)
    local function encode(v)
      if type(v) == 'string' then return string.format('%q', v) end
      if type(v) == 'number' or type(v) == 'boolean' then return tostring(v) end
      if type(v) ~= 'table' then return 'nil' end
      local parts = {}
      for k, item in pairs(v) do parts[#parts + 1] = '[' .. encode(k) .. ']=' .. encode(item) end
      table.sort(parts)
      return '{' .. table.concat(parts, ',') .. '}'
    end
    return encode(value)
  end,
  unserialize = function(content)
    local loader = load('return ' .. content, '=cache', 't', {})
    if not loader then return nil end
    local ok, value = pcall(loader)
    return ok and value or nil
  end,
}

local rt2_engine = require('nodes.rt.rt2_engine')
local rt2_state = require('nodes.rt.rt2_state')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- Fake adapters standing in for adapters/turbine.lua / adapters/reactor.lua --
-- plain functions, no CC:Tweaked globals, matching the dependency-
-- injection style rt2_adapter_test.lua already established.
local turbine_hardware = {
  T1 = { rpm = 900, energy = 100, coil_engaged = true, flow = 4000, active = true },
}
local reactor_hardware = {
  R1 = { steam_fill_ratio = 0.5, control_rod_level = 80, active = true },
}
local applied_flow, applied_coil, applied_rods, applied_active, applied_turbine_active = {}, {}, nil, nil, {}

local fake_ctx = {
  config = { turbines = { 'T1' }, reactors = { 'R1' } },
  CONFIG = { LOG_PREFIX = 'RT' },
  log = function() end,
  adapters = {
    turbine = {
      inspect = function(name) return turbine_hardware[name] end,
      set_flow = function(name, value) applied_flow[name] = value; return true end,
      set_coils = function(name, engaged) applied_coil[name] = engaged; return true end,
      set_active = function(name, enabled) applied_turbine_active[name] = enabled; return true end,
    },
    reactor = {
      inspect = function(name) return reactor_hardware[name] end,
      apply_rod_level = function(name, level) applied_rods = level; return true end,
      set_active = function(name, enabled) applied_active = enabled; return true end,
    },
  },
}

rt2_engine.init({})

-- A tick before capacity is learned must run LEARNING, targeting the
-- fixed RPM and writing that target through to the fake hardware.
local result = rt2_engine.tick(fake_ctx)
assert_eq(result.state, rt2_state.states.LEARNING, 'first tick with fresh hardware must enter LEARNING')
assert_eq(result.turbines[1].target_rpm, 900, 'LEARNING targets the fixed RPM')
-- T1 is already at 900/coil engaged -- inside the band, so flow holds
-- near its current reading rather than the readout getting clobbered.
assert_true(applied_flow.T1 ~= nil, 'the flow decision must have been written to the fake turbine adapter')
assert_true(applied_coil.T1 == true, 'the coil decision must have been written to the fake turbine adapter')
assert_true(applied_rods ~= nil, 'the rod decision must have been written to the fake reactor adapter')
assert_true(applied_active == nil, 'a reactor already reading active=true must not trigger a set_active write')
assert_true(applied_turbine_active.T1 == nil, 'a turbine already reading active=true must not trigger a set_active write')

-- A reactor/turbine reading active=false must be turned back on through
-- the same full adapter chain (rt2_engine -> rt2_adapter -> the fake
-- adapter's set_active), not just decided and dropped.
reactor_hardware.R1.active = false
turbine_hardware.T1.active = false
result = rt2_engine.tick(fake_ctx)
assert_eq(applied_active, true, 'a reactor reading active=false must be turned on via set_active(name, true, ...)')
assert_eq(applied_turbine_active.T1, true, 'a turbine reading active=false must be turned on via set_active(name, true, ...)')
reactor_hardware.R1.active = true
turbine_hardware.T1.active = true
applied_active = nil

-- status_fields() must reflect the last tick without re-reading hardware.
local fields = rt2_engine.status_fields()
assert_eq(fields.mode, result.state)
assert_eq(fields.turbines[1].id, 'T1')

-- Capacity diagnostics (at_target/total_turbines/reason) must be exposed
-- through status_fields() so a stuck LEARNING phase is visible without
-- reading Lua state directly -- this is what surfaced the "capacity
-- never becomes ready although RPM looks fine" report.
do
  local stuck_turbine_hardware = { T2 = { rpm = 500, energy = 0, coil_engaged = false, flow = 4000, active = true } }
  local stuck_ctx = {
    config = { turbines = { 'T2' }, reactors = { 'R1' } },
    CONFIG = { LOG_PREFIX = 'RT' },
    log = function() end,
    adapters = {
      turbine = {
        inspect = function(name) return stuck_turbine_hardware[name] end,
        set_flow = function() return true end,
        set_coils = function() return true end,
        set_active = function() return true end,
      },
      reactor = fake_ctx.adapters.reactor,
    },
  }
  -- A fresh, isolated cache path -- the default path already holds a
  -- saved cache from the earlier tests in this file (T1 reached ready),
  -- and reusing it here would load that stale value instead of exercising
  -- a genuinely fresh, not-yet-ready capacity state.
  rt2_engine.init({ cache_path = '/xreactor_config/rt2_capacity_cache_stuck_test.lua', turbine_count = 1 })
  rt2_engine.tick(stuck_ctx)
  local stuck_fields = rt2_engine.status_fields()
  assert_eq(stuck_fields.capacity_ready, false, 'a turbine far from target RPM must not be ready')
  assert_eq(stuck_fields.capacity_at_target, 0, 'a turbine far from target RPM must not count as at_target')
  assert_eq(stuck_fields.capacity_total_turbines, 1)
  assert_true(stuck_fields.capacity_reason ~= nil, 'a not-ready capacity state must always carry a diagnostic reason')
end

-- handle_command() must reach the underlying orchestrator and its
-- effects must show up on the next tick.
local ack = rt2_engine.handle_command({ target = 'SCRAM' })
assert_true(ack.ok, 'SCRAM must be accepted through the engine facade')
result = rt2_engine.tick(fake_ctx)
assert_eq(result.state, rt2_state.states.SAFE, 'a SCRAM issued through the engine facade must force SAFE on the next tick')
assert_eq(applied_rods, 100, 'SAFE must have written full rod insertion to the fake reactor adapter')

-- Capacity-cache persistence: a fresh init() + a tick that reaches ready
-- must write the cache file, and a second init() with a matching
-- turbine_count must load it back and skip relearning (state goes
-- straight past LEARNING instead of re-measuring from zero).
local cache_path = '/xreactor_config/rt2_capacity_cache_test.lua'
files[cache_path] = nil

rt2_engine.init({ cache_path = cache_path, turbine_count = 1 })
applied_flow, applied_coil, applied_rods = {}, {}, nil
result = rt2_engine.tick(fake_ctx)
assert_true(result.capacity.ready, 'a single turbine already at target rpm must be ready after one tick')
assert_true(files[cache_path] ~= nil, 'a ready capacity measurement must be persisted to the cache file')

-- INIT always spends its first tick becoming LEARNING (rt2_state.lua's
-- INIT branch does not look at capacity_ready), but with a cache already
-- loaded the very next tick must leave LEARNING immediately instead of
-- needing to remeasure from zero.
rt2_engine.init({ cache_path = cache_path, turbine_count = 1 })
result = rt2_engine.tick(fake_ctx)
assert_true(result.capacity.ready, 'a fresh engine loading a matching cache must start already ready, not relearning')
result = rt2_engine.tick(fake_ctx)
assert_true(result.state ~= rt2_state.states.LEARNING, 'loading a valid cache must leave LEARNING on the second tick without remeasuring')

print('rt2_engine_test.lua: ok')
