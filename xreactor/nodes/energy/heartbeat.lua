-- nodes/energy/heartbeat.lua
-- Heartbeat-Thread für die Energy-Node.
-- Läuft in einer eigenen Coroutine via parallel.waitForAny().
-- NIEMALS blockierend — kein Matrix-Polling, keine langen Peripheral-Calls.
--
-- Fix (2026-07-16): CRITICAL (ENERGY-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 13). Tickt jetzt zusaetzlich
-- periodisch ctx.services (COMMS/DISCOVERY/TELEMETRY/UI, siehe
-- nodes/energy/main.lua) ueber einen eigenen, schnellen Timer -- vorher
-- liefen diese Services NUR aus dem potenziell blockierenden Matrix-Thread
-- (nodes/energy/matrix.lua), wodurch ein langsamer Matrix-Peripherie-Call
-- sie mitverzoegerte. "COMMS/UI/Telemetry/Discovery bleiben in getrennten
-- Schedulergruppen" -- dieser (garantiert nie blockierende) Thread ist
-- jetzt ihre alleinige periodische Tick-Quelle.
--
-- Fix (2026-07-17): CRITICAL (ENERGY-P1, Abschnitt 15). Dieser Thread
-- pflegte bisher eine EIGENE, private "last_heartbeat_ts"-Kopie im ctx
-- (per make_hb_ctx() mit 0 initialisiert), komplett unabhaengig von
-- hb_state.last_ts in nodes/energy/main.lua (der Quelle, die auch der
-- Matrix-Thread ueber send_heartbeat_if_due() prueft). Zwei getrennte
-- Zeitquellen fuer denselben Zweck driften zwangslaeufig auseinander --
-- z.B. sofort nach dem Start: main.lua sendet bereits VOR dem Betreten
-- von parallel.waitForAny() einen initialen Heartbeat (setzt hb_state.
-- last_ts), aber die private Kopie hier startete unveraendert bei 0 --
-- ein frueh eintreffendes modem_message-Event wertete "now - 0 >=
-- interval" sofort als faellig und loeste einen unnoetigen Zusatz-Send
-- aus, obwohl gerade erst gesendet worden war. Ausserdem sendete der
-- Timer-Pfad bisher UNBEDINGT (ohne jede Faelligkeitspruefung), selbst
-- wenn der Matrix-Thread kurz zuvor bereits ueber send_heartbeat_if_due()
-- gesendet hatte. Jetzt: kein privater Zaehler mehr -- ctx.send_heartbeat_
-- if_due() (dieselbe Funktion, dieselbe hb_state.last_ts-Quelle wie der
-- Matrix-Thread) gated JEDEN Sendeversuch aus diesem Thread, egal ob
-- Timer- oder Event-ausgeloest.

local M = {}

-- Startet den Heartbeat-Loop.
-- ctx erwartet:
--   ctx.comms              — comms_service Instanz
--   ctx.config             — Node-Config
--   ctx.devices            — devices-Tabelle (für Monitor-Check)
--   ctx.ui_state           — UI-State (für UI-Routing)
--   ctx.ui_pages           — UI-Pages Modul (für Diagnostics-Touch)
--   ctx.services           — service_manager (COMMS/DISCOVERY/TELEMETRY/UI;
--                             wird periodisch UND bei UI-/Key-Events geticked)
--   ctx.now_ms()           — aktuelle Zeit in ms
--   ctx.heartbeat_interval_ms() — Intervall in ms
--   ctx.send_heartbeat_if_due(now) — sendet Heartbeat NUR wenn faellig
--                             (geteilte last_ts-Quelle, siehe main.lua)
--   ctx.get_last_heartbeat_ts() — letzter tatsaechlicher Sendezeitpunkt
--                             (geteilte Quelle, nur fuer die Verzoegerungs-
--                             Warnung gelesen -- keine eigene Kopie)
--   ctx.tick_interval_s    — periodisches services:tick()-Intervall (Sekunden)
function M.run(ctx)
  -- Sendet den Heartbeat nur, wenn er gemaess der GETEILTEN last_ts-Quelle
  -- tatsaechlich faellig ist (siehe ctx.send_heartbeat_if_due()) -- egal ob
  -- vom Timer oder von einem modem_message-Event ausgeloest. Kein eigener,
  -- privater Faelligkeits-/Zeitstempel-Zustand mehr in diesem Thread.
  local function maybe_heartbeat()
    local now = ctx.now_ms()
    local interval = ctx.heartbeat_interval_ms()
    -- Verzögerungs-Warnung (gegen den letzten TATSAECHLICHEN Send, nicht
    -- gegen eine private Kopie)
    local last = ctx.get_last_heartbeat_ts()
    if last > 0 then
      local delayed = now - last
      if delayed > interval * 2 and (now - (ctx.last_heartbeat_warn_ts or 0)) >= interval * 2 then
        ctx.log("Heartbeat tick delayed by " .. delayed .. "ms (interval=" .. interval .. "ms)", "WARN")
        ctx.last_heartbeat_warn_ts = now
      end
    end
    local sent = ctx.send_heartbeat_if_due(now)
    if sent and ctx.comms then pcall(ctx.comms.tick, ctx.comms, now) end
    return sent
  end

  local function tick_services()
    if not ctx.services then return end
    local ok, err = pcall(ctx.services.tick, ctx.services)
    if not ok then
      ctx.log("Service tick error: " .. tostring(err), "WARN")
    end
  end

  local tick_interval_s = ctx.tick_interval_s or 0.5
  local hb_timer = os.startTimer(ctx.heartbeat_interval_ms() / 1000)
  local svc_timer = os.startTimer(tick_interval_s)

  -- Fix (2026-07-17): CRITICAL. INSTALL-P0.2 aus docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md (Abschnitt 4). ENERGY hat keine eigenen
  -- physischen Aktoren zu quiescen -- der Handler bestaetigt sofort einen
  -- sicheren Zustand, verlaesst aber kontrolliert diesen Thread (ueber
  -- parallel.waitForAny() in main.lua beendet das auch den Matrix-Thread),
  -- statt wie bisher unbegrenzt weiterzulaufen, waehrend ein Auto-Update
  -- ENERGYs eigene Dateien ersetzt.
  local update_handshake = require("core.update_handshake")
  local quiesce_handshake = _G.__xreactor_update_handshake

  while true do
    local event = { os.pullEventRaw() }
    local ev = event[1]

    if ev == "terminate" then
      return "terminate"
    elseif ev == "modem_message" then
      ctx.comms:handle_event(event)
      maybe_heartbeat()
    elseif ev == "monitor_touch" or ev == "mouse_click" then
      -- One central input path in ui_service handles router navigation first
      -- and only then page-specific controls. Pre-dispatching Diagnostics
      -- here made one physical touch act on two different pages.
      if ctx.services then ctx.services:tick(nil, event) end
    elseif ev == "key" or ev == "char" or ev == "monitor_resize" or ev == "term_resize" then
      ctx.services:tick(nil, event)
    elseif ev == "timer" and event[2] == hb_timer then
      maybe_heartbeat()
      hb_timer = os.startTimer(ctx.heartbeat_interval_ms() / 1000)
    elseif ev == "timer" and event[2] == svc_timer then
      tick_services()
      if quiesce_handshake and update_handshake.is_quiesce_requested(quiesce_handshake) then
        update_handshake.mark_safe_outputs_applied(quiesce_handshake)
        update_handshake.mark_runtime_stopped(quiesce_handshake)
        ctx.log("Quiesce angefordert -- Heartbeat-Thread wird kontrolliert beendet", "WARN")
        return "quiesced"
      end
      svc_timer = os.startTimer(tick_interval_s)
    end
  end
end

return M
