local constants = require("shared.constants")
local protocol = require("core.protocol")
local safety = require("core.safety")
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

local function now_ms()
  return os.epoch("utc")
end

local function average(list, field)
  local sum, count = 0, 0
  for _, entry in ipairs(list or {}) do
    local value = entry[field]
    if type(value) == "number" then
      sum = sum + value
      count = count + 1
    end
  end
  if count == 0 then
    return nil
  end
  return sum / count
end

local function build_telemetry(node)
  if not node then
    return "telemetry=unavailable"
  end
  local parts = {}
  local snapshot = node.snapshot or {}
  if type(snapshot.avg_rpm) == "number" then
    table.insert(parts, ("avg_rpm=%.0f"):format(snapshot.avg_rpm))
  end
  if type(snapshot.max_temp) == "number" then
    table.insert(parts, ("max_temp=%.0f"):format(snapshot.max_temp))
  end
  local rpm = average(node.turbines, "rpm")
  if rpm then
    table.insert(parts, ("rpm=%.0f"):format(rpm))
  end
  local flow = average(node.turbines, "flow_rate")
  if flow then
    table.insert(parts, ("flow=%.0f"):format(flow))
  end
  local steam = average(node.reactors, "steam_production")
  if steam then
    table.insert(parts, ("steam=%.0f"):format(steam))
  end
  if type(node.output) == "number" then
    table.insert(parts, ("power=%.0f"):format(node.output))
  end
  if type(node.steam) == "number" then
    table.insert(parts, ("steam_target=%.0f"):format(node.steam))
  end
  return #parts > 0 and table.concat(parts, " ") or "telemetry=unavailable"
end

local function should_emergency(node, config)
  if not node then
    return false
  end
  if node.status == constants.status_levels.EMERGENCY then
    return true
  end
  local snapshot = node.snapshot or {}
  if safety.should_scram({ temperature = snapshot.max_temp, max_temperature = 950 }) then
    return true
  end
  local rpm_limit = config and config.rpm_crit_high or nil
  if rpm_limit then
    if type(snapshot.avg_rpm) == "number" and snapshot.avg_rpm > rpm_limit then
      return true
    end
    for _, entry in ipairs(node.turbines or {}) do
      if type(entry.rpm) == "number" and entry.rpm > rpm_limit then
        return true
      end
    end
  end
  return false
end

function sequencer.new(comms, ramp_profile, opts)
  opts = opts or {}
  local self = {
    queue = {},
    state = states.idle,
    active = nil,
    ramp_profile = ramp_profile or "NORMAL",
    timeout_s = tonumber(opts.timeout_s) or 60,
    alert_service = opts.alert_service,
    config = opts.config or {},
    stage_started_ms = nil
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
        table.insert(expanded, { node_id = entry.node_id })
      end
    end
    self.queue = expanded
  end

  function self.tick(nodes)
    if self.state == states.idle and #self.queue > 0 then
      if not self.queue[1].module_id then
        self.build_steps(nodes)
        if #self.queue == 0 or not self.queue[1].module_id then return end
      end
      self.active = table.remove(self.queue, 1)
      local node = nodes and nodes[self.active.node_id]
      if not node or node.mode ~= "MASTER" then
        table.insert(self.queue, 1, self.active)
        self.active = nil
        return
      end
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
      self.stage_started_ms = now_ms()
      utils.log("SEQ", "Request startup " .. tostring(self.active.module_id) .. " on " .. safe_node_id)
    elseif self.state == states.waiting_ack then
      if not self.stage_started_ms then
        self.stage_started_ms = now_ms()
      end
      local elapsed = now_ms() - self.stage_started_ms
      if elapsed >= self.timeout_s * 1000 then
        self:handle_timeout(nodes, "WAITING_ACK", elapsed)
      end
    elseif self.state == states.waiting_stable then
      if not self.stage_started_ms then
        self.stage_started_ms = now_ms()
      end
      local elapsed = now_ms() - self.stage_started_ms
      if elapsed >= self.timeout_s * 1000 then
        self:handle_timeout(nodes, "WAITING_STABLE", elapsed)
      end
    end
  end

  function self.notify_ack(node_id, module_id)
    local safe_node_id = utils.normalize_node_id(node_id)
    if self.active and self.active.node_id == safe_node_id and self.active.module_id == module_id then
      self.state = states.waiting_stable
      self.stage_started_ms = now_ms()
    end
  end

  function self.notify_stable(node_id, module_id, state)
    local safe_node_id = utils.normalize_node_id(node_id)
    if self.active and self.active.node_id == safe_node_id and self.active.module_id == module_id then
      utils.log("SEQ", ("Startup step complete: %s (%s)"):format(module_id, state or "UNKNOWN"))
      self.active = nil
      self.state = states.idle
      self.stage_started_ms = nil
    end
  end

  function self.handle_timeout(nodes, stage, elapsed_ms)
    local active = self.active or {}
    local safe_node_id = utils.normalize_node_id(active.node_id)
    local node = nodes and safe_node_id and nodes[safe_node_id] or nil
    local elapsed_s = elapsed_ms / 1000
    local telemetry = build_telemetry(node)
    utils.log("SEQ", ("Timeout stage=%s elapsed=%.1fs node=%s module=%s %s"):format(
      stage,
      elapsed_s,
      tostring(safe_node_id),
      tostring(active.module_id or "unknown"),
      telemetry
    ), "ERROR")

    local emergency = should_emergency(node, self.config)
    local next_state = emergency and constants.node_states.EMERGENCY or constants.node_states.LIMITED
    if safe_node_id and safe_node_id ~= "UNKNOWN" then
      comms:send_command(safe_node_id, {
        target = constants.command_targets.MODE,
        value = next_state
      }, { requires_applied = true })
    end

    local severity = emergency and "CRITICAL" or "WARN"
    local title = "Startup timeout"
    local message = ("Startup timeout %s after %.1fs (%s)"):format(
      tostring(active.module_id or "unknown"),
      elapsed_s,
      emergency and "EMERGENCY" or "DEGRADED"
    )
    if self.alert_service and self.alert_service.alerts then
      local entry = {
        severity = severity,
        scope = "NODE",
        source = { node_id = safe_node_id, role = constants.roles.MASTER },
        code = "SEQ_TIMEOUT",
        title = title,
        message = message,
        details = {
          stage = stage,
          elapsed_s = elapsed_s,
          module_id = active.module_id,
          telemetry = telemetry
        }
      }
      local result = self.alert_service.alerts:raise(entry)
      if result and result.alert and result.log then
        self.alert_service:log_alert(result.alert, result.event)
      end
    end

    -- Stop sequencing after timeout; LIMITED represents degraded control.
    self.queue = {}
    self.active = nil
    self.state = states.idle
    self.stage_started_ms = nil
  end

  return self
end

return sequencer
