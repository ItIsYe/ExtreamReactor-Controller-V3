package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test for automatic sorter capability discovery. A configured
-- explicit name remains strict and is never silently replaced.

local function read_file(path)
  local f = assert(io.open(path, 'r'))
  local content = f:read('*a')
  f:close()
  return content
end

local function extract(content, start_marker, end_marker)
  local s = content:find(start_marker, 1, true)
  assert(s, 'start marker not found: ' .. start_marker)
  local e = content:find(end_marker, s, true)
  assert(e, 'end marker not found: ' .. end_marker)
  return content:sub(s, e + #end_marker - 1)
end

local SOURCE = read_file('xreactor/nodes/valve/main.lua')
local BLOCK_A = extract(SOURCE, 'local sorter_device = nil',
  '\n-- Fail-safe write at boot before accepting any network command.')
BLOCK_A = BLOCK_A:sub(1, #BLOCK_A - #'\n-- Fail-safe write at boot before accepting any network command.')

local function assert_eq(actual, expected, message)
  if actual ~= expected then error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual)) end
end
local function assert_true(value, message) if not value then error(message or 'assert_true failed') end end

local function make_instance(sorter_name_config, peripherals)
  local preamble = [[
local current_high = false
local valve_initialized = false
local last_write_error = nil
local last_command_ts = os.epoch("utc")
local config = { sorter_name = ]] .. (sorter_name_config and ('"' .. sorter_name_config .. '"') or 'nil') .. [[ }
local CONFIG = { LOG_PREFIX = "VALVE" }
local node_id = "VALVE-1"
]]
  local footer = [[
return {
  apply_valve = apply_valve,
  get_current_high = function() return current_high end,
  get_sorter_resolved_name = function() return sorter_resolved_name end,
  get_last_write_error = function() return last_write_error end,
}
]]
  local env = {
    os = { epoch = function() return 1000000 end },
    peripheral = {
      getNames = function()
        local names = {}; for name in pairs(peripherals) do names[#names + 1] = name end
        table.sort(names); return names
      end,
      getMethods = function(name) local entry = peripherals[name]; return entry and entry.methods or nil end,
      wrap = function(name)
        local entry = peripherals[name]
        if not entry then return nil end
        return { setAutoMode = function(_auto) if entry.ok == false then error('simulated sorter failure') end end }
      end,
    },
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end },
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type,
    pcall = pcall, error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env
  local fn = assert(load(preamble .. BLOCK_A .. footer, 'valve_sorter_autodetect_test_chunk', 't', env))
  return fn()
end

do
  local inst = make_instance(nil, {
    ['monitor_0'] = { methods = { 'setTextScale', 'write' } },
    ['logisticalSorter_3'] = { methods = { 'setAutoMode', 'getInventory' }, ok = true },
  })
  local ok = inst.apply_valve(false)
  assert_true(ok, 'apply_valve should succeed once sorter is auto-detected')
  assert_eq(inst.get_sorter_resolved_name(), 'logisticalSorter_3', 'auto-detected name must be recorded')
  assert_eq(inst.get_current_high(), false, 'valve state must reflect successful open command')
end

do
  local inst = make_instance(nil, { ['monitor_0'] = { methods = { 'setTextScale', 'write' } } })
  local ok = inst.apply_valve(false)
  assert_true(not ok, 'apply_valve must fail cleanly when no sorter can be found')
  assert_true(inst.get_last_write_error() ~= nil, 'failed auto-detect must remain visible')
end

do
  local inst = make_instance('logisticalSorter_configured', {
    ['logisticalSorter_other'] = { methods = { 'setAutoMode' }, ok = true },
  })
  local ok = inst.apply_valve(false)
  assert_true(not ok, 'explicit but absent sorter must not silently fall back')
end

print('valve_sorter_auto_detect_test.lua: ok')
