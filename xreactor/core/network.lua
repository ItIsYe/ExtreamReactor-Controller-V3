local constants = require("shared.constants")
local utils = require("core.utils")
local protocol = require("core.protocol")

local network = {}

local function open_modem(name, channels)
  if not name or not peripheral.isPresent(name) then
    error("Modem " .. tostring(name) .. " missing")
  end
  local modem = peripheral.wrap(name)
  for _, channel in ipairs(channels) do
    modem.open(channel)
  end
  return modem
end

function network.init(config)
  local modem = open_modem(config.wireless_modem, { constants.channels.CONTROL, constants.channels.STATUS })
  local wired = config.wired_modem and peripheral.isPresent(config.wired_modem) and peripheral.wrap(config.wired_modem) or nil
  return {
    modem = modem,
    wired = wired,
    id = os.getComputerLabel() or (config.role .. "-" .. os.getComputerID()),
    role = config.role,
    send = function(_, channel, payload)
      modem.transmit(channel, channel, payload)
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
          if protocol.validate(message) then
            return message
          end
        elseif event[1] == "timer" and event[2] == timer then
          return nil
        end
      end
    end,
    broadcast = function(_, payload)
      modem.transmit(constants.channels.CONTROL, constants.channels.CONTROL, payload)
    end,
    push_wired = function(_, side, method, ...)
      if not wired then return nil, "wired modem missing" end
      return utils.safe_peripheral_call(side, method, ...)
    end
  }
end

return network
