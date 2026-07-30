package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer die "Weg 3"-Idee des Melders: Route-Teach-in per
-- manuellem Redstone-INPUT (Fix 2026-07-20, siehe nodes/valve/main.lua
-- check_teach_input()). Der Redstone-Signal ist ein INPUT an den VALVE-
-- Computer (ein Hebel/Knopf, den der Spieler vor Ort physisch umlegt),
-- NICHT ein Output, den die Node selbst treibt -- eine steigende Flanke
-- auf irgendeiner der 6 eingebauten Seiten (Seite bewusst egal) loest
-- einen einmaligen ROUTE_TEACH_PULSE-Broadcast aus; re-arm erst, wenn der
-- Input wieder ueberall auf "aus" faellt. Extrahiert (wie tests/valve_
-- failed_write_retry_test.lua) den echten Quelltext von
-- check_teach_input() per String-Marker direkt aus main.lua.

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
local BLOCK = extract(SOURCE, 'local teach_input_state = false', 'teach_input_state = any_high\nend')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- inputs: Tabelle { [side] = true/false }. has_modem=false simuliert ein
-- fehlendes Funkmodem (valve_modem == nil).
local function make_instance(inputs, has_modem)
  if has_modem == nil then has_modem = true end
  local transmitted = {}

  local preamble = has_modem and [[
local node_id = "VALVE-1"
local valve_modem = { transmit = function(_channel, _reply, message) __record(message) end }
]] or [[
local node_id = "VALVE-1"
local valve_modem = nil
]]

  local footer = [[

return {
  check_teach_input = check_teach_input,
}
]]

  local chunk = preamble .. BLOCK .. footer

  local env = {
    redstone = {
      getSides = function() return { 'top', 'bottom', 'left', 'right', 'front', 'back' } end,
      getInput = function(side) return inputs[side] == true end,
    },
    constants = { channels = { VALVE = 6504 } },
    __record = function(message) transmitted[#transmitted + 1] = message end,
    pcall = pcall, ipairs = ipairs, type = type,
  }
  env._G = env

  local fn = assert(load(chunk, 'valve_teach_input_test_chunk', 't', env))
  local instance = fn()
  instance.transmitted = transmitted
  return instance
end

-- 1. Kein Input auf irgendeiner Seite: kein Puls.
do
  local inst = make_instance({})
  inst.check_teach_input()
  assert_eq(#inst.transmitted, 0, 'no input on any side must never send a pulse')
end

-- 2. Steigende Flanke (aus -> an) auf EINER beliebigen Seite: genau EIN
--    ROUTE_TEACH_PULSE mit src=node_id, ohne dst (Broadcast).
do
  local inputs = {}
  local inst = make_instance(inputs)
  inst.check_teach_input() -- noch aus
  inputs.left = true
  inst.check_teach_input() -- steigende Flanke
  assert_eq(#inst.transmitted, 1, 'a rising edge must send exactly one pulse')
  assert_eq(inst.transmitted[1].type, 'ROUTE_TEACH_PULSE')
  assert_eq(inst.transmitted[1].src, 'VALVE-1')
  assert_eq(inst.transmitted[1].dst, nil, 'a teach pulse must be a broadcast, not addressed to a specific dst')
end

-- 3. Input bleibt an (kein Loslassen): kein zweiter Puls, solange der
--    Zustand nicht wieder auf "aus" faellt.
do
  local inputs = { left = true }
  local inst = make_instance(inputs)
  inst.check_teach_input() -- erste Flanke
  inst.check_teach_input() -- immer noch an
  inst.check_teach_input() -- immer noch an
  assert_eq(#inst.transmitted, 1, 'a held-high input must not re-trigger additional pulses')
end

-- 4. "an, dann wieder aus, dann wieder an" (typische Hebel-Geste): re-armt
--    sich und sendet einen zweiten Puls.
do
  local inputs = {}
  local inst = make_instance(inputs)
  inputs.right = true
  inst.check_teach_input() -- Puls 1
  inputs.right = false
  inst.check_teach_input() -- re-arm
  inputs.right = true
  inst.check_teach_input() -- Puls 2
  assert_eq(#inst.transmitted, 2, 'releasing and re-triggering the input must send a second pulse')
end

-- 5. Ohne verfuegbares Funkmodem: kein Crash, einfach kein Puls.
do
  local inst = make_instance({ top = true }, false)
  local ok = pcall(inst.check_teach_input)
  assert_true(ok, 'check_teach_input must not crash without a valve_modem')
  assert_eq(#inst.transmitted, 0, 'without a valve_modem, nothing can be transmitted')
end

print("valve_teach_input_test.lua: ok")
