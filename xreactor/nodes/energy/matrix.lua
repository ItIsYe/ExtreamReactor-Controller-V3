-- nodes/energy/matrix.lua
-- Matrix-Polling-Thread für die Energy-Node.
-- Läuft in einer eigenen Coroutine via parallel.waitForAny().
-- DARF blockieren — Peripheral-Calls können 1-4s dauern.
-- Schreibt Ergebnisse nur in ctx.shared.matrix_data (atomic).
--
-- Fix (2026-07-16): CRITICAL (ENERGY-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 13). ctx.services zeigt jetzt auf
-- eine eigene, dedizierte Service-Gruppe (nur STORAGE_SAMPLE/MATRIX_SAMPLE,
-- siehe nodes/energy/main.lua), NICHT mehr auf die vollstaendige Liste
-- (COMMS/DISCOVERY/TELEMETRY/UI liefen bisher im selben blockierenden
-- Thread mit) -- ein langsamer Matrix-Peripherie-Call verzoegert dadurch
-- nur noch die beiden Sample-Services untereinander, nicht mehr COMMS/UI.

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
