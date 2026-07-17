package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer VALVE-P1 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 21 "Senderbindung und Sorter-Reconnect").
--
-- Zwei getrennte Bugs, beide in nodes/valve/main.lua behoben:
--
-- 1. Senderbindung: ohne manuell gesetztes config.trusted_source akzeptierte
--    die Node auf Dauer JEDEN Sender, der ein korrekt adressiertes SET_VALVE
--    auf Kanal 6504 sendet. Fix: automatisches Pairing an den ERSTEN
--    akzeptierten Sender, persistiert in der Nutzerconfig; jeder SPAETERE
--    abweichende Sender wird verworfen.
-- 2. Sorter-Reconnect: get_sorter() cachte den einmal gewrappten Sorter
--    dauerhaft -- ein spaeterer Callfehler (Detach/Reattach, ersetztes
--    Peripheral) liess den kaputten Handle fuer immer im Cache stehen.
--    Fix: bei einem Callfehler wird der Cache geleert, der naechste
--    get_sorter()-Aufruf wrappt neu.
--
-- nodes/valve/main.lua ist ein eigenstaendiges Top-Level-Node-Skript mit
-- Boot-Seiteneffekten -- dieser Test extrahiert deshalb (wie tests/
-- valve_failed_write_retry_test.lua) den echten Quelltext von get_sorter()/
-- write_actuator()/apply_valve() und handle_valve_channel_event() per
-- String-Marker direkt aus main.lua und fuehrt ihn per load() in einer
-- isolierten, gemockten Umgebung aus.

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
local BLOCK_B = extract(SOURCE, 'local SEEN_COMMAND_LIMIT = 16',
  'send_valve_ack(reply_side, message.command_id, applied, current_high, last_write_error, message.src)\nend')
local EXTRACTED = BLOCK_A .. '\n' .. BLOCK_B

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Teil 1: Senderbindung (Auto-Pairing)
-- ─────────────────────────────────────────────────────────────────────────
local function make_pairing_instance(opts)
  opts = opts or {}
  local log_lines = {}
  local write_config_calls = {}

  local preamble = [[
local current_high = true
local valve_initialized = false
local last_write_error = nil
local last_command_ts = os.epoch("utc")
local config = { side = "top", trusted_source = ]] .. (opts.initial_trusted_source and ('"' .. opts.initial_trusted_source .. '"') or 'nil') .. [[ }
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

  local chunk = preamble .. EXTRACTED .. footer

  local env = {
    os = { epoch = function() return 1000000 end },
    redstone = { setOutput = function() end },
    peripheral = { wrap = function() return nil end },
    constants = { channels = { VALVE = 6504 } },
    utils = {
      log = function(_prefix, msg, level) log_lines[#log_lines + 1] = { msg = msg, level = level } end,
      write_config = function(path, cfg)
        write_config_calls[#write_config_calls + 1] = { path = path, trusted_source = cfg.trusted_source }
        if opts.write_config_ok == false then return false, 'simulated persist failure' end
        return true
      end,
    },
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type, pcall = pcall,
    error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env

  local fn = assert(load(chunk, 'valve_pairing_test_chunk', 't', env))
  local instance = fn()
  instance.log_lines = log_lines
  instance.write_config_calls = write_config_calls
  return instance
end

-- 1a. Frische Installation (trusted_source unset): das erste akzeptierte
--     SET_VALVE bindet die Node automatisch an dessen Sender und
--     persistiert das Pairing.
do
  local inst = make_pairing_instance()
  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-1', high = true } }
  inst.handle_valve_channel_event(event)

  assert_eq(inst.get_trusted_source(), 'FUEL-1', 'the first accepted sender must be auto-paired as trusted_source')
  assert_eq(#inst.write_config_calls, 1, 'the pairing must be persisted via write_config')
  assert_eq(inst.write_config_calls[1].trusted_source, 'FUEL-1', 'the persisted config must carry the new trusted_source')
  assert_true(inst.seen_command_ids['CMD-1'] == true, 'the first, now-trusted command must still be applied normally')
end

-- 1b. Nach dem Pairing: ein ANDERER Sender wird verworfen (kein Redstone-
--     Write, kein Dedupe-Eintrag), ein WARN wird geloggt.
do
  local inst = make_pairing_instance({ initial_trusted_source = 'FUEL-1' })
  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_VALVE', dst = 'VALVE-1', src = 'INTRUDER-1', command_id = 'CMD-2', high = false } }
  inst.handle_valve_channel_event(event)

  assert_true(not inst.seen_command_ids['CMD-2'], 'a command from an untrusted sender must never be applied/remembered')
  assert_eq(inst.get_current_high(), true, 'the valve state must be unaffected by an untrusted SET_VALVE')
  local found_warn = false
  for _, entry in ipairs(inst.log_lines) do
    if entry.level == 'WARN' and tostring(entry.msg):find('nicht vertrauenswuerdiger', 1, true) then found_warn = true end
  end
  assert_true(found_warn, 'an untrusted sender must be logged as WARN')
end

-- 1c. Bereits gepaarter, korrekter Sender: normale Anwendung, KEIN
--     erneuter write_config-Aufruf (Pairing ist bereits abgeschlossen).
do
  local inst = make_pairing_instance({ initial_trusted_source = 'FUEL-1' })
  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-3', high = false } }
  inst.handle_valve_channel_event(event)

  assert_true(inst.seen_command_ids['CMD-3'] == true, 'a command from the already-trusted sender must be applied normally')
  assert_eq(#inst.write_config_calls, 0, 'an already-paired sender must not trigger a repeated pairing write')
end

-- 1d. Persistenzfehler waehrend des Pairings: das Pairing gilt trotzdem
--     sofort im RAM (Command wird verarbeitet), aber ein WARN macht die
--     fehlende Dauerhaftigkeit sichtbar (analog zu WATER/RT-P1).
do
  local inst = make_pairing_instance({ write_config_ok = false })
  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-4', high = true } }
  inst.handle_valve_channel_event(event)

  assert_eq(inst.get_trusted_source(), 'FUEL-1', 'pairing must still take effect in RAM even if persistence fails')
  local found_warn = false
  for _, entry in ipairs(inst.log_lines) do
    if entry.level == 'WARN' and tostring(entry.msg):find('konnte nicht persistiert', 1, true) then found_warn = true end
  end
  assert_true(found_warn, 'a failed pairing persistence must be logged as WARN')
end

-- ─────────────────────────────────────────────────────────────────────────
-- Teil 2: Sorter-Reconnect nach Callfehler
-- ─────────────────────────────────────────────────────────────────────────
do
  local wrap_calls = 0
  local sorter_should_fail = true
  local log_lines = {}

  local preamble = [[
local current_high = false
local valve_initialized = false
local last_write_error = nil
local last_command_ts = os.epoch("utc")
local config = { side = "top", trusted_source = "FUEL-1", actuator_type = "sorter", sorter_name = "logisticalSorter_1" }
local CONFIG = { LOG_PREFIX = "VALVE", CONFIG_PATH = "/xreactor/config/valve.lua" }
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
      wrap = function(_name)
        wrap_calls = wrap_calls + 1
        -- Jeder Wrap liefert ein FRISCHES Sorter-Objekt (wie ein echtes
        -- Detach/Reattach es tun wuerde) -- beweist, dass get_sorter()
        -- tatsaechlich neu wrappt statt denselben (evtl. kaputten) alten
        -- Handle weiterzureichen.
        -- write_actuator() calls this as `pcall(sorter.setAutoMode, not high)`
        -- (a plain field reference, NOT a colon-call) -- only `not high` is
        -- passed, no implicit self. Mirror that exact calling convention here.
        return {
          setAutoMode = function(_auto)
            if sorter_should_fail then error('simulated sorter call failure (detached peripheral)') end
          end,
        }
      end,
    },
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function(_prefix, msg, level) log_lines[#log_lines + 1] = { msg = msg, level = level } end },
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type, pcall = pcall,
    error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env

  local fn = assert(load(chunk, 'valve_sorter_reconnect_test_chunk', 't', env))
  local inst = fn()

  -- 2a. Erster Versuch schlaegt fehl (Sorter-Call wirft) -> current_high
  --     bleibt unveraendert.
  local ok1 = inst.apply_valve(true)
  assert_eq(ok1, false, 'a failing sorter call must report failure')
  assert_eq(inst.get_current_high(), false, 'a failed sorter write must not change current_high')
  assert_eq(wrap_calls, 1, 'the first apply_valve attempt must wrap the sorter exactly once')

  -- 2b. Zweiter Versuch (z.B. Retry ueber denselben Redstone-Router-
  --     Mechanismus wie bei valve_failed_write_retry_test.lua): der Sorter
  --     ist jetzt wieder erreichbar. Ohne den Fix wuerde get_sorter() den
  --     Cache aus Versuch 1 weiterreichen (peripheral.wrap NICHT erneut
  --     aufgerufen) -- mit dem Fix muss ein zweiter, frischer Wrap
  --     stattfinden.
  sorter_should_fail = false
  local ok2 = inst.apply_valve(true)
  assert_eq(ok2, true, 'a retry after the sorter becomes reachable again must succeed')
  assert_eq(inst.get_current_high(), true, 'a successful retry must update current_high')
  assert_eq(wrap_calls, 2,
    'get_sorter() must re-wrap the peripheral after a call failure -- ' ..
    'a stale cached handle would never be retried, only ever return the same broken device')
end

print('valve_sender_pairing_and_sorter_reconnect_test.lua: ok')
