-- nodes/energy/matrix.lua
-- Matrix-Polling-Thread für die Energy-Node.
-- Läuft in einer eigenen Coroutine via parallel.waitForAny().
-- DARF blockieren — Peripheral-Calls können 1-4s dauern.
-- Schreibt Ergebnisse nur in ctx.shared.matrix_data (atomic).
--
-- ctx.services zeigt auf eine dedizierte Service-Gruppe (nur STORAGE_SAMPLE/
-- MATRIX_SAMPLE), nicht die vollstaendige Liste -- ein langsamer Matrix-
-- Peripherie-Call verzoegert dadurch nicht COMMS/DISCOVERY/TELEMETRY/UI.

local M = {}

-- Startet den Matrix-Poll-Loop.
-- ctx erwartet:
--   ctx.services                — dedizierte service_manager-Instanz, NUR
--                                  fuer STORAGE_SAMPLE/MATRIX_SAMPLE
--   ctx.now_ms()                — aktuelle Zeit in ms
--   ctx.receive_timeout_s       — Sleep-Intervall zwischen Ticks
--   ctx.send_heartbeat_if_due(ts) — Heartbeat-Nachholpruefung nach langen
--                                  Calls (sendet NUR wenn faellig -- keine
--                                  eigene, ungegatete Kopie mehr)
--   ctx.log(msg, level)         — Logging
function M.run(ctx)
  while true do
    -- Kurz schlafen damit Heartbeat-Coroutine laufen kann
    os.sleep(ctx.receive_timeout_s or 0.5)
    -- Matrix-/Storage-Sampling-Services ticken (koennen blockieren)
    local ok, err = pcall(function()
      ctx.services:tick()
    end)
    if not ok then
      ctx.log("Matrix tick error: " .. tostring(err), "WARN")
    end
    -- Heartbeat-Nachhol-Pruefung nach potentiell langen Calls -- sendet nur,
    -- wenn das konfigurierte Intervall tatsaechlich abgelaufen ist.
    ctx.send_heartbeat_if_due(ctx.now_ms())
  end
end

return M
