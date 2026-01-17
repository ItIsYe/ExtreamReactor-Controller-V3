-- CONFIG
local CONFIG = {
  CORE_PATH = "/xreactor/installer/installer_core.lua", -- Core installer path.
  LOG_PREFIX = "INSTALLER", -- Log prefix for shim messages.
  DEBUG_LOG_ENABLED = false -- Enable shim logging to /xreactor/logs/installer.log.
}

local function log_line(message)
  if not CONFIG.DEBUG_LOG_ENABLED then
    return
  end
  local ok = pcall(function()
    if not fs.exists("/xreactor/logs") then
      fs.makeDir("/xreactor/logs")
    end
    local file = fs.open("/xreactor/logs/installer.log", "a")
    if file then
      file.write(string.format("[%s] %s | %s\n", textutils.formatTime(os.epoch("utc") / 1000, true), CONFIG.LOG_PREFIX, tostring(message)))
      file.close()
    end
  end)
  if not ok then
    CONFIG.DEBUG_LOG_ENABLED = false
  end
end

local function run_core()
  if not fs.exists(CONFIG.CORE_PATH) then
    print("Installer core missing. Run /installer.lua to bootstrap.")
    return
  end
  local loader = loadfile(CONFIG.CORE_PATH)
  if not loader then
    print("Installer core corrupted. Run /installer.lua to repair.")
    return
  end
  loader()
end

log_line("Launching installer core")
run_core()
