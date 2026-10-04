package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Ein verlorenes Timer-Ereignis darf keine Lauf-Schleife stilllegen.
--
-- CC:Tweaked verwirft Ereignisse, sobald 256 in der Warteschlange eines
-- Rechners stehen (ComputerExecutor.QUEUE_LIMIT) -- Timer eingeschlossen,
-- stillschweigend. Bis v811 warteten beide Schleifen aus
-- nodes/support/runtime.lua auf genau EIN Timer-Ereignis: die schnelle brach
-- ihre Warteschleife nur bei genau ihrem Timer ab, die langsame rief
-- os.sleep(), das ebenfalls auf genau einen Timer wartet und jeden anderen
-- ignoriert. Ging dieser eine Timer verloren, stand die Schleife fuer immer
-- still -- erst ein Neustart half.
--
-- Im Betrieb (2026-10) hing so die RT-Node nach dem Laden der Anlage-Chunks:
-- die schnelle Schleife verlor ihren periodischen Takt (nur dort tickt die
-- Regelung; Ereignisse wecken nur Comms und Schirm, der Schirm zeigte also
-- weiter lebende Drehzahlen), die langsame Discovery und Telemetrie (MASTER
-- und FUEL bekamen keine Daten mehr).
--
-- Dieser Test faehrt die ECHTEN Schleifen gegen eine simulierte CC-Umgebung:
-- Servertakte, Timer, und os.sleep() wortgetreu aus CC:Tweakeds bios.lua.
-- Neben den eigenen Timern laufen, wie im Spiel, fremde Ereignisse ein: der
-- Timer der jeweils anderen Schleife alle 100 ms und Funknachrichten alle
-- 50 ms. Dann geht genau EIN eigener Timer verloren.

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local INTERVAL_S = 0.1   -- wie CONFIG.RECEIVE_TIMEOUT der RT-Node
local STEP_MS = 50

-- Faehrt eine Schleife ueber `seconds` simulierte Sekunden.
--   loop     'fast' oder 'slow'
--   drop     { [n] = true }  der n-te eigene Timer geht verloren
--   delay_ms { [n] = ms }    der n-te eigene Timer kommt so viel zu spaet
local function drive(loop, seconds, drop, delay_ms)
  drop, delay_ms = drop or {}, delay_ms or {}
  local now_ms, next_id, timers, late_queue = 0, 0, {}, {}
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
  -- CC:Tweaked bios.lua, unveraendert.
  os.sleep = function(n)
    local timer = os.startTimer(n or 0)
    repeat
      local _, param = os.pullEvent('timer')
    until param == timer
  end

  local periodic, on_event = 0, 0
  local services = { tick = function(_, _, event)
    if event == nil then periodic = periodic + 1 else on_event = on_event + 1 end
  end }
  local comms = { handle_event = function() end }

  package.loaded['nodes.support.runtime'] = nil
  local runtime = require('nodes.support.runtime')
  local co = coroutine.create(function()
    if loop == 'slow' then
      runtime.run_slow_loop({ interval = INTERVAL_S, services = services })
    else
      runtime.run_fast_loop({ receive_timeout = INTERVAL_S, services = services, comms = comms })
    end
  end)

  local ok, filter = coroutine.resume(co)
  assert(ok, filter)
  local own, foreign_at, modem_at = 0, 100, 50
  local periodic_at = {}
  for step = 1, math.floor(seconds * 1000 / STEP_MS) do
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
      if drop[own] then
        -- Warteschlange voll: verworfen.
      elseif delay_ms[own] then
        late_queue[#late_queue + 1] = { at = now_ms + delay_ms[own], id = id }
      else
        events[#events + 1] = { 'timer', id }
      end
    end
    for index = #late_queue, 1, -1 do
      if late_queue[index].at <= now_ms then
        events[#events + 1] = { 'timer', late_queue[index].id }
        table.remove(late_queue, index)
      end
    end
    if now_ms >= foreign_at then
      foreign_at = foreign_at + 100
      events[#events + 1] = { 'timer', 1000000 + step }
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
  return {
    periodic = periodic, on_event = on_event, periodic_at = periodic_at, runtime = runtime,
  }
end

local function stats_of(result, loop)
  assert_true(type(result.runtime.loop_stats) == 'function',
    'nodes/support/runtime.lua muss loop_stats() anbieten')
  return result.runtime.loop_stats()[loop]
end

-- ══ 1. Ohne Verlust: Takt unveraendert ════════════════════════════════════
--
-- Der Fix darf den Normalbetrieb nicht beruehren: genau ein Takt je
-- Intervall, nicht mehr. (Die Zaehler dazu stehen unten in 4 -- zuerst wird
-- das VERHALTEN geprueft, damit der Test auf dem alten Stand aus dem
-- richtigen Grund scheitert und nicht an der fehlenden loop_stats().)
local baseline = {}
for _, loop in ipairs({ 'slow', 'fast' }) do
  baseline[loop] = drive(loop, 30)
  assert_eq(baseline[loop].periodic, 300, loop .. ': ohne Verlust ein Takt je 100 ms')
end

-- ══ 2. Ein eigener Timer geht verloren ═══════════════════════════════════
--
-- Genau der Feldfall. Die Schleife muss weitertakten -- hoechstens gut eine
-- Sekunde Pause (Intervall plus LOST_TIMER_GRACE_S), dann wie vorher.
local dropped = {}
for _, loop in ipairs({ 'slow', 'fast' }) do
  local r = drive(loop, 45, { [20] = true })
  local after_drop = r.periodic_at[5000]
  assert_true(after_drop and r.periodic > after_drop + 350,
    ('%s: die Schleife steht nach EINEM verlorenen Timer still (Takte bei 5 s: %s, bei 45 s: %s)')
      :format(loop, tostring(after_drop), tostring(r.periodic)))
  assert_true(r.periodic >= 430,
    ('%s: mehr als gut eine Sekunde Pause nach dem Verlust (Takte: %d von 450)'):format(loop, r.periodic))
  dropped[loop] = r
end

-- Die schnelle Schleife verarbeitet ihre Ereignisse dabei weiter.
do
  local r = drive('fast', 45, { [20] = true })
  assert_eq(r.on_event, 900, 'fast: jede Funknachricht muss weiter ankommen')
end

-- ══ 3. Zaehler: Normalbetrieb und Verlust ════════════════════════════════
for _, loop in ipairs({ 'slow', 'fast' }) do
  local s = stats_of(baseline[loop], loop)
  assert_eq(s.lost, 0, loop .. ': ohne Verlust kein verlorener Timer')
  assert_eq(s.late, 0, loop .. ': ohne Verlust kein verspaeteter Timer')
  assert_eq(s.compensated, 0, loop .. ': ohne Verlust kein Ausgleich')
  s = stats_of(dropped[loop], loop)
  assert_eq(s.compensated, 1, loop .. ': einmal ohne eigenen Timer weitergemacht')
  assert_eq(s.lost, 1, loop .. ': nach 30 s zaehlt der Timer als verloren')
  assert_eq(s.late, 0, loop .. ': ein verlorener Timer ist nicht verspaetet')
end

-- ══ 4. Ein eigener Timer kommt nur zu spaet ══════════════════════════════
--
-- Ein Stau ist kein Verlust: die Schleife macht nach der Schonzeit weiter,
-- und wenn der alte Timer doch noch kommt, zaehlt er als verspaetet -- nicht
-- als verloren. Sonst wuerde der Zaehler, der den Feldbefund belegen soll,
-- falschen Alarm geben.
for _, loop in ipairs({ 'slow', 'fast' }) do
  local r = drive(loop, 45, nil, { [20] = 2000 })
  local s = stats_of(r, loop)
  assert_eq(s.compensated, 1, loop .. ': bei 2 s Verspaetung einmal ohne eigenen Timer weitergemacht')
  assert_eq(s.late, 1, loop .. ': der verspaetete Timer muss als verspaetet zaehlen')
  assert_eq(s.lost, 0, loop .. ': ein verspaeteter Timer ist nicht verloren')
  assert_true(r.periodic >= 430, loop .. ': auch ein Stau darf den Takt nicht lange anhalten')
end

-- ══ 5. Summen fuer Schirm und Status ═════════════════════════════════════
do
  local r = drive('slow', 60, { [20] = true, [100] = true })
  local all = r.runtime.loop_stats()
  assert_eq(all.slow.lost, 2, 'zwei verlorene Timer in der langsamen Schleife')
  assert_eq(all.lost, 2, 'loop_stats().lost summiert ueber beide Schleifen')
end

print('ok runtime_lost_timer_test')
