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

  local node_id = utils.read_node_id(cfg.NODE_ID_PATH)
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

-- Feature (2026-07-13): SHARED-P0.2 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md). Dieser Crash-Screen wird von FUEL/WATER/
-- REPROCESSOR/ENERGY/VALVE gemeinsam genutzt (ueber M.run_event_loop()) --
-- wartete bisher UNBEGRENZT auf einen physischen Tastendruck, bevor
-- ueberhaupt rebootet wurde. Das widerspricht unbeaufsichtigtem Betrieb
-- komplett: ein Rollenprozess, der seinen eigenen Fehler abfaengt (genau
-- dieser Pfad hier, xpcall in run_event_loop), blieb OHNE physische
-- Anwesenheit fuer immer auf diesem Screen haengen -- start.lua's eigener
-- automatischer Reboot-Pfad fuer ungefangene Fehler wird NICHT erreicht,
-- weil der Fehler ja bereits HIER gefangen wurde. Derselbe Fix wie schon
-- beim LOG_COLLECTOR (2026-07-07 fuer den Basis-Timeout, 2026-07-11 fuer
-- die Crash-Loop-Erkennung): begrenzte Wartezeit + automatischer Reboot,
-- plus persistente Crash-Historie, die bei wiederholten Abstuerzen in
-- kurzer Folge die Wartezeit deutlich verlaengert statt den Server im
-- Sekundentakt mit Reboots zu belasten.
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

-- Fix (2026-07-17): CRITICAL. INSTALL-P0.2 aus docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md (Abschnitt 4). Bisher gab es HIER (dem
-- gemeinsamen Event-Loop von RT/VALVE/FUEL/REPROCESSOR/WATER) ueberhaupt
-- keinen kontrollierten Weg, die Schleife zu verlassen -- nur ein Absturz
-- oder ein "terminate"-Event konnten sie beenden. Ein Auto-Update konnte
-- also Dateien ersetzen, WAEHREND die Rolle weiter Hardware steuerte. Der
-- optionale fuenfte Parameter "quiesce_opts" (Tabelle mit "handshake"
-- [core/update_handshake.lua-Objekt] und optional "on_quiesce"
-- [Rueckgabewert true=bestaetigt sicher, false/nil=noch nicht]) wird am
-- Ende jedes Zyklus geprueft: ist QUIESCE_REQUESTED gesetzt, wird
-- on_quiesce() aufgerufen (rollenspezifische Aktorlogik, z.B. Ventil
-- schliessen/Foerderung stoppen); bestaetigt sie einen sicheren Zustand,
-- markiert diese Funktion SAFE_OUTPUTS_APPLIED+RUNTIME_STOPPED und die
-- Schleife endet SAUBER (kein Fehler, kein Crash) -- bestaetigt sie noch
-- nichts, wird im naechsten Zyklus erneut versucht. Ohne quiesce_opts
-- (bestehende Aufrufer) aendert sich nichts am bisherigen Verhalten.
function M.run_event_loop(receive_timeout, services, comms, after_cycle, quiesce_opts)
  local handshake_lib = quiesce_opts and require("core.update_handshake") or nil
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
      if handshake_lib and handshake_lib.is_quiesce_requested(quiesce_opts.handshake) then
        handshake_lib.mark_quiesce_attempted(quiesce_opts.handshake)
        local confirmed = quiesce_opts.no_actuators == true
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
          return
        end
      end
    end
  end, function(e) return e end)
  if ok then return end
  if is_terminate(err) then return end
  crash_screen(err)
end

-- Feature (2026-07-13): SHARED-P0.2. Als M.crash_screen exportiert, damit
-- ENERGY und MASTER (die ihre eigenen, separaten Crash-Handling-
-- Einstiegspunkte haben, nicht ueber M.run_event_loop() laufen) dieselbe
-- Logik wiederverwenden koennen, statt sie zu duplizieren.
M.crash_screen = crash_screen

return M
