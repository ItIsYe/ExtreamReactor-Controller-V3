local M = {}

function M.heartbeat_interval_ms(config)
  return math.max(1, tonumber(config.heartbeat_interval) or 2) * 1000
end

function M.make_presence(config, comms, ts_ms)
  return {
    ts = ts_ms,
    node_id = comms and comms.network and comms.network.id or config.node_id,
    role = config.role
  }
end

function M.init_logging(args)
  local utils = args.utils
  local config = args.config
  local cfg = args.runtime_config
  local config_meta = args.config_meta
  local config_warnings = args.config_warnings or {}

  local node_id = utils.read_node_id(cfg.NODE_ID_PATH)
  local log_name = utils.build_log_name(cfg.LOG_NAME, node_id)
  local debug_enabled = config.debug_logging
  if cfg.DEBUG_LOG_ENABLED ~= nil then
    debug_enabled = cfg.DEBUG_LOG_ENABLED
  end
  if (config_meta and config_meta.reason) or #config_warnings > 0 then
    debug_enabled = true
  end

  local log_status = utils.init_logger({
    log_name = log_name,
    prefix = cfg.LOG_PREFIX,
    enabled = debug_enabled,
    truncate = config.reset_log_on_start == true
  })

  if log_status and log_status.enabled then
    utils.log(cfg.LOG_PREFIX, string.format("Logfile %s (startup=%s)", tostring(log_status.log_path), tostring(log_status.startup_action)), "INFO")
  end
  utils.log(cfg.LOG_PREFIX, "Startup", "INFO")
  if config_meta and config_meta.reason then
    utils.log(cfg.LOG_PREFIX, "Config issue (" .. tostring(config_meta.reason) .. ") at " .. tostring(config_meta.path) .. "; using defaults where needed.", "WARN")
  end
  for _, warning in ipairs(config_warnings) do
    utils.log(cfg.LOG_PREFIX, warning, "WARN")
  end

  return node_id, log_status
end

function M.warn_once(state, log_fn, key, message)
  state = state or {}
  state.warned = state.warned or {}
  if state.warned[key] then
    return
  end
  state.warned[key] = true
  log_fn(message, "WARN")
end


function M.safe_wrapped_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return false, "missing method"
  end
  return pcall(obj[method], ...)
end

local function is_terminate(err)
  return tostring(err or ""):lower():find("terminate", 1, true) ~= nil
end

local function crash_screen(err)
  if term and term.setBackgroundColor and colors then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== NODE CRASH ===")
    term.setTextColor(colors.white)
    print("")
    print(tostring(err))
    print("")
    term.setTextColor(colors.yellow)
    print("Druecke eine Taste um neu zu starten...")
    term.setTextColor(colors.white)
  else
    print("CRASH: " .. tostring(err))
  end
  pcall(os.pullEvent, "key")
  if os.reboot then os.reboot() end
end

function M.run_event_loop(receive_timeout, services, comms, after_cycle)
  local ok, err = xpcall(function()
    while true do
      local timer = os.startTimer(receive_timeout)
      while true do
        local event = { os.pullEvent() }
        if event[1] == "modem_message" then
          comms:handle_event(event)
          services:tick(nil, event)
        elseif event[1] == "timer" and event[2] == timer then
          break
        elseif event[1] == "monitor_touch" or event[1] == "mouse_click" or event[1] == "key" then
          services:tick(nil, event)
        end
      end
      if type(after_cycle) == "function" then
        local ok2, err2 = pcall(after_cycle)
        if not ok2 then
          -- Fehler in after_cycle loggen aber nicht crashen
          pcall(function()
            require("core.utils").log("RUNTIME", "after_cycle error: " .. tostring(err2), "ERROR")
          end)
        end
      end
      services:tick()
    end
  end, function(e) return e end)
  if ok then return end
  if is_terminate(err) then return end
  crash_screen(err)
end

return M
