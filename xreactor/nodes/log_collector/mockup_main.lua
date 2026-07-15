-- LOG Collector mockup entrypoint.
-- Runs the real collector runtime (main.lua) completely unmodified. Selects
-- the "mockup" touch-monitor renderer instead of the default terminal
-- layout via a renderer-selection global that main.lua's draw() reads
-- (nodes/log_collector/default_ui.lua vs. nodes/log_collector/mockup_ui.lua,
-- both implementing the same M.render(ctx) interface) — no runtime
-- source-text patching involved (see LOG-P2, docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 10).

-- Fix (2026-07-05): nodes/log_collector/main.lua ruft historisch NIE
-- bootstrap.setup() auf — der LOG-Collector war komplett eigenstaendig ohne
-- projektinternes require()-Modulsystem (im Gegensatz zu MASTER/RT/ENERGY/
-- WATER/FUEL/REPROCESSOR, die alle bootstrap.setup() in main.lua aufrufen).
-- Die mockup_ui.lua-Integration braucht aber require("nodes.log_collector.
-- mockup_ui") bzw. require("nodes.log_collector.default_ui") — ohne
-- bootstrap.setup() ist require() dafuer die native, nicht-funktionierende
-- CC:Tweaked-Standardfunktion, was zu "attempt to call a nil value" fuehrte
-- (require selbst existierte in diesem Kontext nicht als brauchbare
-- Funktion). bootstrap.setup() setzt require GLOBAL (_G.require), daher
-- reicht ein einmaliger Aufruf hier, bevor main.lua ausgefuehrt wird.
local ok_bootstrap, bootstrap = pcall(dofile, "/xreactor/core/bootstrap.lua")
if ok_bootstrap and type(bootstrap) == "table" and type(bootstrap.setup) == "function" then
  pcall(bootstrap.setup, { role = "log" })
end

_G.XR_LOG_RENDERER_MODULE = "nodes.log_collector.mockup_ui"

local MAIN_PATH = "/xreactor/nodes/log_collector/main.lua"
if not fs or not fs.exists or not fs.exists(MAIN_PATH) then
  error("LOG mockup loader: missing " .. MAIN_PATH, 0)
end

return dofile(MAIN_PATH)
