-- core/remote_update.lua
-- Arming/token validation and managed remote-update queueing.

local M = {}

local ARMING_CONFIG_PATH = "/xreactor/config/remote_update.lua"
local INSTALLER_URL_BRANCH = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer"
local RELEASE_URL_BRANCH = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/release.lua"

local function make_log(opts)
  opts = opts or {}
  if type(opts.log_fn) == "function" then return opts.log_fn end
  if type(opts.utils) == "table" and type(opts.utils.log) == "function" then
    local prefix = opts.log_prefix or "NODE"
    return function(level, text) opts.utils.log(prefix, text, level) end
  end
  return function() end
end

local function load_arming_config()
  if not fs or type(fs.exists) ~= "function" or type(fs.open) ~= "function" then
    return nil, "fs unavailable"
  end
  if not fs.exists(ARMING_CONFIG_PATH) then return nil, "not armed" end
  local handle = fs.open(ARMING_CONFIG_PATH, "r")
  if not handle then return nil, "arming config unreadable" end
  local content = handle.readAll()
  handle.close()
  local loader, err = load(content, "=remote_update_arming", "t", {})
  if not loader then return nil, "arming config parse failed: " .. tostring(err) end
  local ok, result = pcall(loader)
  if not ok then return nil, "arming config failed: " .. tostring(result) end
  if type(result) ~= "table" or result.enabled ~= true then return nil, "not armed" end
  return result
end

local function command_token(opts)
  local message = opts and opts.message or nil
  if type(message) == "table" then
    if message.token ~= nil then return message.token end
    if type(message.command) == "table" and message.command.token ~= nil then return message.command.token end
  end
  local payload = type(message) == "table" and message.payload or nil
  local command = type(payload) == "table" and payload.command or nil
  if type(command) == "table" and command.token ~= nil then return command.token end
  return opts and opts.token or nil
end

function M.is_armed(opts)
  local cfg, reason = load_arming_config()
  if not cfg then return false, reason end
  if cfg.token ~= nil then
    local token = command_token(opts)
    if tostring(token or "") ~= tostring(cfg.token) then return false, "token mismatch" end
  end
  return true, "armed"
end

-- The normal managed runtime (start.lua) owns a dedicated updater coroutine.
-- A radio/manual command may request an update, but it must never start the
-- installer from inside a role command/event handler. Queue only metadata that
-- is useful for diagnostics; the token is validated above and is deliberately
-- not retained in shared global state.
function M.queue_command(opts)
  opts = opts or {}
  local log = make_log(opts)
  local armed, arm_reason = M.is_armed(opts)
  if not armed then
    log("WARN", "Remote-Update command blocked: " .. tostring(arm_reason))
    return { ok = false, error = arm_reason or "not armed", reason_code = "REMOTE_UPDATE_NOT_ARMED" }
  end

  local handshake = rawget(_G, "__xreactor_update_handshake")
  if type(handshake) ~= "table" then
    log("ERROR", "Remote-Update blocked: managed update handshake unavailable")
    return { ok = false, error = "managed update handshake unavailable", reason_code = "UPDATE_HANDSHAKE_UNAVAILABLE" }
  end

  local update_handshake = require("core.update_handshake")
  local message = opts.message or {}
  local queued, reason = update_handshake.request_remote_update(handshake, {
    source = message.src or message.sender_id or "unknown",
    message_id = message.message_id,
    trigger = opts.trigger or "COMMAND",
    authorized = true,
  })
  if not queued then
    log("ERROR", "Remote-Update queue failed: " .. tostring(reason))
    return { ok = false, error = tostring(reason), reason_code = "UPDATE_QUEUE_FAILED" }
  end
  log("WARN", "Remote-Update accepted and queued for quiesced updater (" .. tostring(reason) .. ")")
  return { ok = true, queued = true, detail = reason }
end

function M.handle_command(opts)
  local result = M.queue_command(opts)
  if result.ok and type(opts and opts.send_ack) == "function" then pcall(opts.send_ack) end
  return result.ok == true, result.error or result.detail
end

local function is_html(body)
  if type(body) ~= "string" then return false end
  local s = body:sub(1, 200):lower()
  return s:find("<html", 1, true) ~= nil or s:find("<!doctype", 1, true) ~= nil
end

local function download_installer(log)
  local delays = { 2, 5, 10, 20 }
  for attempt = 1, 4 do
    local ok, r = pcall(http.get, INSTALLER_URL_BRANCH, nil, { timeout = 20 })
    if ok and r then
      local ok2, body = pcall(r.readAll); pcall(r.close)
      if ok2 and type(body) == "string" and #body > 100 and not is_html(body) then
        return body, INSTALLER_URL_BRANCH
      end
    end
    if attempt < 4 and os and type(os.sleep) == "function" then os.sleep(delays[attempt] or 20) end
  end
  return nil, "all installer downloads failed"
end

-- Legacy/direct installer entry point. In a managed boot it is deliberately
-- unusable until the role has reached RUNTIME_STOPPED; this prevents any old
-- special-case caller from bypassing the shared safety handshake.
function M.run(log_fn, opts)
  opts = opts or {}
  local log = type(log_fn) == "function" and log_fn or function() end
  local managed = rawget(_G, "__xreactor_update_handshake")
  if type(managed) == "table" then
    local update_handshake = require("core.update_handshake")
    if not update_handshake.is_runtime_stopped(managed) then
      log("ERROR", "Remote-Update blocked: runtime quiesce/RUNTIME_STOPPED required")
      return false, "runtime quiesce required"
    end
  end

  local armed, arm_reason = M.is_armed(opts)
  if not armed then return false, arm_reason or "not armed" end
  if not http or type(http.get) ~= "function" then return false, "no http" end

  local body, url_or_err = download_installer(log)
  if not body then return false, url_or_err end
  local path = "/xreactor_remote_update_installer.lua"
  local ok_w, h_or_err = pcall(fs.open, path, "w")
  if not ok_w or not h_or_err then return false, "write failed" end
  local h = h_or_err
  local ok_write = pcall(h.write, h, body)
  pcall(h.close, h)
  if not ok_write then pcall(fs.delete, path); return false, "write error" end

  _G.__xreactor_remote_update = true
  local ok_run, run_err
  if type(shell) == "table" and type(shell.run) == "function" then
    local ok_call, result = pcall(shell.run, path)
    ok_run = ok_call and result ~= false
    run_err = ok_call and (result == false and "installer returned false" or nil) or result
  else
    ok_run, run_err = pcall(dofile, path)
  end
  _G.__xreactor_remote_update = nil
  pcall(fs.delete, path)
  if not ok_run then return false, tostring(run_err) end
  if os and type(os.sleep) == "function" then os.sleep(1) end
  if os and type(os.reboot) == "function" then os.reboot() end
  return true
end

-- Retained for diagnostics/legacy standalone callers. The managed runtime uses
-- xreactor/installer/auto_update.lua instead.
function M.check_version(log)
  log = log or function() end
  if not http or type(http.get) ~= "function" then return nil end
  local remote_v = nil
  for attempt = 1, 3 do
    local ok, r = pcall(http.get, RELEASE_URL_BRANCH, nil, { timeout = 10 })
    if ok and r then
      local ok2, body = pcall(r.readAll); pcall(r.close)
      if ok2 and type(body) == "string" and not is_html(body) then
        remote_v = tonumber(body:match("manifest_version%s*=%s*(%d+)"))
        if remote_v then break end
      end
    end
    if attempt < 3 and os and type(os.sleep) == "function" then os.sleep(3) end
  end
  if not remote_v then return nil end
  local local_v = nil
  if fs and fs.exists("/xreactor/release.lua") then
    local h = fs.open("/xreactor/release.lua", "r")
    if h then local src = h.readAll(); h.close(); local_v = tonumber(src:match("manifest_version%s*=%s*(%d+)")) end
  end
  if not local_v or remote_v <= local_v then return nil end
  return remote_v
end

function M.auto_check_loop(log, check_interval_s)
  log = log or function() end
  check_interval_s = tonumber(check_interval_s) or 120
  return function()
    while true do
      local timer_id = os.startTimer and os.startTimer(check_interval_s) or nil
      if timer_id then
        repeat local ev, id = os.pullEvent() until ev == "timer" and id == timer_id
      else
        os.sleep(check_interval_s)
      end
      local new_v = M.check_version(log)
      if new_v then
        log("WARN", "Legacy auto_check_loop detected an update but will not bypass managed updater")
        local handshake = rawget(_G, "__xreactor_update_handshake")
        if type(handshake) == "table" then
          require("core.update_handshake").request_remote_update(handshake, {
            trigger = "LEGACY_AUTO_CHECK", authorized = true, remote_version = new_v,
          })
        end
      end
    end
  end
end

return M
