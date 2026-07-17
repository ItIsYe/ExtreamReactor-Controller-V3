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

-- 3. RT SET_REACTOR_FILL_TARGET dispatch: persisted must reflect
--    ctx.set_reactor_fill_target()'s return value.
do
  local handler = require('nodes.rt.command_handler')
  local constants = require('shared.constants')

  local function new_handler(set_reactor_fill_target)
    return handler.new({
      protocol = { is_for_node = function() return true end, is_proto_compatible = function() return true end },
      STATE = { MASTER = 'MASTER', SAFE = 'SAFE' },
      targets = {},
      get_current_state = function() return 'MASTER' end,
      get_states = function() return constants.node_states end,
      node_state_machine = { state = function() return constants.node_states.RUNNING end, transition = function() end },
      request_startup_if_needed = function() end,
      apply_mode = function() end,
      start_module = function() return nil end,
      add_alarm = function() end,
      get_network_id = function() return 'RT-1' end,
      note_master_seen = function() end,
      set_last_command = function() end,
      set_last_command_ts = function() end,
      set_reactor_fill_target = set_reactor_fill_target,
      log = function() end,
    })
  end

  -- 3a. successful persistence
  do
    local ch = new_handler(function(_value) return true end)
    local result = ch({ proto_ver = constants.proto_ver, payload = { command = { target = 'SET_REACTOR_FILL_TARGET', value = 0.5 } } })
    assert_eq(result.ok, true, 'SET_REACTOR_FILL_TARGET must apply ok=true when persistence succeeds')
    assert_eq(result.persisted, true, 'SET_REACTOR_FILL_TARGET must report persisted=true when persistence succeeds')
  end

  -- 3b. failed persistence -> ok stays true, persisted=false (the bug: this
  --     used to return bare `nil`, which the outer dispatcher always turned
  --     into an unconditional { ok = true } with no persistence signal at all)
  do
    local ch = new_handler(function(_value) return false end)
    local result = ch({ proto_ver = constants.proto_ver, payload = { command = { target = 'SET_REACTOR_FILL_TARGET', value = 0.5 } } })
    assert_eq(result.ok, true, 'SET_REACTOR_FILL_TARGET must still report ok=true (the RAM value was applied)')
    assert_eq(result.persisted, false,
      'SET_REACTOR_FILL_TARGET must report persisted=false when ctx.set_reactor_fill_target() fails to persist')
  end
end

-- 4. RT main.lua's set_reactor_fill_target callback: must actually inspect
--    write_config()'s return value (previously discarded via an
--    unevaluated pcall(...)) and return it to the caller.
do
  local source = read('xreactor/nodes/rt/main.lua')
  local start_pos = source:find('set_reactor_fill_target = function(value)', 1, true)
  assert(start_pos, 'set_reactor_fill_target not found in nodes/rt/main.lua')
  local end_pos = source:find('\n    end,\n    log = log,', start_pos, true)
  assert(end_pos, 'end of set_reactor_fill_target not found')
  local block = source:sub(start_pos, end_pos - 1) .. '\n    end'

  local function load_callback(write_ok, write_err, warn_log, info_log)
    local env = setmetatable({
      config = {},
      CONFIG = { CONFIG_PATH = '/xreactor/config/rt.lua' },
      utils = { write_config = function() return write_ok, write_err end },
      log = function(level, msg)
        if level == 'WARN' then warn_log[#warn_log + 1] = msg end
        if level == 'INFO' then info_log[#info_log + 1] = msg end
      end,
    }, { __index = _G })
    local chunk = 'local ' .. block .. '\nreturn set_reactor_fill_target\n'
    local fn = assert(load(chunk, '=rt_set_reactor_fill_target_test', 't', env))
    return fn()
  end

  -- 4a. successful persistence -> returns true, logs INFO not WARN
  do
    local warn_log, info_log = {}, {}
    local set_reactor_fill_target = load_callback(true, nil, warn_log, info_log)
    local ok_result = set_reactor_fill_target(0.5)
    assert_eq(ok_result, true, 'set_reactor_fill_target must return true when write_config succeeds')
    assert_eq(#warn_log, 0, 'no WARN expected on successful persistence')
    assert(#info_log >= 1, 'a successful change must still be logged as INFO')
  end

  -- 4b. failed persistence -> returns false (not silently swallowed by an
  --     unevaluated pcall), logs WARN
  do
    local warn_log, info_log = {}, {}
    local set_reactor_fill_target = load_callback(false, 'disk_full', warn_log, info_log)
    local ok_result = set_reactor_fill_target(0.5)
    assert_eq(ok_result, false,
      'set_reactor_fill_target must return false when write_config fails -- ' ..
      'the old pcall(utils.write_config, ...) call discarded this result entirely')
    assert(#warn_log >= 1, 'a persistence failure must be logged as WARN')
  end
end

print('water_rt_persistence_ack_honesty_test.lua: ok')
