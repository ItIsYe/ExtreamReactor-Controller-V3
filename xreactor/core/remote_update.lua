-- Validation and queueing for managed updates.
--
-- This module deliberately does not download or execute anything. The sole
-- installer owner is installer/auto_update.lua, which first waits for the
-- role runtime to prove its safe state and stop.

local M = {}

local ARMING_CONFIG_PATH = "/xreactor/config/remote_update.lua"

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

  local loader, load_err = load(content, "=remote_update_arming", "t", {})
  if not loader then
    return nil, "arming config parse failed: " .. tostring(load_err)
  end
  local ok, config = pcall(loader)
  if not ok or type(config) ~= "table" then
    return nil, "arming config invalid"
  end
  if config.enabled ~= true then return nil, "not armed" end
  return config
end

local function command_token(opts)
  local message = opts and opts.message or nil
  if type(message) == "table" then
    if message.token ~= nil then return message.token end
    if type(message.command) == "table" and message.command.token ~= nil then
      return message.command.token
    end
    local payload = type(message.payload) == "table" and message.payload or nil
    local command = type(payload) == "table" and payload.command or nil
    if type(command) == "table" and command.token ~= nil then return command.token end
  end
  return opts and opts.token or nil
end

function M.is_armed(opts)
  local config, reason = load_arming_config()
  if not config then return false, reason end
  if not (opts and opts.local_trigger == true) and config.token ~= nil then
    if tostring(command_token(opts) or "") ~= tostring(config.token) then
      return false, "token mismatch"
    end
  end
  return true, "armed", config
end

local function queue(opts)
  opts = opts or {}
  local log = make_log(opts)
  local armed, arm_reason = M.is_armed(opts)
  if not armed then
    log("WARN", "Remote-Update blocked: " .. tostring(arm_reason))
    return {
      ok = false,
      error = arm_reason or "not armed",
      reason_code = "REMOTE_UPDATE_NOT_ARMED",
    }
  end

  local handshake = rawget(_G, "__xreactor_update_handshake")
  if type(handshake) ~= "table" then
    log("ERROR", "Remote-Update blocked: managed update handshake unavailable")
    return {
      ok = false,
      error = "managed update handshake unavailable",
      reason_code = "UPDATE_HANDSHAKE_UNAVAILABLE",
    }
  end

  local update_handshake = require("core.update_handshake")
  local message = type(opts.message) == "table" and opts.message or {}
  local queued, reason = update_handshake.request_remote_update(handshake, {
    source = message.src or message.sender_id or opts.source or "local",
    message_id = message.message_id,
    trigger = opts.trigger or (opts.local_trigger and "LOCAL" or "COMMAND"),
  })
  if not queued then
    log("ERROR", "Remote-Update queue failed: " .. tostring(reason))
    return {
      ok = false,
      error = tostring(reason),
      reason_code = "UPDATE_QUEUE_FAILED",
    }
  end

  log("WARN", "Remote-Update accepted and queued (" .. tostring(reason) .. ")")
  return { ok = true, queued = true, detail = reason }
end

function M.queue_command(opts)
  opts = opts or {}
  opts.local_trigger = false
  return queue(opts)
end

function M.queue_local(opts)
  opts = opts or {}
  opts.local_trigger = true
  return queue(opts)
end

-- Use the locally configured token for Master -> node update commands. A nil
-- token is valid when the installation was armed without one.
function M.build_command()
  local config, reason = load_arming_config()
  if not config then return nil, reason end
  return { target = "REMOTE_UPDATE", token = config.token }
end

return M
