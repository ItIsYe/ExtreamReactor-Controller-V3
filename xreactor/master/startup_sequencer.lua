local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")

local sequencer = {}

local states = {
  idle = "IDLE",
  waiting_ack = "WAITING_ACK",
  waiting_stable = "WAITING_STABLE"
}

local function plan_modules(node_id, modules)
  local steps = {}
  for name, mod in pairs(modules or {}) do
    if name:find("turbine") then
      table.insert(steps, { node_id = node_id, module_id = name, module_type = "turbine" })
    end
  end
  for name in pairs(modules or {}) do
    if name:find("reactor") then
      table.insert(steps, { node_id = node_id, module_id = name, module_type = "reactor" })
    end
  end
  return steps
end

function sequencer.new(comms, ramp_profile)
  local self = {
    queue = {},
    state = states.idle,
    active = nil,
    ramp_profile = ramp_profile or "NORMAL"
  }

  function self.enqueue(node_id)
    local normalized = utils.normalize_node_id(node_id)
    table.insert(self.queue, { node_id = normalized })
  end

  function self.build_steps(nodes)
    local expanded = {}
    for _, entry in ipairs(self.queue) do
      local node = nodes and nodes[entry.node_id]
      if node and node.modules then
        for _, step in ipairs(plan_modules(entry.node_id, node.modules)) do
          table.insert(expanded, step)
        end
      else
        table.insert(expanded, { node_id = entry.node_id, module_id = "all", module_type = "reactor" })
      end
    end
    self.queue = expanded
  end

  function self.tick(nodes)
    if self.state == states.idle and #self.queue > 0 then
      if not self.queue[1].module_id then
        self.build_steps(nodes)
        if #self.queue == 0 then return end
      end
      self.active = table.remove(self.queue, 1)
      local payload = {
        target = constants.command_targets.STARTUP_STAGE or constants.command_targets.REQUEST_STARTUP_MODULE,
        value = {
          module_id = self.active.module_id,
          module_type = self.active.module_type,
          ramp_profile = self.ramp_profile
        }
      }
      local safe_node_id = utils.normalize_node_id(self.active and self.active.node_id)
      comms:send_command(safe_node_id, payload, { requires_applied = true })
      self.state = states.waiting_ack
      utils.log("SEQ", "Request startup " .. tostring(self.active.module_id) .. " on " .. safe_node_id)
    elseif self.state == states.waiting_ack then
      -- wait
    elseif self.state == states.waiting_stable then
      -- wait
    end
  end

  function self.notify_ack(node_id, module_id)
    local safe_node_id = utils.normalize_node_id(node_id)
    if self.active and self.active.node_id == safe_node_id and self.active.module_id == module_id then
      self.state = states.waiting_stable
    end
  end

  function self.notify_stable(node_id, module_id, state)
    local safe_node_id = utils.normalize_node_id(node_id)
    if self.active and self.active.node_id == safe_node_id and self.active.module_id == module_id then
      utils.log("SEQ", ("Startup step complete: %s (%s)"):format(module_id, state or "UNKNOWN"))
      self.active = nil
      self.state = states.idle
    end
  end

  return self
end

return sequencer
