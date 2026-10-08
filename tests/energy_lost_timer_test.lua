package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Ein verlorenes Timer-Ereignis darf keinen Thread der ENERGY-Node
-- stilllegen.
--
-- CC:Tweaked verwirft Ereignisse, sobald 256 in der Warteschlange stehen
-- (ComputerExecutor.QUEUE_LIMIT), Timer eingeschlossen. Bis v813 haengten
-- beide ENERGY-Threads an genau einem Timer:
--
--   nodes/energy/heartbeat.lua  stellte seinen Dienste-Timer (Telemetrie,
--                               Discovery, Schirm, Quiesce-Pruefung) und
--                               seinen Heartbeat-Timer nur neu, wenn genau
--                               deren Ereignis kam
--   nodes/energy/matrix.lua     schlief mit os.sleep(), das auf genau einen
--                               Timer wartet -- danach froren die
--                               Speicherwerte an MASTER ein
--
-- Der Test faehrt die ECHTEN Threads gegen eine simulierte CC-Umgebung und
-- verwirft dann genau EIN Timer-Ereignis. Wann ein Heartbeat gesendet wird,
-- entscheidet weiter ctx.send_heartbeat_if_due() -- hier gezaehlt, nicht
-- veraendert.

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local STEP_MS = 50
local TICK_S = 0.5        -- ctx.tick_interval_s / receive_timeout_s
local HEARTBEAT_MS = 2000 -- ctx.heartbeat_interval_ms()

-- Faehrt einen Thread ueber `seconds` simulierte Sekunden.
--   thread  'heartbeat' oder 'matrix'
--   opts.modem  Funknachrichten alle 50 ms (Normalfall in der Anlage)
--   opts.drop   { svc = n } / { hb = n } / { matrix = n }: der n-te Timer
--               dieser Art geht verloren
local function drive(thread, seconds, opts)
  opts = opts or {}
  local drop = opts.drop or {}
  local now_ms, next_id, timers, kind_of = 0, 0, {}, {}
  os.clock = function() return now_ms / 1000 end
  os.epoch = function() return 1700000000000 + now_ms end
  os.startTimer = function(s)
    next_id = next_id + 1
    timers[next_id] = now_ms + math.floor((tonumber(s) or 0) * 1000 + 0.5)
    if thread == 'matrix' then
      kind_of[next_id] = 'matrix'
    else
      kind_of[next_id] = (math.abs((tonumber(s) or 0) - TICK_S) < 1e-9) and 'svc' or 'hb'
    end
    return next_id
  end
  os.cancelTimer = function(id) timers[id] = nil end
  os.pullEvent = function(filter) return coroutine.yield(filter) end
  os.pullEventRaw = os.pullEvent
  -- CC:Tweaked bios.lua, unveraendert (so schlief matrix.lua bis v813).
  os.sleep = function(n)
    local timer = os.startTimer(n or 0)
    repeat
      local _, param = os.pullEvent('timer')
    until param == timer
  end

  package.loaded['nodes.support.runtime'] = nil
  package.loaded['nodes.energy.heartbeat'] = nil
  package.loaded['nodes.energy.matrix'] = nil
  local support_runtime = require('nodes.support.runtime')

  local service_ticks, heartbeat_checks = 0, 0
  local ctx = {
    comms = { handle_event = function() end, tick = function() end },
    config = {}, devices = {}, ui_state = {}, ui_pages = {},
    services = { tick = function(_, _, event) if event == nil then service_ticks = service_ticks + 1 end end },
    now_ms = function() return now_ms end,
    log = function() end,
    last_heartbeat_warn_ts = 0,
    heartbeat_interval_ms = function() return HEARTBEAT_MS end,
    get_last_heartbeat_ts = function() return 0 end,
    send_heartbeat_if_due = function() heartbeat_checks = heartbeat_checks + 1; return false end,
    tick_interval_s = TICK_S,
    receive_timeout_s = TICK_S,
  }
  local mod = require(thread == 'matrix' and 'nodes.energy.matrix' or 'nodes.energy.heartbeat')
  local co = coroutine.create(function() return mod.run(ctx) end)
  local ok, filter = coroutine.resume(co)
  assert(ok, filter)

  local count, modem_at = {}, 50
  local ticks_at, checks_at = {}, {}
  for _ = 1, math.floor(seconds * 1000 / STEP_MS) do
    now_ms = now_ms + STEP_MS
    local events = {}
    local due = {}
    for id, at in pairs(timers) do
      if at <= now_ms then due[#due + 1] = id end
    end
    table.sort(due)
    for _, id in ipairs(due) do
      timers[id] = nil
      local kind = kind_of[id]
      count[kind] = (count[kind] or 0) + 1
      if drop[kind] ~= count[kind] then events[#events + 1] = { 'timer', id } end
    end
    if opts.modem and now_ms >= modem_at then
      modem_at = modem_at + 50
      events[#events + 1] = { 'modem_message', 'back', 1, 1, {}, 1 }
    end
    for _, ev in ipairs(events) do
      if coroutine.status(co) == 'suspended' and (filter == nil or filter == ev[1]) then
        ok, filter = coroutine.resume(co, table.unpack(ev))
        assert(ok, filter)
      end
    end
    ticks_at[now_ms] = service_ticks
    checks_at[now_ms] = heartbeat_checks
  end
  return {
    service_ticks = service_ticks, heartbeat_checks = heartbeat_checks,
    ticks_at = ticks_at, checks_at = checks_at, stats = support_runtime.loop_stats(),
  }
end

-- ══ 1. Ohne Verlust: Takt unveraendert ════════════════════════════════════
local hb_base = drive('heartbeat', 30, { modem = true })
assert_eq(hb_base.service_ticks, 60, 'heartbeat.lua: ohne Verlust ein Dienste-Takt je 0,5 s')
local mx_base = drive('matrix', 30, { modem = true })
assert_eq(mx_base.service_ticks, 60, 'matrix.lua: ohne Verlust ein Matrix-Takt je 0,5 s')
local hb_quiet = drive('heartbeat', 30)
assert_eq(hb_quiet.heartbeat_checks, 15, 'heartbeat.lua: ohne Funkverkehr eine Heartbeat-Pruefung je 2 s')

-- ══ 2. Der Dienste-Timer geht verloren ═══════════════════════════════════
--
-- Bis v813 standen damit Telemetrie, Discovery, Schirm und Quiesce-Pruefung
-- der ENERGY-Node bis zum Neustart.
do
  local r = drive('heartbeat', 45, { modem = true, drop = { svc = 10 } })
  local at_10s = r.ticks_at[10000]
  assert_true(at_10s and r.service_ticks > at_10s + 60,
    ('heartbeat.lua: die Dienste stehen nach EINEM verlorenen Timer still (Takte bei 10 s: %s, bei 45 s: %s)')
      :format(tostring(at_10s), tostring(r.service_ticks)))
  assert_true(r.service_ticks >= 87,
    ('heartbeat.lua: mehr als anderthalb Sekunden Pause nach dem Verlust (Takte: %d von 90)'):format(r.service_ticks))
  assert_eq(r.stats.energy_services.compensated, 1, 'heartbeat.lua: einmal ohne Dienste-Timer weitergemacht')
  assert_eq(r.stats.energy_services.lost, 1, 'heartbeat.lua: nach 30 s zaehlt der Timer als verloren')
end

-- ══ 3. Der Heartbeat-Timer geht verloren -- ohne Funkverkehr ═══════════════
--
-- Mit Funkverkehr pruefen auch eingehende Nachrichten, ob ein Heartbeat
-- faellig ist; ohne hing er allein an seinem Timer.
do
  local r = drive('heartbeat', 30, { drop = { hb = 3 } })
  assert_true(r.heartbeat_checks >= 13,
    ('heartbeat.lua: der Heartbeat bleibt nach EINEM verlorenen Timer aus (Pruefungen: %d, ohne Verlust 15)')
      :format(r.heartbeat_checks))
  assert_eq(r.stats.energy_heartbeat.compensated, 1, 'heartbeat.lua: einmal ohne Heartbeat-Timer weitergemacht')
  assert_eq(r.service_ticks, 60, 'heartbeat.lua: der Dienste-Takt bleibt davon unberuehrt')
end

-- ══ 4. Der Matrix-Timer geht verloren ════════════════════════════════════
do
  local r = drive('matrix', 45, { modem = true, drop = { matrix = 10 } })
  local at_10s = r.ticks_at[10000]
  assert_true(at_10s and r.service_ticks > at_10s + 60,
    ('matrix.lua: der Matrix-Thread steht nach EINEM verlorenen Timer still (Takte bei 10 s: %s, bei 45 s: %s)')
      :format(tostring(at_10s), tostring(r.service_ticks)))
  assert_true(r.service_ticks >= 87,
    ('matrix.lua: mehr als anderthalb Sekunden Pause nach dem Verlust (Takte: %d von 90)'):format(r.service_ticks))
  assert_eq(r.stats.energy_matrix.compensated, 1, 'matrix.lua: einmal ohne eigenen Timer weitergemacht')
end

print('ok energy_lost_timer_test')
