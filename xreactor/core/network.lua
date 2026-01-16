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
    error("Modem " .. tostring(name) .. " missing")
  end
  local modem, err = utils.safe_wrap(name)
  if not modem then
    error("Modem " .. tostring(name) .. " wrap failed: " .. tostring(err))
  end
  for _, channel in ipairs(channels) do
    modem.open(channel)
  end
  return modem
end

function network.init(config)
  local modem = open_modem(config.wireless_modem, { constants.channels.CONTROL, constants.channels.STATUS })
  local wired = nil
  if config.wired_modem and peripheral.isPresent(config.wired_modem) then
    wired = select(1, utils.safe_wrap(config.wired_modem))
  end
  local node_id = resolve_node_id(config)
  return {
    modem = modem,
    wired = wired,
    id = node_id,
    role = config.role,
    send = function(_, channel, payload)
      local sanitized = protocol.sanitize_message(payload)
      if sanitized then
        modem.transmit(channel, channel, sanitized)
      end
    end,
    receive = function(_, timeout)
      local timer
      if timeout then
        timer = os.startTimer(timeout)
      end
      while true do
        local event = { os.pullEvent() }
        if event[1] == "modem_message" then
          local _, _, channel, _, message = table.unpack(event)
          local ok, err = protocol.validateMessage(message)
          if ok then
            return protocol.sanitize_message(message)
          end
          warn_once("schema:" .. tostring(err), "WARN: invalid message ignored (" .. tostring(err) .. ")")
        elseif event[1] == "timer" and event[2] == timer then
          return nil
        end
      end
    end,
    broadcast = function(_, payload)
      local sanitized = protocol.sanitize_message(payload)
      if sanitized then
        modem.transmit(constants.channels.CONTROL, constants.channels.CONTROL, sanitized)
      end
    end,
    push_wired = function(_, side, method, ...)
      if not wired then return nil, "wired modem missing" end
      return utils.safe_peripheral_call(side, method, ...)
    end
  }
end

return network
