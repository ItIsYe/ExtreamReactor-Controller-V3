package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer WATER-P1/RT-P1 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 16 und Abschnitt 14 "Persistenzfehler
-- kann trotzdem als angewendet bestaetigt werden"). Vor diesem Fix
-- quittierten sowohl WATER's SET_TARGET-Handler (nodes/water/main.lua) als
-- auch RT's SET_REACTOR_FILL_TARGET-Pfad (nodes/rt/command_handler.lua +
-- nodes/rt/main.lua's set_reactor_fill_target-Callback) das Command IMMER
-- mit `ok=true`, selbst wenn der zugrundeliegende write_config()-Aufruf
-- fehlschlug (WATER: Rueckgabewert geloggt aber ignoriert; RT: Rueckgabewert
-- komplett verworfen durch einen unausgewerteten `pcall(...)`). MASTER
-- konnte dadurch ein ACK_APPLIED erhalten, obwohl der Wert nach einem
-- Neustart wieder verloren geht.
--
-- Vier Testbloecke:
-- 1. nodes/support/command_handler.lua's finish() -- neues optionales
--    `extra`-Argument, rueckwaertskompatibel.
-- 2. nodes/water/main.lua's SET_TARGET-Zweig (Boot-Skript, nicht direkt
--    require()-bar -- per Marker-Extraktion isoliert).
-- 3. nodes/rt/command_handler.lua's SET_REACTOR_FILL_TARGET-Dispatch (echtes
--    require()-bares Modul).
-- 4. nodes/rt/main.lua's set_reactor_fill_target-Callback (Boot-Skript --
--    per Marker-Extraktion isoliert).

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function read(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local c = f:read('*a')
  f:close()
  return c
end

-- 1. support_command_handler.finish() mit/ohne extra-Argument
do
  local support_command_handler = require('nodes.support.command_handler')
  local devices = {}

  local result_no_extra = support_command_handler.finish(devices, true)
  assert_eq(result_no_extra.ok, true, 'finish(devices, true) must stay ok=true without extra')
  assert_eq(result_no_extra.persisted, nil, 'finish(devices, true) without extra must not invent a persisted field')

  local result_with_extra = support_command_handler.finish(devices, true, { persisted = false })
  assert_eq(result_with_extra.ok, true, 'finish(devices, true, {persisted=false}) must keep ok=true (RAM value was applied)')
  assert_eq(result_with_extra.persisted, false, 'finish() must merge the extra table into the result')
end

-- 2. WATER SET_TARGET: persisted must honestly reflect write_config()'s
--    result, while ok stays true (the RAM value was applied either way).
do
  local source = read('xreactor/nodes/water/main.lua')
  local start_pos = source:find('local function handle_command(message)', 1, true)
  assert(start_pos, 'handle_command not found in nodes/water/main.lua')
  local end_pos = source:find('\nlocal function init()', start_pos, true)
  assert(end_pos, 'end of handle_command not found')
  local block = source:sub(start_pos, end_pos)

  local function load_handler(write_ok, write_err, warn_log)
    local env = setmetatable({
      constants = { command_targets = { SET_TARGET = 'SET_TARGET' } },
      support_command_handler = require('nodes.support.command_handler'),
      utils = {
        write_config = function() return write_ok, write_err end,
        log = function(_prefix, msg, level)
          if level == 'WARN' then warn_log[#warn_log + 1] = msg end
        end,
      },
      config = {},
      CONFIG = { CONFIG_PATH = '/xreactor/config/water.lua' },
      devices = {},
    }, { __index = _G })
    local chunk = block .. '\nreturn { handle_command = handle_command }\n'
    local fn = assert(load(chunk, '=water_set_target_test', 't', env))
    return fn().handle_command
  end

  -- 2a. successful persistence -> persisted=true
  do
    local warn_log = {}
    local handle_command = load_handler(true, nil, warn_log)
    local result = handle_command({ payload = { command = { target = 'SET_TARGET', value = '1000' } } })
    assert_eq(result.ok, true, 'SET_TARGET must apply ok=true when write_config succeeds')
    assert_eq(result.persisted, true, 'SET_TARGET must report persisted=true when write_config succeeds')
    assert_eq(#warn_log, 0, 'no WARN log expected on successful persistence')
  end

  -- 2b. failed persistence -> ok stays true (RAM value applied), but persisted=false
  do
    local warn_log = {}
    local handle_command = load_handler(false, 'disk_full', warn_log)
    local result = handle_command({ payload = { command = { target = 'SET_TARGET', value = '1000' } } })
    assert_eq(result.ok, true, 'SET_TARGET must still report ok=true (the in-RAM value was applied) even if persistence failed')
    assert_eq(result.persisted, false,
      'SET_TARGET must report persisted=false when write_config fails -- ' ..
      'a blanket ok=true here is exactly the bug: MASTER would see ACK_APPLIED for a value that is lost on reboot')
    assert(#warn_log >= 1, 'a persistence failure must still be logged as WARN')
  end
end

-- Bloecke 3 und 4 (RTs SET_REACTOR_FILL_TARGET-Dispatch in nodes/rt/
-- command_handler.lua und der zugehoerige Callback in nodes/rt/main.lua)
-- sind mit v769 entfallen: der v1-Command-Handler ist entfernt, und
-- nodes/rt/rt2_command_handler.lua kennt dieses Kommando nicht -- es war
-- also schon vor diesem Umbau unerreichbar, seit der Regler v2 laeuft. Der
-- Sollwert des Dampftanks steht jetzt in rt2_reactor.DEFAULT_TARGET_FILL.
-- Die eigentliche Lehre dieses Tests -- eine fehlgeschlagene Persistenz darf
-- nie als angewendet quittiert werden -- bewachen die Bloecke 1 und 2
-- unveraendert weiter (support/command_handler.lua und WATER).

print('water_rt_persistence_ack_honesty_test.lua: ok')
