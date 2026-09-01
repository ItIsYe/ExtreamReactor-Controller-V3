-- LOG Collector mockup entrypoint.
-- Runs the real collector runtime (main.lua) completely unmodified. Selects
-- the "mockup" touch-monitor renderer instead of the default terminal
-- layout via a renderer-selection global that main.lua's draw() reads
-- (nodes/log_collector/default_ui.lua vs. nodes/log_collector/mockup_ui.lua,
-- both implementing the same M.render(ctx) interface).
--
-- main.lua itself never calls bootstrap.setup() (unlike MASTER/RT/ENERGY/
-- WATER/FUEL/REPROCESSOR), but the mockup_ui.lua integration needs
-- require() for it; bootstrap.setup() sets require GLOBAL (_G.require),
-- so one call here before main.lua runs is enough.
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
