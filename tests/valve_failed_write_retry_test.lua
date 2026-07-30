package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer VALVE-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 12 "Fehlgeschlagener Write wird nicht erneut
-- versucht"). nodes/valve/main.lua ist ein eigenstaendiges Top-Level-
-- Node-Skript (dofile()/require() mit Seiteneffekten, blockierender
-- Event-Loop am Ende) -- kein require()-bares Modul. Dieser Test extrahiert
-- deshalb den echten Quelltext von apply_valve()/handle_valve_channel_
-- event() per String-Marker direkt aus main.lua und fuehrt ihn per load()
-- in einer isolierten, gemockten Umgebung aus (Sorter setAutoMode()
-- steuerbar fehlschlagend), um zu beweisen, dass die reale Fix-Logik
-- (nicht nur eine Nachbildung) sich korrekt verhaelt.

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
-- Zwei getrennte Bloecke: get_sorter()/write_actuator()/apply_valve()
-- (Block A) und die Dedupe-Helfer + send_valve_ack() +
-- handle_valve_channel_event() (Block B) -- dazwischen liegen der
-- Boot-Write-Aufruf und die Modem-Kanal-Oeffnung (echte Seiteneffekte,
-- peripheral.find()), die fuer diesen Test nicht gebraucht und nicht
-- extrahiert werden. apply_valve() ruft seit der Sorter-Aktor-Erweiterung
-- write_actuator() auf statt redstone.setOutput() direkt -- Block A muss
-- deshalb bei get_sorter()/write_actuator() beginnen, nicht erst bei
-- apply_valve() selbst.
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

-- Baut eine frische, isolierte Instanz der extrahierten Logik.
-- write_ok_ref: Funktion, die pro Aufruf steuert ob der Sorter-Call
-- gerade "erfolgreich" oder "fehlschlagend" simuliert wird.
local function make_instance(write_ok_ref, opts)
  opts = opts or {}
  local clock = opts.clock or 1000000
  local log_lines = {}

  local preamble = [[
local current_high = ]] .. tostring(opts.default_blocked ~= false) .. [[

local valve_initialized = false
local last_write_error = nil
local last_command_ts = os.epoch("utc")
-- trusted_source pre-set (not nil) so the VALVE-P1 auto-pairing logic
-- (added 2026-07-17, see valve_sender_pairing_and_sorter_reconnect_test.lua
-- for its dedicated coverage) does not interfere with this test's
-- write-retry-focused assertions.
local config = { sorter_name = "logisticalSorter_1", trusted_source = "FUEL-1" }
local CONFIG = { LOG_PREFIX = "VALVE" }
local node_id = "VALVE-1"
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

  local chunk = preamble .. EXTRACTED .. footer

  local env = {
    os = { epoch = function() return clock end },
    peripheral = {
      wrap = function(_name)
        return {
          setAutoMode = function(_auto)
            if not write_ok_ref() then
              error('simulated sorter write failure')
            end
          end,
        }
      end,
    },
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function(_prefix, msg, level) table.insert(log_lines, { msg = msg, level = level }) end },
    string = string, table = table, tostring = tostring, tonumber = tonumber, type = type, pcall = pcall,
    error = error, ipairs = ipairs, pairs = pairs, select = select,
  }
  env._G = env

  local fn = assert(load(chunk, 'valve_test_chunk', 't', env))
  local instance = fn()
  instance.log_lines = log_lines
  instance.set_clock = function(v) clock = v end
  return instance
end

-- 1. Fehlgeschlagener Write: Retry mit DERSELBEN command_id muss einen
--    ZWEITEN echten Schreibversuch ausloesen, sobald das Ventil (hier
--    simuliert) wieder schreibbar ist -- nicht bloss aus dem Dedupe-Cache
--    beantwortet werden.
do
  local write_ok = false
  local inst = make_instance(function() return write_ok end, { default_blocked = false })

  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-1', high = true } }

  inst.handle_valve_channel_event(event)
  assert_eq(inst.get_current_high(), false, 'a failed write must not change current_high (still open/default)')
  assert_true(not inst.seen_command_ids['CMD-1'], 'a failed command must NOT be remembered as seen (this is the actual bug)')

  -- Der Router wuerde jetzt (redstone_router.lua's check_pending_acks())
  -- exakt dieselbe command_id erneut senden.
  write_ok = true
  inst.handle_valve_channel_event(event)
  assert_eq(inst.get_current_high(), true, 'the retry with the same command_id must perform a real second write attempt and succeed')
  assert_true(inst.seen_command_ids['CMD-1'] == true, 'a command is only remembered once it actually succeeded')
end

-- 2. Erfolgreicher Write wird weiterhin korrekt dedupliziert (kein
--    Regressionsverlust der urspruenglichen VALVE-P1-Dedupe-Funktion).
do
  local inst = make_instance(function() return true end)
  local write_count = 0
  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-2', high = true } }

  inst.handle_valve_channel_event(event)
  assert_true(inst.seen_command_ids['CMD-2'] == true, 'a successful command should be remembered')
  local first_ts = inst.get_last_command_ts()

  inst.set_clock(first_ts + 5000)
  inst.handle_valve_channel_event(event)
  assert_eq(inst.get_last_command_ts(), first_ts, 'a deduplicated retry of an already-successful command must not touch state again')
end

-- 3. last_command_ts darf durch einen fehlgeschlagenen sicherheitskritischen
--    Write NICHT verlaengert werden (ein offen bleibendes Ventil darf nicht
--    laenger unbeaufsichtigt bleiben, nur weil ein Blockierversuch
--    fehlschlug).
do
  local write_ok = true
  local inst = make_instance(function() return write_ok end, { default_blocked = false })
  local baseline_ts = inst.get_last_command_ts()

  inst.set_clock(baseline_ts + 1000)
  write_ok = false
  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-3', high = true } }
  inst.handle_valve_channel_event(event)

  assert_eq(inst.get_current_high(), false, 'the failed block attempt must not change current_high')
  assert_eq(inst.get_last_command_ts(), baseline_ts, 'a failed write must not reset last_command_ts (would extend the unsafe grace period)')
  assert_true(inst.get_last_write_error() ~= nil, 'the failure should be visible via last_write_error')
end

print('valve_failed_write_retry_test.lua: ok')
