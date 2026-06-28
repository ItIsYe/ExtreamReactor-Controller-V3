-- nodes/energy/matrix.lua
-- Matrix-Polling-Thread für die Energy-Node.
-- Läuft in einer eigenen Coroutine via parallel.waitForAny().
-- DARF blockieren — Peripheral-Calls können 1-4s dauern.
-- Schreibt Ergebnisse nur in ctx.shared.matrix_data (atomic).

local M = {}

-- Startet den Matrix-Poll-Loop.
-- ctx erwartet:
--   ctx.services           — service_manager (für MATRIX_SAMPLE tick)
--   ctx.now_ms()           — aktuelle Zeit in ms
--   ctx.receive_timeout_s  — Sleep-Intervall zwischen Ticks
--   ctx.send_heartbeat(ts) — Heartbeat nach langen Calls
--   ctx.log(msg, level)    — Logging
function M.run(ctx)
  while true do
    -- Kurz schlafen damit Heartbeat-Coroutine laufen kann
    os.sleep(ctx.receive_timeout_s or 0.5)
    -- Matrix-Sampling-Service ticken (kann blockieren)
    local ok, err = pcall(function()
      ctx.services:tick()
    end)
    if not ok then
      ctx.log("Matrix tick error: " .. tostring(err), "WARN")
    end
    -- Heartbeat-Pump nach potentiell langen Calls
    ctx.send_heartbeat(ctx.now_ms())
  end
end

return M
