package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer den optionalen Ampel-Statusmonitor an der VALVE-Node
-- (Fix 2026-07-20, siehe nodes/valve/main.lua render_ampel()): gruen=offen,
-- rot=blockiert, bei jeder apply_valve()-Anwendung aktualisiert (auch im
-- Dedupe-Fruehausstieg "bereits im Zielzustand"). Ohne verfuegbares
-- optional.ampel-Modul (ampel_instance == nil, z.B. wenn das Modul aus
-- irgendeinem Grund nicht ladbar ist) darf apply_valve() niemals
-- fehlschlagen oder werfen -- render_ampel() muss dann ein reiner No-Op
-- sein. Extrahiert (wie tests/valve_failed_write_retry_test.lua) den
-- echten Quelltext von main.lua per String-Marker.

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
  'BLOCKIERT" or "OFFEN"), "INFO")\n  return true\nend')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_instance(ampel_instance_mock)
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

return {
  apply_valve = apply_valve,
  get_current_high = function() return current_high end,
}
]]

  local chunk = preamble .. BLOCK_A .. footer

  local env = {
    os = { epoch = function() return 1000000 end },
    peripheral = { wrap = function() return { setAutoMode = function() end } end },
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end },
    ampel_instance = ampel_instance_mock,
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type, pcall = pcall,
    error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env

  local fn = assert(load(chunk, 'valve_ampel_test_chunk', 't', env))
  return fn()
end

-- 1. Ohne Ampel-Modul (ampel_instance == nil): apply_valve() darf niemals
--    fehlschlagen/werfen, render_ampel() ist ein No-Op.
do
  local inst = make_instance(nil)
  local ok = inst.apply_valve(false)
  assert_true(ok, 'apply_valve must succeed normally when no ampel monitor module is available')
end

-- 2. Mit Ampel-Modul: OFFEN -> "OK" (gruen), BLOCKIERT -> "EMERGENCY" (rot),
--    inklusive des Dedupe-Fruehausstiegs (bereits im Zielzustand).
do
  local rendered = {}
  local mock = { render = function(_main_name, status_key) rendered[#rendered + 1] = status_key end }
  local inst = make_instance(mock)

  inst.apply_valve(false) -- OFFEN
  assert_eq(rendered[#rendered], 'OK', 'an open valve must render the green ("OK") ampel status')

  inst.apply_valve(true) -- BLOCKIERT
  assert_eq(rendered[#rendered], 'EMERGENCY', 'a blocked valve must render the red ("EMERGENCY") ampel status')

  local count_before = #rendered
  inst.apply_valve(true) -- bereits im Zielzustand -- Dedupe-Fruehausstieg
  assert_true(#rendered > count_before, 'the ampel must still refresh on the already-in-state fast path (e.g. after a monitor reconnect)')
  assert_eq(rendered[#rendered], 'EMERGENCY', 'the deduped re-apply must still report the current (blocked) state')
end

print("valve_ampel_status_test.lua: ok")
