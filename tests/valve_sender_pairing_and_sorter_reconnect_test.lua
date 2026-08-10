package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Covers durable first-sender pairing and sorter re-wrap after an actuator
-- call failure using the real extracted VALVE implementation.

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

local function make_pairing_instance(opts)
  opts = opts or {}
  local log_lines = {}
  local write_config_calls = {}

  local preamble = [[
local current_high = true
local valve_initialized = false
local last_write_error = nil
local last_command_ts = os.epoch("utc")
local config = { sorter_name = "logisticalSorter_1", trusted_source = ]] .. (opts.initial_trusted_source and ('"' .. opts.initial_trusted_source .. '"') or 'nil') .. [[ }
local CONFIG = { LOG_PREFIX = "VALVE", CONFIG_PATH = "/xreactor/config/valve.lua" }
local node_id = "VALVE-1"
]]
  local footer = [[
return {
  handle_valve_channel_event = handle_valve_channel_event,
  get_current_high = function() return current_high end,
  get_trusted_source = function() return config.trusted_source end,
  seen_command_ids = seen_command_ids,
}
]]
  local env = {
    os = { epoch = function() return 1000000 end },
    peripheral = { wrap = function() return { setAutoMode = function() end } end },
    constants = { channels = { VALVE = 6504 } },
    utils = {
      log = function(_prefix, msg, level) log_lines[#log_lines + 1] = { msg = msg, level = level } end,
      write_config = function(path, cfg)
        write_config_calls[#write_config_calls + 1] = { path = path, trusted_source = cfg.trusted_source }
        if opts.write_config_ok == false then return false, 'simulated persist failure' end
        return true
      end,
    },
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type,
    pcall = pcall, error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env
  local fn = assert(load(preamble .. EXTRACTED .. footer, 'valve_pairing_test_chunk', 't', env))
  local instance = fn()
  instance.log_lines = log_lines
  instance.write_config_calls = write_config_calls
  return instance
end

-- First accepted sender is paired only after a successful actuator apply and
-- the trust identity is durably persisted.
do
  local inst = make_pairing_instance()
  local event = { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-1', high = true } }
  inst.handle_valve_channel_event(event)
  assert_eq(inst.get_trusted_source(), 'FUEL-1', 'first accepted sender must become trusted_source')
  assert_eq(#inst.write_config_calls, 1, 'pairing must be persisted once')
  assert_eq(inst.write_config_calls[1].trusted_source, 'FUEL-1', 'persisted config must carry trusted source')
  assert_true(inst.seen_command_ids['CMD-1'] == true, 'successfully paired command must be remembered')
end

-- Different sender after pairing is rejected without changing state.
do
  local inst = make_pairing_instance({ initial_trusted_source = 'FUEL-1' })
  local event = { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = 'INTRUDER-1', command_id = 'CMD-2', high = false } }
  inst.handle_valve_channel_event(event)
  assert_true(not inst.seen_command_ids['CMD-2'], 'untrusted sender must never be applied/remembered')
  assert_eq(inst.get_current_high(), true, 'untrusted command must not change valve state')
  local found_warn = false
  for _, entry in ipairs(inst.log_lines) do
    if entry.level == 'WARN' and tostring(entry.msg):find('nicht vertrauenswuerdiger', 1, true) then found_warn = true end
  end
  assert_true(found_warn, 'untrusted sender must be logged as WARN')
end

-- Already paired correct sender does not rewrite pairing config.
do
  local inst = make_pairing_instance({ initial_trusted_source = 'FUEL-1' })
  local event = { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-3', high = false } }
  inst.handle_valve_channel_event(event)
  assert_true(inst.seen_command_ids['CMD-3'] == true, 'trusted sender must be applied')
  assert_eq(#inst.write_config_calls, 0, 'existing pairing must not be re-persisted')
end

-- Pairing persistence failure clears RAM trust, forces BLOCKED physically and
-- leaves command retryable.
do
  local inst = make_pairing_instance({ write_config_ok = false })
  local event = { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-4', high = false } }
  inst.handle_valve_channel_event(event)
  assert_eq(inst.get_trusted_source(), nil, 'failed durable pairing must undo RAM trust')
  assert_eq(inst.get_current_high(), true, 'failed pairing persistence must force BLOCKED')
  assert_true(not inst.seen_command_ids['CMD-4'], 'failed pairing must not dedupe a future retry')
  local found_error = false
  for _, entry in ipairs(inst.log_lines) do
    if entry.level == 'ERROR' and tostring(entry.msg):find('NICHT dauerhaft gespeichert', 1, true) then found_error = true end
  end
  assert_true(found_error, 'failed durable pairing must be surfaced as ERROR')
end

-- Sorter handle is invalidated after a failed actuator call and wrapped fresh
-- on the next attempt.
do
  local wrap_calls = 0
  local sorter_should_fail = true
  local log_lines = {}
  local preamble = [[
local current_high = false
local valve_initialized = false
local last_write_error = nil
local last_command_ts = os.epoch("utc")
local config = { sorter_name = "logisticalSorter_1", trusted_source = "FUEL-1" }
local CONFIG = { LOG_PREFIX = "VALVE", CONFIG_PATH = "/xreactor/config/valve.lua" }
local node_id = "VALVE-1"
]]
  local footer = [[
return { apply_valve = apply_valve, get_current_high = function() return current_high end }
]]
  local env = {
    os = { epoch = function() return 1000000 end },
    peripheral = {
      wrap = function(_name)
        wrap_calls = wrap_calls + 1
        return { setAutoMode = function(_auto)
          if sorter_should_fail then error('simulated sorter call failure') end
        end }
      end,
    },
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function(_prefix, msg, level) log_lines[#log_lines + 1] = { msg = msg, level = level } end },
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type,
    pcall = pcall, error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env
  local fn = assert(load(preamble .. BLOCK_A .. footer, 'valve_sorter_reconnect_test_chunk', 't', env))
  local inst = fn()

  local ok1 = inst.apply_valve(true)
  assert_eq(ok1, false, 'failing sorter call must report failure')
  assert_eq(inst.get_current_high(), false, 'failed sorter write must not change current_high')
  assert_eq(wrap_calls, 1, 'first attempt must wrap sorter once')

  sorter_should_fail = false
  local ok2 = inst.apply_valve(true)
  assert_eq(ok2, true, 'retry after sorter becomes reachable must succeed')
  assert_eq(inst.get_current_high(), true, 'successful retry must update current_high')
  assert_eq(wrap_calls, 2, 'get_sorter() must re-wrap after actuator call failure')
end

print('valve_sender_pairing_and_sorter_reconnect_test.lua: ok')
