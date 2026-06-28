-- nodes/energy/heartbeat.lua
-- Heartbeat-Thread für die Energy-Node.
-- Läuft in einer eigenen Coroutine via parallel.waitForAny().
-- NIEMALS blockierend — kein Matrix-Polling, keine langen Peripheral-Calls.

local M = {}

-- Startet den Heartbeat-Loop.
-- ctx erwartet:
--   ctx.comms              — comms_service Instanz
--   ctx.config             — Node-Config
--   ctx.devices            — devices-Tabelle (für Monitor-Check)
--   ctx.ui_state           — UI-State (für UI-Routing)
--   ctx.ui_pages           — UI-Pages Modul (für Diagnostics-Touch)
--   ctx.services           — service_manager (für UI/Key-Events)
--   ctx.now_ms()           — aktuelle Zeit in ms
--   ctx.heartbeat_interval_ms() — Intervall in ms
--   ctx.send_heartbeat()   — sendet Heartbeat
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
    ctx.comms:tick(now)
    ctx.last_heartbeat_ts = now
  end

  while true do
    local interval_s = ctx.heartbeat_interval_ms() / 1000
    local timer = os.startTimer(interval_s)

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
        if ctx.devices.monitor and ctx.ui_state.router then
          local current = ctx.ui_state.router:current()
          if current and current.name == "Diagnostics" then
            ctx.ui_pages.handle_diagnostics_touch(ctx.devices.monitor, event[3], event[4])
          end
        end
        ctx.services:tick(nil, event)
      elseif ev == "key" then
        ctx.services:tick(nil, event)
      elseif ev == "timer" and event[2] == timer then
        do_heartbeat()
        break  -- nächsten Timer starten
      end
    end
  end
end

return M
