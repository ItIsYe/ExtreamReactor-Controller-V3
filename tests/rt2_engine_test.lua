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
  T1 = { rpm = 900, energy = 100, coil_engaged = true, flow = 4000 },
}
local reactor_hardware = {
  R1 = { steam_fill_ratio = 0.5, control_rod_level = 50 },
}
local applied_flow, applied_coil, applied_rods = {}, {}, nil

local fake_ctx = {
  config = { turbines = { 'T1' }, reactors = { 'R1' } },
  CONFIG = { LOG_PREFIX = 'RT' },
  log = function() end,
  adapters = {
    turbine = {
      inspect = function(name) return turbine_hardware[name] end,
      set_flow = function(name, value) applied_flow[name] = value; return true end,
      set_coils = function(name, engaged) applied_coil[name] = engaged; return true end,
    },
    reactor = {
      inspect = function(name) return reactor_hardware[name] end,
      apply_rod_level = function(name, level) applied_rods = level; return true end,
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

-- status_fields() must reflect the last tick without re-reading hardware.
local fields = rt2_engine.status_fields()
assert_eq(fields.mode, result.state)
assert_eq(fields.turbines[1].id, 'T1')

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
