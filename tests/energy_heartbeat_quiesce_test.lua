package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer INSTALL-P0.2 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 4). ENERGY hat (anders als RT/VALVE/
-- FUEL/REPROCESSOR/WATER) keinen gemeinsamen support_runtime.run_event_
-- loop() -- der Heartbeat-Thread (nodes/energy/heartbeat.lua) laeuft ueber
-- parallel.waitForAny() neben dem Matrix-Thread. Vor diesem Fix hatte dieser
-- Thread keinen kontrollierten Weg, sich zu beenden. Dieser Test treibt das
-- echte Modul mit gemocktem os.pullEventRaw und einem echten core/
-- update_handshake.lua-Handshake: ist QUIESCE_REQUESTED gesetzt, muss der
-- Thread beim naechsten svc_timer-Tick sauber zurueckkehren und den
-- Handshake auf RUNTIME_STOPPED setzen.

local heartbeat_mod = require('nodes.energy.heartbeat')
local update_handshake = require('core.update_handshake')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- 1. QUIESCE_REQUESTED gesetzt -> der Thread beendet sich beim naechsten
--    svc_timer-Tick, OHNE auf den (viel selteneren) hb_timer zu warten.
do
  _G.__xreactor_update_handshake = update_handshake.new()
  update_handshake.request_quiesce(_G.__xreactor_update_handshake)

  local now = 1000
  local next_timer_id = 0
  local os_start_timer = os.startTimer
  os.startTimer = function(_s) next_timer_id = next_timer_id + 1; return next_timer_id end

  local event_queue = {
    { 'timer', 2 },  -- svc_timer (2. os.startTimer-Aufruf beim Loop-Start)
  }
  local os_pull_event_raw = os.pullEventRaw
  os.pullEventRaw = function()
    local e = table.remove(event_queue, 1)
    if not e then error('event queue exhausted -- loop did not exit on the svc_timer tick as expected') end
    return table.unpack(e)
  end

  local ctx = {
    comms = { handle_event = function() end, tick = function() end },
    config = {}, devices = {}, ui_state = {}, ui_pages = {},
    services = { tick = function() end },
    now_ms = function() return now end,
    log = function() end,
    last_heartbeat_warn_ts = 0,
    heartbeat_interval_ms = function() return 2000 end,
    get_last_heartbeat_ts = function() return 0 end,
    send_heartbeat_if_due = function() return false end,
    tick_interval_s = 0.5,
  }

  heartbeat_mod.run(ctx)

  os.startTimer = os_start_timer
  os.pullEventRaw = os_pull_event_raw

  assert_eq(_G.__xreactor_update_handshake.state, update_handshake.STATE.RUNTIME_STOPPED,
    'the heartbeat thread must mark RUNTIME_STOPPED once it observes QUIESCE_REQUESTED')

  _G.__xreactor_update_handshake = nil
end

-- 2. Ohne einen konfigurierten Handshake (_G.__xreactor_update_handshake ==
--    nil, der Normalfall ausserhalb eines Updates) darf sich am bisherigen
--    Verhalten nichts aendern -- der Thread laeuft normal weiter.
do
  _G.__xreactor_update_handshake = nil

  local next_timer_id = 0
  local os_start_timer = os.startTimer
  os.startTimer = function(_s) next_timer_id = next_timer_id + 1; return next_timer_id end

  local event_queue = {
    { 'timer', 2 },  -- svc_timer: must NOT exit without a handshake
    { 'terminate' },
  }
  local os_pull_event_raw = os.pullEventRaw
  os.pullEventRaw = function()
    local e = table.remove(event_queue, 1)
    if not e then error('event queue exhausted') end
    return table.unpack(e)
  end

  local ctx = {
    comms = { handle_event = function() end, tick = function() end },
    config = {}, devices = {}, ui_state = {}, ui_pages = {},
    services = { tick = function() end },
    now_ms = function() return 1000 end,
    log = function() end,
    last_heartbeat_warn_ts = 0,
    heartbeat_interval_ms = function() return 2000 end,
    get_last_heartbeat_ts = function() return 0 end,
    send_heartbeat_if_due = function() return false end,
    tick_interval_s = 0.5,
  }

  local result = heartbeat_mod.run(ctx)

  os.startTimer = os_start_timer
  os.pullEventRaw = os_pull_event_raw

  assert_eq(result, 'terminate', 'without a handshake the loop must run until terminate, exactly as before this fix')
end

print('energy_heartbeat_quiesce_test.lua: ok')
