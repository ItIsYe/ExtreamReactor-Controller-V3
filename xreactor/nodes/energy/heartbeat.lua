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
--   ctx.send_heartbeat()   — sendet Heartbeat (unbedingt)
--   ctx.tick_interval_s    — periodisches services:tick()-Intervall (Sekunden)
function M.run(ctx)
  local function should_send()
    local now = ctx.now_ms()
    local interval = ctx.heartbeat_interval_ms()
    return (now - (ctx.last_heartbeat_ts or 0)) >= interval
  end

  local function do_heartbeat()
    local now = ctx.now_ms()
    local interval = ctx.heartbeat_interval_ms()
    -- Verzögerungs-Warnung
    if (ctx.last_heartbeat_ts or 0) > 0 then
      local delayed = now - ctx.last_heartbeat_ts
      if delayed > interval * 2 and (now - (ctx.last_heartbeat_warn_ts or 0)) >= interval * 2 then
        ctx.log("Heartbeat tick delayed by " .. delayed .. "ms (interval=" .. interval .. "ms)", "WARN")
        ctx.last_heartbeat_warn_ts = now
      end
    end
    ctx.send_heartbeat(now)
    if ctx.comms then pcall(ctx.comms.tick, ctx.comms, now) end
    ctx.last_heartbeat_ts = now
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

  while true do
    local event = { os.pullEventRaw() }
    local ev = event[1]

    if ev == "terminate" then
      return "terminate"
    elseif ev == "modem_message" then
      ctx.comms:handle_event(event)
      if should_send() then do_heartbeat() end
    elseif ev == "monitor_touch" or ev == "mouse_click" then
      -- UI-Touch weiterleiten
      if ctx.devices and ctx.devices.monitor and ctx.ui_state and ctx.ui_state.router then
        local current = ctx.ui_state.router:current()
        if current and current.name == "Diagnostics" then
          pcall(ctx.ui_pages.handle_diagnostics_touch,
            ctx.devices.monitor, event[3], event[4])
        end
      end
      if ctx.services then ctx.services:tick(nil, event) end
    elseif ev == "key" then
      ctx.services:tick(nil, event)
    elseif ev == "timer" and event[2] == hb_timer then
      do_heartbeat()
      hb_timer = os.startTimer(ctx.heartbeat_interval_ms() / 1000)
    elseif ev == "timer" and event[2] == svc_timer then
      tick_services()
      svc_timer = os.startTimer(tick_interval_s)
    end
  end
end

return M
