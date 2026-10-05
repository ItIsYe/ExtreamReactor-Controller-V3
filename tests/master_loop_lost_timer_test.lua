package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Ein verlorenes Timer-Ereignis darf MASTERs Schleife nicht stilllegen.
--
-- master/loop.lua wartete bis v812 auf genau EIN Timer-Ereignis (0,5 s) und
-- fuehrte erst danach den periodischen Takt aus -- und nur dort laufen
-- Heartbeat, Status, Befehle (rt_sync) und das Neuzeichnen des Schirms.
-- Funknachrichten nimmt die Schleife nur entgegen, Beruehrungen loesen
-- einen Ereignis-Takt aus.
--
-- CC:Tweaked verwirft Ereignisse, sobald 256 in der Warteschlange stehen
-- (ComputerExecutor.QUEUE_LIMIT), Timer eingeschlossen. MASTER empfaengt die
-- Nachrichten ALLER Knoten -- ein Ueberlauf ist dort am wahrscheinlichsten,
-- etwa wenn nach einem Update alle Knoten gleichzeitig neu starten.
--
-- Im Betrieb (2026-10-05, mit v812) genau so passiert: MASTERs Schirm
-- aenderte sich nur noch beim Antippen, alle RT-Knoten zeigten MASTER DOWN,
-- und Aenderungen kamen bei den Knoten nicht mehr an. Erst ein Neustart von
-- MASTER half.
--
-- Der Test faehrt die ECHTE Schleife (master/loop.lua's M.run) gegen eine
-- simulierte CC-Umgebung, mit Funknachrichten alle 50 ms -- und dann geht
-- genau EIN eigener Timer verloren.

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local STEP_MS = 50

-- Faehrt MASTERs Schleife ueber `seconds` simulierte Sekunden; der n-te
-- eigene Timer geht verloren, wenn drop[n] gesetzt ist.
local function drive(seconds, drop)
  drop = drop or {}
  local now_ms, next_id, timers = 0, 0, {}
  os.clock = function() return now_ms / 1000 end
  os.epoch = function() return 1700000000000 + now_ms end
  os.startTimer = function(s)
    next_id = next_id + 1
    timers[next_id] = now_ms + math.floor((tonumber(s) or 0) * 1000 + 0.5)
    return next_id
  end
  os.cancelTimer = function(id) timers[id] = nil end
  os.pullEvent = function(filter) return coroutine.yield(filter) end
  os.pullEventRaw = os.pullEvent

  local printed = {}
  local real_print = print
  _G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, ' ')
  end

  -- Die optionalen Teile der Schleife (Ampel, Remote-Update) brauchen hier
  -- keine echte Umgebung.
  package.loaded['optional.master_ampel'] = { update = function() end }
  package.loaded['core.remote_update'] = {}
  package.loaded['nodes.support.runtime'] = nil
  package.loaded['master.loop'] = nil
  local support_runtime = require('nodes.support.runtime')
  local loop = require('master.loop')

  local periodic, on_event, modem = 0, 0, 0
  local runtime = {
    log = function() end,
    state = { nodes = {} },
    refs = {
      services = { tick = function(_, _, event)
        if event == nil then periodic = periodic + 1 else on_event = on_event + 1 end
      end },
      comms = { handle_event = function() modem = modem + 1 end },
    },
  }

  local co = coroutine.create(function() loop.run(runtime, {}) end)
  local ok, filter = coroutine.resume(co)
  assert(ok, filter)
  local own, modem_at = 0, 50
  local periodic_at = {}
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
      own = own + 1
      if not drop[own] then events[#events + 1] = { 'timer', id } end
    end
    if now_ms >= modem_at then
      modem_at = modem_at + 50
      events[#events + 1] = { 'modem_message', 'back', 1, 1, {}, 1 }
    end
    for _, ev in ipairs(events) do
      if filter == nil or filter == ev[1] then
        ok, filter = coroutine.resume(co, table.unpack(ev))
        assert(ok, filter)
      end
    end
    periodic_at[now_ms] = periodic
  end
  _G.print = real_print
  return {
    periodic = periodic, modem = modem, periodic_at = periodic_at,
    printed = printed, support_runtime = support_runtime,
  }
end

-- ══ 1. Ohne Verlust: ein Takt je 0,5 s ═══════════════════════════════════
local baseline = drive(30)
assert_eq(baseline.periodic, 60, 'ohne Verlust ein periodischer Takt je 0,5 s')

-- ══ 2. Ein eigener Timer geht verloren ═══════════════════════════════════
--
-- Genau der Feldfall: die Schleife muss weitertakten -- hoechstens gut
-- anderthalb Sekunden Pause (0,5 s plus Schonzeit), dann wie vorher.
local dropped = drive(45, { [10] = true })
local after_drop = dropped.periodic_at[10000]
assert_true(after_drop and dropped.periodic > after_drop + 60,
  ('MASTERs Schleife steht nach EINEM verlorenen Timer still (Takte bei 10 s: %s, bei 45 s: %s)')
    :format(tostring(after_drop), tostring(dropped.periodic)))
assert_true(dropped.periodic >= 87,
  ('mehr als anderthalb Sekunden Pause nach dem Verlust (Takte: %d von 90)'):format(dropped.periodic))
assert_eq(dropped.modem, 900, 'jede Funknachricht muss weiter ankommen')

-- ══ 3. Zaehler und Meldung ═══════════════════════════════════════════════
--
-- MASTER hat keinen Diagnose-Schirm wie die RT-Node; ohne Meldung erfuehre
-- niemand, dass es passiert ist.
do
  local s = baseline.support_runtime.loop_stats().master
  assert_true(s ~= nil, 'loop_stats() muss die MASTER-Schleife fuehren')
  assert_eq(s.compensated, 0, 'ohne Verlust kein Ausgleich')
  assert_eq(#baseline.printed, 0, 'ohne Verlust keine Meldung')

  s = dropped.support_runtime.loop_stats().master
  assert_eq(s.compensated, 1, 'einmal ohne eigenen Timer weitergemacht')
  assert_eq(s.lost, 1, 'nach 30 s zaehlt der Timer als verloren')
  local notice = false
  for _, line in ipairs(dropped.printed) do
    if line:find('[MASTER]', 1, true) and line:find('Timer', 1, true) then notice = true end
  end
  assert_true(notice, 'MASTER muss den ausgebliebenen Timer auf dem eigenen Terminal melden')
end

print('ok master_loop_lost_timer_test')
