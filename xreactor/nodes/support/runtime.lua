local M = {}

function M.heartbeat_interval_ms(config)
  return math.max(1, tonumber(config.heartbeat_interval) or 2) * 1000
end

function M.make_presence(config, comms, ts_ms)
  return {
    ts = ts_ms,
    node_id = comms and comms.network and comms.network.id or config.node_id,
    role = config.role
  }
end

function M.init_logging(args)
  local utils = args.utils
  local config = args.config
  local cfg = args.runtime_config
  local config_meta = args.config_meta
  local config_warnings = args.config_warnings or {}

  local node_id = utils.read_node_id_or_generate(cfg.NODE_ID_PATH)
  local log_name = utils.build_log_name(cfg.LOG_NAME, node_id)
  local debug_enabled = config.debug_logging
  if cfg.DEBUG_LOG_ENABLED ~= nil then
    debug_enabled = cfg.DEBUG_LOG_ENABLED
  end
  if (config_meta and config_meta.reason) or #config_warnings > 0 then
    debug_enabled = true
  end

  local log_status = utils.init_logger({
    log_name = log_name,
    prefix = cfg.LOG_PREFIX,
    enabled = debug_enabled,
    truncate = config.reset_log_on_start == true
  })

  if log_status and log_status.enabled then
    utils.log(cfg.LOG_PREFIX, string.format("Logfile %s (startup=%s)", tostring(log_status.log_path), tostring(log_status.startup_action)), "INFO")
  end
  utils.log(cfg.LOG_PREFIX, "Startup", "INFO")
  if config_meta and config_meta.reason then
    utils.log(cfg.LOG_PREFIX, "Config issue (" .. tostring(config_meta.reason) .. ") at " .. tostring(config_meta.path) .. "; using defaults where needed.", "WARN")
  end
  for _, warning in ipairs(config_warnings) do
    utils.log(cfg.LOG_PREFIX, warning, "WARN")
  end

  return node_id, log_status
end

function M.warn_once(state, log_fn, key, message)
  state = state or {}
  state.warned = state.warned or {}
  if state.warned[key] then
    return
  end
  state.warned[key] = true
  log_fn(message, "WARN")
end


function M.safe_wrapped_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return false, "missing method"
  end
  return pcall(obj[method], ...)
end

local function is_terminate(err)
  return tostring(err or ""):lower():find("terminate", 1, true) ~= nil
end

-- Gemeinsamer Crash-Screen fuer FUEL/WATER/REPROCESSOR/ENERGY/VALVE (ueber
-- M.run_event_loop()): begrenzte Wartezeit statt unbegrenztem Warten auf
-- einen Tastendruck, danach automatischer Reboot. Persistente Crash-
-- Historie verlaengert die Wartezeit bei wiederholten Abstuerzen in
-- kurzer Folge, statt den Server im Sekundentakt mit Reboots zu belasten.
local CRASH_HISTORY_PATH = "/xreactor_role_crash_history.txt"
local CRASH_LOOP_WINDOW_S = 120
local CRASH_LOOP_THRESHOLD = 3
local CRASH_LOOP_WAIT_S = 300
local CRASH_NORMAL_WAIT_S = 20

local function read_crash_history()
  if not (fs and fs.exists and fs.exists(CRASH_HISTORY_PATH)) then return {} end
  local ok, handle = pcall(fs.open, CRASH_HISTORY_PATH, "r")
  if not ok or not handle then return {} end
  local content = handle.readAll() or ""
  handle.close()
  local out = {}
  for line in content:gmatch("[^\n]+") do
    local n = tonumber(line)
    if n then out[#out + 1] = n end
  end
  return out
end

local function record_crash_and_check_loop()
  local now = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
  local history = read_crash_history()
  local recent = {}
  for _, ts in ipairs(history) do
    if now - ts <= CRASH_LOOP_WINDOW_S then recent[#recent + 1] = ts end
  end
  recent[#recent + 1] = now
  pcall(function()
    local handle = fs.open(CRASH_HISTORY_PATH, "w")
    if handle then
      handle.write(table.concat(recent, "\n") .. "\n")
      handle.close()
    end
  end)
  return #recent >= CRASH_LOOP_THRESHOLD, #recent
end

local function crash_screen(err)
  local is_loop, crash_count = record_crash_and_check_loop()
  if term and term.setBackgroundColor and colors then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== NODE CRASH ===")
    term.setTextColor(colors.white)
    print("")
    print(tostring(err))
    print("")
    if is_loop then
      term.setTextColor(colors.red)
      print("!! CRASH-LOOP ERKANNT (" .. tostring(crash_count) .. " Abstuerze in " .. CRASH_LOOP_WINDOW_S .. "s) !!")
      print("Warte " .. CRASH_LOOP_WAIT_S .. "s vor dem naechsten Neustart-Versuch.")
      print("Bitte Ursache manuell pruefen (siehe Fehler oben).")
      print("")
    end
    term.setTextColor(colors.yellow)
    print("Automatischer Neustart in " .. (is_loop and CRASH_LOOP_WAIT_S or CRASH_NORMAL_WAIT_S) .. "s, oder Taste druecken...")
    term.setTextColor(colors.white)
  else
    print("CRASH: " .. tostring(err))
  end
  pcall(function()
    require("core.utils").log("RUNTIME", "Node-Absturz: " .. tostring(err) .. (is_loop and " [CRASH-LOOP]" or ""), "ERROR")
  end)
  local wait_s = is_loop and CRASH_LOOP_WAIT_S or CRASH_NORMAL_WAIT_S
  pcall(function()
    local timer_id = os.startTimer(wait_s)
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "key" then return end
      if ev[1] == "timer" and ev[2] == timer_id then return end
    end
  end)
  if os.reboot then os.reboot() end
end

-- Optionaler fuenfter Parameter "quiesce_opts" (Tabelle mit "handshake"
-- [core/update_handshake.lua-Objekt] und optional "on_quiesce" [Rueckgabe
-- true=bestaetigt sicher]) wird am Ende jedes Zyklus geprueft: ist
-- QUIESCE_REQUESTED gesetzt, wird on_quiesce() aufgerufen (rollenspezifische
-- Aktorlogik); bestaetigt sie einen sicheren Zustand, markiert diese
-- Funktion SAFE_OUTPUTS_APPLIED+RUNTIME_STOPPED und die Schleife endet
-- sauber, statt (wie vor diesem Parameter) nur durch Absturz oder
-- "terminate"-Event beendbar zu sein. Ohne quiesce_opts unveraendertes
-- Verhalten.
-- TEMP DIAGNOSTIC (2026-09-06): einmalig pro Quiesce-Request loggen, ob
-- dieser Zweig ueberhaupt erreicht wird -- Feld-Reports zeigen "Quiesce-
-- Timeout -- Rolle bleibt aktiv" nach voller 60s-Wartezeit bei mehreren
-- Rollen, was bedeuten wuerde, dass mark_quiesce_attempted() nie lief.
-- Diese Zeile beweist/widerlegt das direkt im Rollen-Log. Geteilt zwischen
-- run_event_loop() und run_fast_loop() statt dort dupliziert -- flag ist ein
-- Tabellen-Wrapper (nicht ein einfacher Bool-Rueckgabewert), damit die
-- aufrufende Schleife ihn wie einen lokalen Zustand mutieren kann.
local function log_quiesce_seen_once(flag)
  if flag.seen then return end
  flag.seen = true
  pcall(function()
    require("core.utils").log("RUNTIME", "quiesce request erkannt (Diagnose)", "INFO")
  end)
end

-- Quiesce-Pruefung, geteilt zwischen run_event_loop() und run_fast_loop()
-- (vorher in beiden dupliziert). Rueckgabe true = Runtime darf/soll enden.
--
-- Der Ruecknahme-Zweig (on_quiesce_cancelled) ist sicherheitsrelevant, kein
-- Aufraeumen: core/update_handshake.lua's reset() storniert einen Quiesce-
-- Request ausdruecklich nur, "while the role is still running" -- die Rolle
-- laeuft danach also weiter und MUSS ihren Sicherheitszustand wieder
-- verlassen. Genau das fehlte: on_quiesce() setzt bei RT/FUEL eine Sperre
-- (rt_update_quiescing bzw. _state.quiesce), die die gesamte Regelung bzw.
-- jede Lieferung unterdrueckt, und diese Sperre hatte keinen Rueckweg.
-- Bestaetigt die Rolle den sicheren Zustand nicht innerhalb des Update-
-- Fensters (bei RT muessen ALLE Turbinen Flow 0 + Coil + inaktiv
-- zurueckmelden -- mit 50 Turbinen deutlich wahrscheinlicher unvollstaendig
-- als mit 25) und bricht der Updater danach ab (installer/auto_update.lua's
-- recover_unexpected() ruft im Zustand QUIESCE_REQUESTED reset(), OHNE
-- Reboot), blieb die Node dauerhaft in diesem Zustand: Flow 0 auf allen
-- Turbinen, Coils eingehaengt, v2-Regelung tot -- waehrend die Anzeige
-- weiter Drehzahlen las und "einlernen" behauptete, weil der Status-
-- Snapshot die Hardware unabhaengig von control_tick() abfragt. Nur ein
-- Reboot half.
local function run_quiesce_check(handshake_lib, quiesce_opts, quiesce_seen)
  if not handshake_lib then return false end
  if handshake_lib.is_quiesce_requested(quiesce_opts.handshake) then
    log_quiesce_seen_once(quiesce_seen)
    quiesce_seen.attempted = true
    handshake_lib.mark_quiesce_attempted(quiesce_opts.handshake)
    -- Fail-closed default: ohne echtes on_quiesce-Ergebnis gilt der
    -- Quiesce-Vorgang nicht als bestaetigt.
    local confirmed = false
    if type(quiesce_opts.on_quiesce) == "function" then
      local ok3, result3 = pcall(quiesce_opts.on_quiesce)
      if ok3 then
        -- Safety acknowledgement is fail-closed: nil/omitted results are
        -- not proof that physical outputs reached their safe state.
        confirmed = result3 == true
      else
        confirmed = false
        pcall(function()
          require("core.utils").log("RUNTIME", "on_quiesce error: " .. tostring(result3), "ERROR")
        end)
      end
    end
    if confirmed then
      handshake_lib.mark_safe_outputs_applied(quiesce_opts.handshake)
      handshake_lib.mark_runtime_stopped(quiesce_opts.handshake)
      return true
    end
    return false
  end
  quiesce_seen.seen = false
  if quiesce_seen.attempted then
    quiesce_seen.attempted = false
    if type(quiesce_opts.on_quiesce_cancelled) == "function" then
      local ok4, err4 = pcall(quiesce_opts.on_quiesce_cancelled)
      if not ok4 then
        pcall(function()
          require("core.utils").log("RUNTIME",
            "on_quiesce_cancelled error: " .. tostring(err4), "ERROR")
        end)
      end
    end
  end
  return false
end

function M.run_event_loop(receive_timeout, services, comms, after_cycle, quiesce_opts)
  local handshake_lib = quiesce_opts and require("core.update_handshake") or nil
  local quiesce_seen = { seen = false } -- TEMP DIAGNOSTIC, see log_quiesce_seen_once() above
  local ok, err = xpcall(function()
    while true do
      local timer = os.startTimer(receive_timeout)
      while true do
        local event = { os.pullEvent() }
        if event[1] == "modem_message" then
          comms:handle_event(event)
          services:tick(nil, event)
        elseif event[1] == "timer" and event[2] == timer then
          break
        elseif event[1] == "monitor_touch" or event[1] == "mouse_click" or event[1] == "key"
            or event[1] == "monitor_resize" or event[1] == "term_resize" then
          services:tick(nil, event)
        end
      end
      if type(after_cycle) == "function" then
        local ok2, err2 = pcall(after_cycle)
        if not ok2 then
          -- Fehler in after_cycle loggen aber nicht crashen
          pcall(function()
            require("core.utils").log("RUNTIME", "after_cycle error: " .. tostring(err2), "ERROR")
          end)
        end
      end
      services:tick()
      if run_quiesce_check(handshake_lib, quiesce_opts, quiesce_seen) then
        return
      end
    end
  end, function(e) return e end)
  if ok then return end
  if is_terminate(err) then return end
  crash_screen(err)
end

-- Exportiert, damit ENERGY und MASTER (eigene Crash-Handling-Einstiegspunkte,
-- nicht ueber M.run_event_loop()) dieselbe Logik wiederverwenden koennen.
M.crash_screen = crash_screen
M.is_terminate = is_terminate

-- run_fast_loop()/run_slow_loop(): entkoppelte Zwei-Coroutinen-Variante von
-- run_event_loop(), fuer FUEL/WATER/REPROCESSOR/RT/VALVE (siehe deren
-- main.lua, per parallel.waitForAny(fast, slow) verdrahtet). Hintergrund:
-- run_event_loop() tickt ALLE Services (UI eingeschlossen) streng
-- nacheinander in EINER Coroutine -- ein einzelner langsamer/blockierender
-- Service (Discovery-Scan, ME-Bridge-Export) friert dadurch bis zu seiner
-- eigenen Laufzeit lang auch Touch-Eingabe und Ventil-Sicherheitslogik ein.
-- CC:Tweaked hat keine echten Threads: parallel.waitForAny/All wechselt nur
-- an os.pullEvent()/os.sleep()-Punkten -- ein synchroner Peripherie-Call
-- gibt die Kontrolle waehrend seiner Laufzeit trotzdem NICHT ab und blockiert
-- dann beide Coroutinen gemeinsam (die gesamte Lua-VM ist einsträngig). Diese
-- Aufteilung verhindert also nicht jede Blockade, sondern nur, dass ein
-- langsamer Service in der "slow"-Gruppe VOR jedem UI-/Touch-/Sicherheits-
-- Tick in derselben sequentiellen Liste stehen muss -- exakt das Muster, das
-- nodes/energy/matrix.lua + heartbeat.lua bereits fuer ENERGY nutzen.
--
-- run_fast_loop(opts): opts = { receive_timeout, services, comms,
--   after_cycle (optional, rollenspezifische guenstige/zeitkritische Arbeit,
--   z.B. redstone_router:tick() -- treibt eine laufende Ventil-Transaktion
--   voran, macht aber selbst keine blockierenden Peripherie-Calls),
--   quiesce_opts (optional, wie bei run_event_loop) }. Bekommt jedes Event
--   (modem_message/Touch/Taste/Resize) UND tickt periodisch alle
--   opts.services -- identisch zum bisherigen run_event_loop(), nur ohne die
--   "slow"-Services in derselben Liste.

-- ── Warten auf den naechsten Takt -- ohne an EINEM Timer zu haengen ────────
--
-- Bis v811 warteten beide Schleifen auf genau EIN Timer-Ereignis: die
-- schnelle brach ihre Warteschleife nur bei genau ihrem Timer ab, die
-- langsame rief os.sleep() -- und CC:Tweakeds os.sleep() (bios.lua) wartet
-- ebenfalls auf genau diesen einen Timer und ignoriert jeden anderen.
--
-- CC:Tweaked VERWIRFT aber Ereignisse, sobald 256 in der Warteschlange eines
-- Rechners stehen (ComputerExecutor.QUEUE_LIMIT) -- Timer eingeschlossen,
-- stillschweigend. Ging der eine Timer verloren, wartete die Schleife fuer
-- immer: nichts stellte einen neuen, alle anderen Ereignisse liefen ein und
-- wurden ignoriert.
--
-- Im Betrieb (2026-10) hing so die RT-Node nach dem Laden der Anlage-Chunks,
-- und erst ein Neustart half. Dort prasseln mit Abstand die meisten
-- Peripherie-Ereignisse ein. Die schnelle Schleife verlor ihren periodischen
-- Takt -- nur dort tickt die Regelung; Ereignisse wecken nur Comms und
-- Schirm, der Schirm zeigte also weiter lebende Drehzahlen. Die langsame
-- verlor Discovery und Telemetrie, MASTER und FUEL bekamen keine Daten mehr.
--
-- Jetzt geht es weiter, wenn der eigene Timer eintrifft ODER wenn bei
-- irgendeinem Ereignis das Intervall plus LOST_TIMER_GRACE_S verstrichen ist.
-- Gemessen wird mit os.clock(): in CC:Tweaked zaehlt das Servertakte
-- (OSAPI.clock = Takte * 0.05) -- dieselbe Zeitbasis wie os.startTimer(),
-- monoton, ohne Spruenge der Weltuhr. Andere Ereignisse gibt es staendig:
-- Funknachrichten der anderen Knoten und die Timer der jeweils anderen
-- Schleife. Ein verlorener Timer kostet damit gut eine Sekunde statt eines
-- Neustarts.
--
-- Bewusstes Rest-Risiko: geht der eigene Timer verloren UND kommt danach gar
-- kein Ereignis mehr, wartet die Schleife weiter. Das hiesse, auch der Timer
-- der anderen Schleife ist im selben Moment verloren und es herrscht
-- Funkstille -- in einer Anlage mit vielen Knoten praktisch ausgeschlossen.
--
-- Sichtbar, weil es sonst niemand erfaehrt: M.loop_stats() zaehlt je
-- Schleife, wie oft ohne eigenen Timer weitergemacht wurde (compensated),
-- wie viele der aufgegebenen Timer doch noch kamen, nur zu spaet (late), und
-- wie viele nie (lost). Test: tests/runtime_lost_timer_test.lua.

-- Wie lange ueber das Intervall hinaus auf den EIGENEN Timer gewartet wird.
-- Im Normalbetrieb kommt er puenktlich; mehr als eine Sekunde zu spaet heisst
-- Stau oder Verlust, und in beiden Faellen ist der Takt faellig.
local LOST_TIMER_GRACE_S = 1.0
-- Ab wann ein aufgegebener Timer als VERLOREN zaehlt. Ein verworfenes
-- Ereignis stellt CC:Tweaked nie nach; ein nur gestautes kommt binnen
-- Sekunden.
local LOST_TIMER_AFTER_S = 30
-- Hoechstens eine Logzeile je Schleife in diesem Abstand.
local LOST_TIMER_LOG_INTERVAL_S = 60

local function new_loop_stats()
  return { ticks = 0, compensated = 0, late = 0, lost = 0, last_tick_clock = nil, last_log_clock = nil }
end

local loop_stats = { fast = new_loop_stats(), slow = new_loop_stats() }

local function clock_s()
  local ok, value = pcall(os.clock)
  if ok and type(value) == "number" then return value end
  return nil
end

-- Je Schleife und als Summe -- fuer Schirm und Status der Rollen.
function M.loop_stats()
  local out = { lost = 0, late = 0, compensated = 0 }
  for name, stats in pairs(loop_stats) do
    out[name] = {
      ticks = stats.ticks, compensated = stats.compensated,
      late = stats.late, lost = stats.lost, last_tick_clock = stats.last_tick_clock,
    }
    out.lost = out.lost + stats.lost
    out.late = out.late + stats.late
    out.compensated = out.compensated + stats.compensated
  end
  return out
end

-- Wartet einen Takt (siehe oben). on_event bekommt jedes Ereignis ausser dem
-- eigenen Timer; abandoned merkt sich aufgegebene eigene Timer. true, wenn
-- ohne den eigenen Timer weitergemacht wurde.
local function wait_cycle(stats, abandoned, interval_s, on_event)
  local started = clock_s()
  local deadline_s = (tonumber(interval_s) or 0) + LOST_TIMER_GRACE_S
  local timer = os.startTimer(interval_s)
  while true do
    local event = { os.pullEvent() }
    if event[1] == "timer" then
      if event[2] == timer then return false end
      if abandoned[event[2]] then
        -- Ein frueher aufgegebener eigener Timer: kam doch noch, nur spaet.
        abandoned[event[2]] = nil
        stats.late = stats.late + 1
      end
    end
    if on_event then on_event(event) end
    local now = clock_s()
    if started and now and now - started >= deadline_s then
      abandoned[timer] = now
      stats.compensated = stats.compensated + 1
      return true
    end
  end
end

-- Aufgegebene Timer, die nach LOST_TIMER_AFTER_S noch fehlen, sind verloren.
local function settle_abandoned(stats, abandoned, label)
  local now = clock_s()
  if not now then return end
  for id, since in pairs(abandoned) do
    if now - since >= LOST_TIMER_AFTER_S then
      abandoned[id] = nil
      stats.lost = stats.lost + 1
      if not stats.last_log_clock or now - stats.last_log_clock >= LOST_TIMER_LOG_INTERVAL_S then
        stats.last_log_clock = now
        pcall(function()
          require("core.utils").log("RUNTIME", string.format(
            "%s Schleife: Timer verloren (insgesamt %d, verspaetet %d) -- Ereignis-Warteschlange"
              .. " uebergelaufen? Der Takt lief ohne ihn weiter.", label, stats.lost, stats.late), "WARN")
        end)
      end
    end
  end
end

local function begin_cycle(stats, abandoned, label)
  settle_abandoned(stats, abandoned, label)
  stats.ticks = stats.ticks + 1
  stats.last_tick_clock = clock_s()
end

-- Taktgeber fuer eine Schleife, die ihren Takt selbst wartet -- dieselbe
-- Mechanik wie die beiden Schleifen unten. MASTERs eigene Schleife
-- (master/loop.lua) nutzt ihn: sie hatte denselben Fehler. Liefert
-- wait(interval_s, on_event); die Zaehler stehen in M.loop_stats()[name],
-- und wait() gibt true zurueck, wenn ohne eigenen Timer weitergemacht wurde.
function M.make_cycle_waiter(name, label)
  local stats, abandoned = new_loop_stats(), {}
  loop_stats[name] = stats
  return function(interval_s, on_event)
    local compensated = wait_cycle(stats, abandoned, interval_s, on_event)
    begin_cycle(stats, abandoned, label or name)
    return compensated
  end
end

function M.run_fast_loop(opts)
  local receive_timeout = opts.receive_timeout
  local services = opts.services
  local comms = opts.comms
  local after_cycle = opts.after_cycle
  local quiesce_opts = opts.quiesce_opts
  local handshake_lib = quiesce_opts and require("core.update_handshake") or nil
  local quiesce_seen = { seen = false } -- TEMP DIAGNOSTIC, see log_quiesce_seen_once() above
  local wait_for_cycle = M.make_cycle_waiter("fast", "Schnelle")
  local function dispatch(event)
    if event[1] == "modem_message" then
      comms:handle_event(event)
      services:tick(nil, event)
    elseif event[1] == "monitor_touch" or event[1] == "mouse_click" or event[1] == "key"
        or event[1] == "monitor_resize" or event[1] == "term_resize" then
      services:tick(nil, event)
    end
  end
  while true do
    wait_for_cycle(receive_timeout, dispatch)
    services:tick()
    if type(after_cycle) == "function" then
      local ok2, err2 = pcall(after_cycle)
      if not ok2 then
        pcall(function()
          require("core.utils").log("RUNTIME", "fast-loop after_cycle error: " .. tostring(err2), "ERROR")
        end)
      end
    end
    if run_quiesce_check(handshake_lib, quiesce_opts, quiesce_seen) then
      return
    end
  end
end

-- run_slow_loop(opts): opts = { interval, services, after_cycle (optional,
--   rollenspezifische Hintergrundarbeit, die tatsaechlich lange/blockierende
--   Peripherie-Calls machen darf, z.B. logistics_router:export). Keine
--   Event-Verarbeitung (Ereignisse wecken sie nur, siehe wait_cycle), keine
--   Quiesce-Pruefung (die lebt in run_fast_loop) -- rein periodisches Ticken
--   auf eigenem Takt, damit ein langsamer Aufruf hier UI/Touch/Ventil-
--   Sicherheit in run_fast_loop nur so lange blockiert, wie der Aufruf selbst
--   dauert, statt zusaetzlich hinter allen anderen Services in einer
--   gemeinsamen Liste anstehen zu muessen.
--
-- Hier stand os.sleep(interval). Das wartet auf genau einen Timer -- siehe
-- wait_cycle oben, warum das die Schleife fuer immer stilllegen konnte.
function M.run_slow_loop(opts)
  local interval = opts.interval
  local services = opts.services
  local after_cycle = opts.after_cycle
  local wait_for_cycle = M.make_cycle_waiter("slow", "Langsame")
  while true do
    wait_for_cycle(interval, nil)
    local ok, err = pcall(function() services:tick() end)
    if not ok then
      pcall(function()
        require("core.utils").log("RUNTIME", "slow-loop tick error: " .. tostring(err), "ERROR")
      end)
    end
    if type(after_cycle) == "function" then
      local ok2, err2 = pcall(after_cycle)
      if not ok2 then
        pcall(function()
          require("core.utils").log("RUNTIME", "slow-loop after_cycle error: " .. tostring(err2), "ERROR")
        end)
      end
    end
  end
end

return M
