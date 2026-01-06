local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")

local sequencer = {}

local states = {
  idle = "IDLE",
  waiting_ack = "WAITING_ACK",
  waiting_stable = "WAITING_STABLE"
}

function sequencer.new(network, ramp_profile)
  return {
    queue = {},
    state = states.idle,
    active = nil,
    ramp_profile = ramp_profile or "NORMAL",
    enqueue = function(self, node_id)
      table.insert(self.queue, node_id)
    end,
    tick = function(self)
      if self.state == states.idle and #self.queue > 0 then
        self.active = table.remove(self.queue, 1)
        network:send(constants.channels.CONTROL, protocol.command(network.id, network.role, self.active, { target = constants.command_targets.MODE, value = constants.node_states.STARTUP }))
        self.state = states.waiting_ack
        utils.log("SEQ", "Requested startup for " .. self.active)
      elseif self.state == states.waiting_ack then
        -- waiting for master loop to set transition
      elseif self.state == states.waiting_stable then
        -- handled externally
      end
    end,
    notify_ack = function(self, node_id)
      if self.active == node_id and self.state == states.waiting_ack then
        self.state = states.waiting_stable
      end
    end,
    notify_stable = function(self, node_id)
      if self.active == node_id and self.state == states.waiting_stable then
        utils.log("SEQ", node_id .. " stable")
        self.active = nil
        self.state = states.idle
      end
    end
  }
end

return sequencer
