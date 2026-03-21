local constants = require("shared.constants")
local utils = require("core.utils")
local protocol = require("core.protocol")

local network = {}
local warned = {}

local function warn_once(key, message)
  if warned[key] then return end
  warned[key] = true
  utils.log("NET", message)
end

local function resolve_node_id(config)
  if config.node_id then
    local normalized = utils.normalize_node_id(config.node_id)
    if normalized ~= "UNKNOWN" then
      if type(config.node_id) ~= "string" then
        warn_once("node_id.normalize", "WARN: normalized node_id to string")
      end
      return normalized
    end
  end
  local path = "/xreactor/config/node_id.txt"
  if fs.exists(path) then
    local file = fs.open(path, "r")
    if file then
      local stored = utils.trim(file.readAll())
      file.close()
      if stored ~= "" then
        return stored
      end
    end
  end
  local generated = os.getComputerLabel() or (config.role .. "-" .. os.getComputerID())
  utils.ensure_dir(fs.getDir(path))
  local file = fs.open(path, "w")
  if file then
    file.write(generated)
    file.close()
  end
  return generated
end

local function open_modem(name, channels)
  if not name or not peripheral.isPresent(name) then
    return nil, "missing"
  end
  local modem, err = utils.safe_wrap(name)
  if not modem then
    return nil, "wrap failed: " .. tostring(err)
  end
  if type(modem.open) ~= "function" or type(modem.transmit) ~= "function" then
    return nil, "not a modem"
  end
  for _, channel in ipairs(channels) do
    local ok, open_err = pcall(modem.open, modem, channel)
    if not ok then
      return nil, "open failed: " .. tostring(open_err)
    end
  end
  return modem
end

local function safe_call_remote(wired, device_name, method, ...)
  if not wired then
    return nil, "wired modem missing"
  end
  if type(wired.callRemote) ~= "function" then
    return nil, "wired modem unsupported"
  end
  if type(wired.isPresentRemote) == "function" and not wired.isPresentRemote(device_name) then
    return nil, "remote peripheral missing"
  end
  local results = table.pack(pcall(wired.callRemote, device_name, method, ...))
  if not results[1] then
    return nil, results[2]
  end
  if results.n == 1 then
    return true
  end
  return table.unpack(results, 2, results.n)
end

local function resolve_channels(config)
  local channels = type(config.channels) == "table" and config.channels or {}
  local control = type(channels.control) == "number" and channels.control or constants.channels.CONTROL
  local status = type(channels.status) == "number" and channels.status or constants.channels.STATUS
  return { control = control, status = status }
end

local function legacy_receive_disabled()
  warn_once("receive.legacy", "WARN: network.receive() is legacy/disabled; use modem_message event handling via comms_service")
  return nil, "legacy receive disabled"
end

local function legacy_receive(timeout)
  local timer
  if timeout then
    timer = os.startTimer(timeout)
  end
  while true do
    local event = { os.pullEvent() }
    if event[1] == "modem_message" then
      local _, _, _, _, message = table.unpack(event)
      local ok, err = protocol.validateMessage(message)
      if ok then
        return protocol.sanitize_message(message)
      end
      warn_once("schema:" .. tostring(err), "WARN: invalid message ignored (" .. tostring(err) .. ")")
    elseif event[1] == "timer" and event[2] == timer then
      return nil
    end
  end
end

function network.init(config)
  config = config or {}
  local channels = resolve_channels(config)
  local modem, modem_err = open_modem(config.wireless_modem, { channels.control, channels.status })
  local wired = nil
  if config.wired_modem and peripheral.isPresent(config.wired_modem) then
    wired = select(1, utils.safe_wrap(config.wired_modem))
  end
  local node_id = resolve_node_id(config)
  if not modem then
    warn_once("modem.missing", "WARN: wireless modem missing; comms disabled (" .. tostring(modem_err) .. ")")
    return {
      modem = nil,
      wired = wired,
      channels = channels,
      id = node_id,
      role = config.role,
      send = function(_, _, _)
        return false, "wireless modem missing"
      end,
      receive = function(_, timeout)
        if config.allow_legacy_receive == true then
          return legacy_receive(timeout)
        end
        return legacy_receive_disabled()
      end,
      broadcast = function(_, _)
        return false, "wireless modem missing"
      end,
      push_wired = function(_, device_name, method, ...)
        return safe_call_remote(wired, device_name, method, ...)
      end
    }
  end
  return {
    modem = modem,
    wired = wired,
    channels = channels,
    id = node_id,
    role = config.role,
    send = function(_, channel, payload)
      local sanitized = protocol.sanitize_message(payload)
      if not sanitized then
        return false, "invalid payload"
      end
      local ok, err = pcall(modem.transmit, modem, channel, channel, sanitized)
      if not ok then
        return false, tostring(err)
      end
      return true
    end,
    receive = function(_, timeout)
      if config.allow_legacy_receive == true then
        return legacy_receive(timeout)
      end
      return legacy_receive_disabled()
    end,
    broadcast = function(_, payload)
      local sanitized = protocol.sanitize_message(payload)
      if not sanitized then
        return false, "invalid payload"
      end
      local ok, err = pcall(modem.transmit, modem, channels.control, channels.control, sanitized)
      if not ok then
        return false, tostring(err)
      end
      return true
    end,
    push_wired = function(_, device_name, method, ...)
      return safe_call_remote(wired, device_name, method, ...)
    end
  }
end

return network
