package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Drives the real extracted VALVE actuator/command logic. A transaction-id
-- retry may be deduped logically, but its ACK must still be based on a fresh
-- physical sorter write rather than a cached RAM state.

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
local BLOCK_B = extract(SOURCE, 'local SEEN_COMMAND_LIMIT = 16',
  '\nlocal comms = comms_service.new({')
BLOCK_B = BLOCK_B:sub(1, #BLOCK_B - #'\nlocal comms = comms_service.new({')
local EXTRACTED = BLOCK_A .. '\n' .. BLOCK_B

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end
local function assert_true(value, message) if not value then error(message or 'assert_true failed') end end

local function make_instance(write_ok_ref, opts)
  opts = opts or {}
  local clock = opts.clock or 1000000
  local log_lines = {}
  local write_count = 0

  local preamble = [[
local current_high = ]] .. tostring(opts.default_blocked ~= false) .. [[

local valve_initialized = false
local last_write_error = nil
local last_command_ts = os.epoch("utc")
local config = { sorter_name = "logisticalSorter_1", trusted_source = "FUEL-1" }
local CONFIG = { LOG_PREFIX = "VALVE", CONFIG_PATH = "/xreactor/config/valve.lua" }
local node_id = "VALVE-1"
local valve_auth_secret = "test-secret-123456"
]]

  local footer = [[
return {
  apply_valve = apply_valve,
  handle_valve_channel_event = handle_valve_channel_event,
  get_current_high = function() return current_high end,
  get_valve_initialized = function() return valve_initialized end,
  get_last_command_ts = function() return last_command_ts end,
  get_last_write_error = function() return last_write_error end,
  seen_command_ids = seen_command_ids,
}
]]

  local env = {
    os = { epoch = function() return clock end },
    peripheral = {
      wrap = function(_name)
        return {
          setAutoMode = function(_auto)
            write_count = write_count + 1
            if not write_ok_ref() then error('simulated sorter write failure') end
          end,
        }
      end,
    },
    constants = { channels = { VALVE = 6504 } },
    utils = {
      log = function(_prefix, msg, level) table.insert(log_lines, { msg = msg, level = level }) end,
      write_config = function() return true end,
      load_config = function() return {} end,
    },
    protocol = {
      valve_auth_value = function(message) return message end,
      verify_value = function() return true end,
      sign_value = function() return "test-mac" end,
    },
    colors = { orange = 1, red = 2, green = 3 },
    string = string, table = table, math = math, tostring = tostring, tonumber = tonumber, type = type,
    pcall = pcall, error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env
  local fn = assert(load(preamble .. EXTRACTED .. footer, 'valve_test_chunk', 't', env))
  local instance = fn()
  instance.log_lines = log_lines
  instance.set_clock = function(v) clock = v end
  instance.get_write_count = function() return write_count end
  return instance
end

-- 1. A failed write is not remembered; retry with the SAME command_id must
-- perform another physical write and can then succeed.
do
  local write_ok = false
  local inst = make_instance(function() return write_ok end, { default_blocked = false })
  local event = { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-1',
      high = true, ts = 1000000, auth = { algorithm = 'HMAC-SHA256', mac = 'test-mac' } } }

  inst.handle_valve_channel_event(event)
  assert_eq(inst.get_current_high(), false, 'failed write must not change current_high')
  assert_true(not inst.seen_command_ids['CMD-1'], 'failed command must not be remembered')
  assert_eq(inst.get_write_count(), 1, 'first command must make one physical write attempt')

  write_ok = true
  inst.handle_valve_channel_event(event)
  assert_eq(inst.get_current_high(), true, 'same command-id retry must really write and succeed')
  assert_true(inst.seen_command_ids['CMD-1'] == true, 'command is remembered only after success')
  assert_eq(inst.get_write_count(), 2, 'retry must perform a second physical write')
end

-- 2. A duplicate SUCCESS is logically deduped but physically re-proven. This
-- protects against an externally changed/reset sorter between ACK retries.
do
  local inst = make_instance(function() return true end)
  local event = { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-2',
      high = true, ts = 1000000, auth = { algorithm = 'HMAC-SHA256', mac = 'test-mac' } } }

  inst.handle_valve_channel_event(event)
  assert_true(inst.seen_command_ids['CMD-2'] == true, 'successful command should be remembered')
  assert_eq(inst.get_write_count(), 1, 'first success should write once')
  local first_ts = inst.get_last_command_ts()

  inst.set_clock(first_ts + 5000)
  event[5].ts = first_ts + 5000
  inst.handle_valve_channel_event(event)
  assert_eq(inst.get_write_count(), 2,
    'duplicate successful command must force fresh physical proof before re-ACK')
  assert_eq(inst.get_last_command_ts(), first_ts + 5000,
    'successful physical reproof refreshes last confirmed command timestamp')
end

-- 3. A new transaction requesting the same logical state must also prove the
-- hardware again; its new ACK gates a different router transaction.
do
  local inst = make_instance(function() return true end)
  local first = { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-NEW-1',
      high = true, ts = 1000000, auth = { algorithm = 'HMAC-SHA256', mac = 'test-mac' } } }
  inst.handle_valve_channel_event(first)
  assert_eq(inst.get_write_count(), 1, 'first transaction must physically write')

  inst.set_clock(1001000)
  local second = { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-NEW-2',
      high = true, ts = 1001000, auth = { algorithm = 'HMAC-SHA256', mac = 'test-mac' } } }
  inst.handle_valve_channel_event(second)
  assert_eq(inst.get_write_count(), 2,
    'new command-id with unchanged desired state must force fresh physical proof')
end

-- 4. Failed safety-critical write must not extend the grace period.
do
  local write_ok = true
  local inst = make_instance(function() return write_ok end, { default_blocked = false })
  local baseline_ts = inst.get_last_command_ts()
  inst.set_clock(baseline_ts + 1000)
  write_ok = false
  local event = { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-3',
      high = true, ts = baseline_ts + 1000,
      auth = { algorithm = 'HMAC-SHA256', mac = 'test-mac' } } }
  inst.handle_valve_channel_event(event)
  assert_eq(inst.get_current_high(), false, 'failed block attempt must not change current_high')
  assert_eq(inst.get_last_command_ts(), baseline_ts, 'failed write must not reset last_command_ts')
  assert_true(inst.get_last_write_error() ~= nil, 'failure should remain visible via last_write_error')
end

print('valve_failed_write_retry_test.lua: ok')
