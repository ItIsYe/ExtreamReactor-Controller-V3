package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer die "Weg 3"-Idee des Melders (Identify/Locate-Hilfe,
-- Fix 2026-07-20, siehe nodes/valve/main.lua apply_identify()/SET_IDENTIFY):
-- KEIN automatisches Teach-in (ausdruecklich abgelehnt), rein kosmetisch --
-- solange FUEL diese Node als Teil der gerade bearbeiteten Ventilkette
-- meldet, ziehen ALLE Redstone-Seiten gleichzeitig high (Seite ist bewusst
-- egal), voellig unabhaengig von der Sorter-Steuerung. Extrahiert (wie
-- tests/valve_sender_pairing_and_sorter_reconnect_test.lua) den echten
-- Quelltext von apply_identify() und handle_valve_channel_event() per
-- String-Marker direkt aus main.lua.

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
local BLOCK_C = extract(SOURCE, 'local identify_active = false', 'identify_active = on\nend')
local BLOCK_B = extract(SOURCE, 'local SEEN_COMMAND_LIMIT = 16',
  'send_valve_ack(reply_side, message.command_id, applied, current_high, last_write_error, message.src)\nend')
local EXTRACTED = BLOCK_C .. '\n' .. BLOCK_B

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_instance(opts)
  opts = opts or {}
  local rs_calls = {}

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
  get_identify_active = function() return identify_active end,
}
]]

  local chunk = preamble .. EXTRACTED .. footer

  local env = {
    os = { epoch = function() return 1000000 end },
    redstone = {
      getSides = function() return { 'top', 'bottom', 'left', 'right', 'front', 'back' } end,
      setOutput = function(side, on) rs_calls[#rs_calls + 1] = { side = side, on = on } end,
    },
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end, write_config = function() return true end },
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type, pcall = pcall,
    error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env

  local fn = assert(load(chunk, 'valve_identify_test_chunk', 't', env))
  local instance = fn()
  instance.rs_calls = rs_calls
  return instance
end

-- 1. SET_IDENTIFY(on=true) ohne vorheriges Pairing (frische Installation,
--    kein trusted_source) muss trotzdem angenommen werden und ALLE 6 Seiten
--    high ziehen.
do
  local inst = make_instance()
  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_IDENTIFY', dst = 'VALVE-1', src = 'FUEL-1', on = true } }
  inst.handle_valve_channel_event(event)

  assert_true(inst.get_identify_active(), 'SET_IDENTIFY(on=true) must activate identify even without a paired trusted_source')
  assert_eq(#inst.rs_calls, 6, 'apply_identify(true) must set redstone.setOutput on every side exactly once')
  for _, call in ipairs(inst.rs_calls) do
    assert_eq(call.on, true, 'every side must be pulsed high, not low')
  end
end

-- 2. Ein zweites SET_IDENTIFY(on=true), waehrend bereits aktiv, darf keine
--    weiteren redstone.setOutput-Aufrufe ausloesen (bereits im Zielzustand).
do
  local inst = make_instance()
  local event_on = { 'modem_message', 'left', 6504, 6504, { type = 'SET_IDENTIFY', dst = 'VALVE-1', src = 'FUEL-1', on = true } }
  inst.handle_valve_channel_event(event_on)
  local count_after_first = #inst.rs_calls
  inst.handle_valve_channel_event(event_on)
  assert_eq(#inst.rs_calls, count_after_first, 'a redundant SET_IDENTIFY(on=true) refresh must not re-trigger redstone.setOutput')
end

-- 3. SET_IDENTIFY(on=false) muss wieder alle Seiten auf low setzen.
do
  local inst = make_instance()
  inst.handle_valve_channel_event({ 'modem_message', 'left', 6504, 6504, { type = 'SET_IDENTIFY', dst = 'VALVE-1', src = 'FUEL-1', on = true } })
  inst.handle_valve_channel_event({ 'modem_message', 'left', 6504, 6504, { type = 'SET_IDENTIFY', dst = 'VALVE-1', src = 'FUEL-1', on = false } })

  assert_true(not inst.get_identify_active(), 'SET_IDENTIFY(on=false) must deactivate identify')
  local last_six = {}
  for i = #inst.rs_calls - 5, #inst.rs_calls do last_six[#last_six + 1] = inst.rs_calls[i] end
  for _, call in ipairs(last_six) do
    assert_eq(call.on, false, 'turning identify off must pulse every side low again')
  end
end

-- 4. Ist bereits ein trusted_source gepaart, wird ein SET_IDENTIFY von
--    einer ANDEREN Quelle verworfen (kein fremder Sender kann die Lampe
--    eines bereits gepaarten Ventils fernsteuern) -- UND ein Identify-
--    Befehl darf selbst KEIN Pairing auszuloesen (anders als SET_VALVE).
do
  local inst = make_instance({ initial_trusted_source = 'FUEL-1' })
  inst.handle_valve_channel_event({ 'modem_message', 'left', 6504, 6504, { type = 'SET_IDENTIFY', dst = 'VALVE-1', src = 'INTRUDER-1', on = true } })
  assert_true(not inst.get_identify_active(), 'a SET_IDENTIFY from an untrusted sender must be ignored once paired')
  assert_eq(#inst.rs_calls, 0, 'an untrusted SET_IDENTIFY must never touch redstone')
end

print("valve_identify_test.lua: ok")
