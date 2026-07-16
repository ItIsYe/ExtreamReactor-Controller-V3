package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer ENERGY-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 13 "Schedulergruppen sind nicht vollstaendig
-- getrennt"). Vor diesem Fix tickte nodes/energy/matrix.lua (der Thread, der
-- ausdruecklich blockierende 1-4s-Peripherie-Calls machen darf) die
-- VOLLSTAENDIGE Service-Liste (COMMS/DISCOVERY/STORAGE_SAMPLE/MATRIX_
-- SAMPLE/TELEMETRY/UI) und sendete bei jedem ~0.5s-Loop-Durchlauf
-- UNGEGATET einen Heartbeat, unabhaengig vom konfigurierten Intervall.
-- Dieser Test treibt die echten, jetzt require()-baren Module nodes/
-- energy/matrix.lua und nodes/energy/heartbeat.lua (beide reine M.run(ctx)-
-- Module ohne Boot-Seiteneffekte) und beweist die neue Trennung; ergaenzt
-- um eine strukturelle Pruefung von nodes/energy/main.lua's Verdrahtung
-- (die als Boot-Skript mit Seiteneffekten nicht direkt instanziierbar ist).

local matrix_mod = require('nodes.energy.matrix')
local heartbeat_mod = require('nodes.energy.heartbeat')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- 1. matrix.lua tickt nur das ihm uebergebene ctx.services (jetzt eine
--    dedizierte Gruppe in main.lua) und ruft NACH JEDEM Tick nur noch
--    ctx.send_heartbeat_if_due() auf (nicht mehr ein ungegatetes
--    send_heartbeat) -- egal wie oft/wie "langsam" der Tick simuliert wird.
do
  local sleep_count = 0
  local real_sleep = os.sleep
  os.sleep = function(_s)
    sleep_count = sleep_count + 1
    if sleep_count > 3 then error('STOP_TEST_LOOP') end
  end

  local tick_calls = 0
  local heartbeat_due_calls = {}
  local ctx = {
    services = { tick = function() tick_calls = tick_calls + 1 end },
    now_ms = function() return 1000 * sleep_count end,
    receive_timeout_s = 0.1,
    send_heartbeat_if_due = function(ts) table.insert(heartbeat_due_calls, ts) end,
    log = function() end,
  }

  local ok, err = pcall(matrix_mod.run, ctx)
  os.sleep = real_sleep

  assert_true(not ok, 'test loop should terminate via the sentinel error')
  assert_true(tostring(err):find('STOP_TEST_LOOP', 1, true) ~= nil, 'unexpected error: ' .. tostring(err))
  assert_eq(tick_calls, 3, 'matrix.lua should tick its injected services group once per loop iteration')
  assert_eq(#heartbeat_due_calls, 3, 'matrix.lua must call send_heartbeat_if_due (gated), not an unconditional send, after every tick')
end

-- 2. matrix.lua survives a slow/failing tick (pcall-wrapped) and still
--    calls the heartbeat catch-up check afterward.
do
  local sleep_count = 0
  local real_sleep = os.sleep
  os.sleep = function(_s)
    sleep_count = sleep_count + 1
    if sleep_count > 1 then error('STOP_TEST_LOOP') end
  end
  local heartbeat_due_calls = 0
  local ctx = {
    services = { tick = function() error('simulated slow/broken peripheral call') end },
    now_ms = function() return 1000 end,
    receive_timeout_s = 0.1,
    send_heartbeat_if_due = function() heartbeat_due_calls = heartbeat_due_calls + 1 end,
    log = function() end,
  }
  local ok = pcall(matrix_mod.run, ctx)
  os.sleep = real_sleep
  assert_true(not ok, 'sentinel should still terminate the loop')
  assert_eq(heartbeat_due_calls, 1, 'a failing services:tick() must not prevent the heartbeat catch-up check')
end

-- 3. heartbeat.lua tickt ctx.services periodisch, UNABHAENGIG vom
--    Heartbeat-Sende-Intervall (eigener Timer) -- "COMMS/UI/Telemetry/
--    Discovery bleiben in getrennten Schedulergruppen" bedeutet konkret:
--    ihr periodischer Tick ist nicht an den (potenziell selteneren)
--    Heartbeat-Takt gekoppelt.
do
  local next_timer_id = 0
  local os_start_timer = os.startTimer
  os.startTimer = function(_s) next_timer_id = next_timer_id + 1; return next_timer_id end

  local event_queue = {
    { 'timer', 2 },  -- svc_timer (2. Aufruf von os.startTimer beim Loop-Start)
    { 'timer', 3 },  -- svc_timer neu gestartet (3. Aufruf)
    { 'timer', 1 },  -- hb_timer (1. Aufruf von os.startTimer beim Loop-Start)
    { 'terminate' },
  }
  local os_pull_event_raw = os.pullEventRaw
  os.pullEventRaw = function()
    local e = table.remove(event_queue, 1)
    if not e then error('event queue exhausted') end
    return table.unpack(e)
  end

  local tick_calls = 0
  local heartbeat_calls = 0
  local ctx = {
    comms = { handle_event = function() end, tick = function() end },
    config = {}, devices = {}, ui_state = {}, ui_pages = {},
    services = { tick = function() tick_calls = tick_calls + 1 end },
    now_ms = function() return 0 end,
    log = function() end,
    last_heartbeat_ts = 0, last_heartbeat_warn_ts = 0,
    heartbeat_interval_ms = function() return 2000 end,
    send_heartbeat = function() heartbeat_calls = heartbeat_calls + 1 end,
    tick_interval_s = 0.5,
  }

  local result = heartbeat_mod.run(ctx)
  os.startTimer = os_start_timer
  os.pullEventRaw = os_pull_event_raw

  assert_eq(result, 'terminate', 'the loop should exit cleanly on a terminate event')
  assert_eq(tick_calls, 2, 'ctx.services must be ticked periodically via its own timer, independent of the heartbeat timer')
  assert_eq(heartbeat_calls, 1, 'do_heartbeat should fire once for the single hb_timer event')
end

-- 4. Strukturelle Verdrahtungspruefung fuer nodes/energy/main.lua (Boot-
--    Skript mit Seiteneffekten, nicht direkt instanziierbar): STORAGE_
--    SAMPLE/MATRIX_SAMPLE muessen in matrix_services registriert sein
--    (nicht in services), und der Matrix-Thread-Context muss matrix_
--    services statt der vollen "services"-Gruppe an matrix.lua uebergeben.
do
  local f = assert(io.open('xreactor/nodes/energy/main.lua', 'r'))
  local source = f:read('*a')
  f:close()

  assert_true(source:find('matrix_services:add(matrix_sampling_service.new({\n    name = "STORAGE_SAMPLE"', 1, true) ~= nil,
    'STORAGE_SAMPLE must be registered on matrix_services, not services')
  assert_true(source:find('matrix_services:add(matrix_sampling_service.new({\n    name = "MATRIX_SAMPLE"', 1, true) ~= nil,
    'MATRIX_SAMPLE must be registered on matrix_services, not services')
  assert_true(not source:find('\n  services:add(matrix_sampling_service.new', 1, true),
    'STORAGE_SAMPLE/MATRIX_SAMPLE must no longer be registered on the shared services manager')
  assert_true(source:find('services = matrix_services, now_ms = now_ms,', 1, true) ~= nil,
    'make_mx_ctx() must pass matrix_services (the dedicated group) to matrix.lua, not the full services manager')
  assert_true(source:find('matrix_services:init()', 1, true) ~= nil,
    'matrix_services must be initialized alongside services')
end

print('energy_matrix_thread_scheduler_isolation_test.lua: ok')
