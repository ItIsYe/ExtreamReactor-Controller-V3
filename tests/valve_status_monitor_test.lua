package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Status monitor remains presentation-only: green=open, red=blocked, and a
-- missing/failing monitor may never make the actuator operation fail.

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

local function make_instance(monitor_mock)
  local preamble = [[
local current_high = true
local valve_initialized = false
local last_write_error = nil
local last_command_ts = os.epoch("utc")
local config = { sorter_name = "logisticalSorter_1" }
local CONFIG = { LOG_PREFIX = "VALVE" }
local node_id = "VALVE-1"
]]
  local footer = [[
return { apply_valve = apply_valve, get_current_high = function() return current_high end }
]]
  local env = {
    os = { epoch = function() return 1000000 end },
    peripheral = {
      wrap = function() return { setAutoMode = function() end } end,
      find = function(kind)
        if kind ~= 'monitor' or not monitor_mock then return nil end
        return {
          setBackgroundColor = function(color)
            if monitor_mock.fail then error('simulated monitor failure') end
            monitor_mock.colors[#monitor_mock.colors + 1] = color
          end,
          clear = function() end,
        }
      end,
    },
    colors = { orange = 'orange', red = 'red', green = 'green' },
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end },
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type,
    pcall = pcall, error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env
  local fn = assert(load(preamble .. BLOCK_A .. footer, 'valve_status_monitor_test_chunk', 't', env))
  return fn()
end

do
  local inst = make_instance(nil)
  local ok = inst.apply_valve(false)
  assert_true(ok, 'apply_valve must succeed normally when no monitor is attached')
end

do
  local mock = { colors = {} }
  local inst = make_instance(mock)
  inst.apply_valve(false)
  assert_eq(mock.colors[#mock.colors], 'green', 'open valve must render green')
  inst.apply_valve(true)
  assert_eq(mock.colors[#mock.colors], 'red', 'blocked valve must render red')
  local count_before = #mock.colors
  inst.apply_valve(true)
  assert_eq(#mock.colors, count_before, 'unchanged color must not cause redundant monitor write')
end

do
  local mock = { colors = {}, fail = true }
  local inst = make_instance(mock)
  local ok = inst.apply_valve(false)
  assert_true(ok, 'actuator success must not depend on status-monitor success')
  assert_eq(#mock.colors, 0, 'failing monitor write must not record a color')
end

print('valve_status_monitor_test.lua: ok')
