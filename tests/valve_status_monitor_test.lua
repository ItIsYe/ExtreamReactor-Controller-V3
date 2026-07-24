package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer den fest eingebauten (NICHT optionalen) 1x1-
-- Statusmonitor an der VALVE-Node (Fix 2026-07-20, siehe
-- nodes/valve/main.lua render_status_monitor()): gruen=offen, rot=
-- blockiert, bei jeder apply_valve()-Anwendung aktualisiert (auch im
-- Dedupe-Fruehausstieg "bereits im Zielzustand"). Anders als das
-- gemeinsame optional/ampel.lua-Modul (1x3-Turmform, per Installer-
-- Feature abwaehlbar) ist dieser Monitor ein simpler peripheral.find(
-- "monitor") ohne Formcheck, immer Teil der Installation. Ist physisch
-- kein Monitor angeschlossen, darf apply_valve() niemals fehlschlagen
-- oder werfen. Extrahiert (wie tests/valve_failed_write_retry_test.lua)
-- den echten Quelltext von main.lua per String-Marker.

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

-- monitor_mock: nil (kein Monitor gefunden) oder eine Tabelle mit
-- {colors=<liste der gesetzten setBackgroundColor-Werte>, fail=true/false}
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

return {
  apply_valve = apply_valve,
  get_current_high = function() return current_high end,
}
]]

  local chunk = preamble .. BLOCK_A .. footer

  local env = {
    os = { epoch = function() return 1000000 end },
    peripheral = {
      wrap = function() return { setAutoMode = function() end } end,
      find = function(kind)
        if kind ~= 'monitor' then return nil end
        if not monitor_mock then return nil end
        return {
          setBackgroundColor = function(color)
            if monitor_mock.fail then error('simulated monitor failure') end
            monitor_mock.colors[#monitor_mock.colors + 1] = color
          end,
          clear = function() end,
        }
      end,
    },
    colors = { red = 'red', green = 'green' },
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end },
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type, pcall = pcall,
    error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env

  local fn = assert(load(chunk, 'valve_status_monitor_test_chunk', 't', env))
  return fn()
end

-- 1. Ohne angeschlossenen Monitor (peripheral.find liefert nil): apply_
--    valve() darf niemals fehlschlagen/werfen, render_status_monitor() ist
--    ein reiner No-Op.
do
  local inst = make_instance(nil)
  local ok = inst.apply_valve(false)
  assert_true(ok, 'apply_valve must succeed normally when no monitor is attached')
end

-- 2. Mit Monitor: OFFEN -> gruen, BLOCKIERT -> rot, inklusive des Dedupe-
--    Fruehausstiegs (bereits im Zielzustand) -- muss weiterhin refreshen,
--    damit ein erst nach dem letzten Zustandswechsel angeschlossener/
--    wiederangeschlossener Monitor die aktuelle Farbe bekommt.
do
  local mock = { colors = {} }
  local inst = make_instance(mock)

  inst.apply_valve(false) -- OFFEN
  assert_eq(mock.colors[#mock.colors], 'green', 'an open valve must set the monitor background to green')

  inst.apply_valve(true) -- BLOCKIERT
  assert_eq(mock.colors[#mock.colors], 'red', 'a blocked valve must set the monitor background to red')

  local count_before = #mock.colors
  inst.apply_valve(true) -- bereits im Zielzustand, gleiche Farbe -- Dedupe-Fruehausstieg
  assert_eq(#mock.colors, count_before, 'an unchanged color must not trigger a redundant setBackgroundColor call')
end

-- 3. Ein fehlschlagender setBackgroundColor/clear-Aufruf (z.B. Monitor
--    getrennt) darf apply_valve() nicht zum Scheitern bringen, und muss den
--    Monitor-Cache verwerfen, damit der naechste Aufruf erneut sucht
--    (analog zu get_sorter()'s Reconnect-Verhalten).
do
  local mock = { colors = {}, fail = true }
  local inst = make_instance(mock)
  local ok = inst.apply_valve(false)
  assert_true(ok, 'apply_valve must still succeed even if the status monitor write fails')
  assert_eq(#mock.colors, 0, 'a failing monitor write must not record a color')
end

print("valve_status_monitor_test.lua: ok")
