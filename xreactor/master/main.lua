local bootstrap = dofile('/xreactor/core/bootstrap.lua')
bootstrap.setup({
  role = 'master',
  log_enabled = false,
  log_path = nil
})

local require = bootstrap.require
local runtime_loop  = require('master.runtime_loop')
local remote_update = require('core.remote_update')

-- Auto-Update Loop parallel zum Haupt-Loop starten.
-- Der Loop prüft periodisch ob eine neue Version auf GitHub vorhanden ist
-- und startet den Installer wenn auto_update=true in der Arming-Config.
local function make_log()
  local ok, utils = pcall(require, 'core.utils')
  if ok and type(utils) == "table" and type(utils.log) == "function" then
    return function(level, msg) utils.log("MASTER", msg, level) end
  end
  return function(level, msg) print("[" .. tostring(level) .. "] " .. tostring(msg)) end
end

local auto_log = make_log()
local auto_loop = remote_update.auto_check_loop(auto_log, 120)

-- parallel.waitForAny: wenn einer der Threads endet (Update oder Absturz)
-- endet der gesamte Prozess und start.lua startet alles neu.
parallel.waitForAny(
  function() runtime_loop.run() end,
  auto_loop
)
