local constants = require("shared.constants")
local health = require("core.health")

local rules = {}

local function now_ms()
  return os.epoch("utc")
end

local function has_reason(reasons, code)
  if type(reasons) == "table" then
    if reasons[code] then
      return true
    end
    for _, entry in ipairs(reasons) do
      if entry == code then
        return true
      end
    end
  end
  return false
end

local function build_reason_text(reasons)
  if type(reasons) ~= "table" then
    return nil
  end
  local list = {}
  for key, value in pairs(reasons) do
    if value == true then
      table.insert(list, tostring(key))
    end
  end
  for _, value in ipairs(reasons) do
    table.insert(list, tostring(value))
  end
  if #list == 0 then
    return nil
  end
  table.sort(list)
  return table.concat(list, ", ")
end

local function build_source(node, device_id)
  return {
    node_id = node.id,
    role = node.role,
    device_id = device_id
  }
end

local function severity_for_proto(node)
  if node.role == constants.roles.RT_NODE then
    return "CRITICAL"
  end
  return "WARN"
end

local function rule_state(self, key)
  local state = self.state[key]
  if not state then
    state = { active = false, since = nil, clear_since = nil, last_emit = 0, last_active = false }
    self.state[key] = state
  end
  return state
end

local function should_raise(state, active, now, opts)
  local raise_ms = (opts.raise_after_s or 0) * 1000
  local clear_ms = (opts.clear_after_s or 0) * 1000
  local cooldown_ms = (opts.cooldown_s or 0) * 1000
  if active then
    if not state.active then
      state.since = state.since or now
      if now - state.since >= raise_ms and now - (state.last_emit or 0) >= cooldown_ms then
        state.active = true
        state.clear_since = nil
        state.last_emit = now
        return "raise"
      end
    else
      if now - (state.last_emit or 0) >= cooldown_ms then
        state.last_emit = now
        return "raise"
      end
    end
  else
    state.since = nil
    if state.active then
      state.clear_since = state.clear_since or now
      if now - state.clear_since >= clear_ms then
        state.active = false
        state.clear_since = nil
        return "clear"
      end
    end
  end
  return nil
end

function rules.new(config)
  local self = {
    config = config or {},
    state = {}
  }
  return setmetatable(self, { __index = rules })
end

function rules:evaluate(context)
  context = context or {}
  local now = context.now or now_ms()
  local cfg = context.config or self.config or {}
  local nodes = context.nodes or {}
  local alerts = {}
  local clears = {}

  local base_opts = {
    raise_after_s = cfg.alert_raise_after_s or cfg.alert_debounce_s or 1,
    clear_after_s = cfg.alert_clear_after_s or cfg.alert_clear_s or 2,
    cooldown_s = cfg.alert_cooldown_s or 5
  }

  local function emit(key, active, opts, builder)
    local state = rule_state(self, key)
    local action = should_raise(state, active, now, opts or base_opts)
    if action == "raise" then
      local entry = builder(state)
      if entry then
        entry.key = key
        table.insert(alerts, entry)
      end
    elseif action == "clear" then
      table.insert(clears, key)
    end
  end

  for _, node in pairs(nodes) do
    local reasons = node.health and node.health.reasons
    local comms_down = node.health and node.health.status == health.status.DOWN
    comms_down = comms_down or has_reason(reasons, health.reasons.COMMS_DOWN)
    local down_key = string.format("NODE_COMMS_DOWN|%s", tostring(node.id))
    emit(down_key, comms_down, {
      raise_after_s = cfg.comms_down_warn_secs or base_opts.raise_after_s,
      clear_after_s = cfg.alert_clear_after_s or cfg.alert_clear_s or base_opts.clear_after_s,
      cooldown_s = base_opts.cooldown_s
    }, function(state)
      local down_for = state.since and math.floor((now - state.since) / 1000) or (node.down_since and math.floor((now - node.down_since) / 1000)) or nil
      local detail = down_for and ("down %ds"):format(down_for) or "down"
      local crit_after = cfg.comms_down_crit_secs or 12
      local severity = down_for and down_for >= crit_after and "CRITICAL" or "WARN"
      return {
        code = "NODE_COMMS_DOWN",
        severity = severity,
        scope = "NODE",
        source = build_source(node),
        title = "Node comms down",
        message = string.format("%s (%s)", tostring(node.id or "NODE"), detail),
        details = { down_for_s = down_for, warn_after_s = cfg.comms_down_warn_secs or base_opts.raise_after_s, crit_after_s = crit_after }
      }
    end)

    local degraded = node.health and node.health.status == health.status.DEGRADED
    local degraded_key = string.format("NODE_DEGRADED|%s", tostring(node.id))
    emit(degraded_key, degraded, base_opts, function()
      local reason_text = build_reason_text(reasons) or "unknown"
      return {
        code = "NODE_DEGRADED",
        severity = "WARN",
        scope = "NODE",
        source = build_source(node),
        title = "Node degraded",
        message = string.format("%s (%s)", tostring(node.id or "NODE"), reason_text),
        details = { reasons = reason_text }
      }
    end)

    local proto_mismatch = has_reason(reasons, health.reasons.PROTO_MISMATCH)
    local proto_key = string.format("PROTO_MISMATCH|%s", tostring(node.id))
    emit(proto_key, proto_mismatch, base_opts, function()
      local version = node.proto_ver or "unknown"
      return {
        code = "PROTO_MISMATCH",
        severity = severity_for_proto(node),
        scope = "NODE",
        source = build_source(node),
        title = "Protocol mismatch",
        message = string.format("%s proto %s", tostring(node.id or "NODE"), tostring(version)),
        details = { proto = version }
      }
    end)
  end

  local stored = 0
  local capacity = 0
  local matrices = {}
  for _, node in pairs(nodes) do
    if node.role == constants.roles.ENERGY_NODE then
      stored = stored + (node.stored or 0)
      capacity = capacity + (node.capacity or 0)
      for _, matrix in ipairs(node.matrices or {}) do
        table.insert(matrices, { matrix = matrix, node = node })
      end
      local matrix_missing = has_reason(node.health and node.health.reasons, health.reasons.NO_MATRIX)
      local matrix_key = string.format("MATRIX_MISSING|%s", tostring(node.id))
      emit(matrix_key, matrix_missing, base_opts, function()
        local matrix_count = node.matrix_count or node.matrix_bound or 0
        local storage_count = node.storage_bound_count or 0
        local severity = (storage_count == 0 and matrix_count == 0) and "CRITICAL" or "WARN"
        return {
          code = "MATRIX_MISSING",
          severity = severity,
          scope = "NODE",
          source = build_source(node),
          title = "Matrix missing",
          message = string.format("%s matrix bound=0", tostring(node.id or "ENERGY")),
          details = { matrix_count = matrix_count, storage_count = storage_count }
        }
      end)
    end
  end

  if capacity > 0 then
    local pct = (stored / capacity) * 100
    local warn = cfg.energy_warn_pct or 25
    local crit = cfg.energy_crit_pct or 10
    local active = pct <= warn
    local key = "ENERGY_LOW"
    emit(key, active, base_opts, function()
      local severity = pct <= crit and "CRITICAL" or "WARN"
      return {
        code = "ENERGY_LOW",
        severity = severity,
        scope = "SYSTEM",
        source = { node_id = "MASTER", role = "MASTER" },
        title = "Energy low",
        message = string.format("Total energy %.1f%%", pct),
        details = { percent = pct, warn = warn, crit = crit }
      }
    end)
  end

  local matrix_warn = cfg.matrix_warn_full_pct or 90
  for _, entry in ipairs(matrices) do
    local matrix = entry.matrix
    local node = entry.node
    local percent = (matrix.percent or 0) * 100
    local active = percent >= matrix_warn
    local matrix_id = matrix.id or matrix.name or matrix.label
    local key = string.format("MATRIX_NEAR_FULL|%s|%s", tostring(node.id), tostring(matrix_id))
    emit(key, active, base_opts, function()
      return {
        code = "MATRIX_NEAR_FULL",
        severity = "WARN",
        scope = "DEVICE",
        source = build_source(node, matrix_id),
        title = "Matrix near full",
        message = string.format("%s %.1f%%", tostring(matrix.label or matrix_id or "matrix"), percent),
        details = { percent = percent, threshold = matrix_warn }
      }
    end)
  end

  local demand = context.power_target and context.power_target > 0
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      local turbines = node.turbines or {}
      local warn_low = cfg.rpm_warn_low or 800
      local crit_high = cfg.rpm_crit_high or 1800
      for _, turbine in ipairs(turbines) do
        local rpm = turbine.rpm or 0
        local turbine_id = turbine.id or turbine.name
        local low_active = rpm > 0 and rpm < warn_low and (demand or (node.output or 0) > 0)
        local low_key = string.format("TURBINE_RPM_LOW|%s|%s", tostring(node.id), tostring(turbine_id))
        emit(low_key, low_active, base_opts, function()
          return {
            code = "TURBINE_RPM_LOW",
            severity = "WARN",
            scope = "DEVICE",
            source = build_source(node, turbine_id),
            title = "Turbine RPM low",
            message = string.format("%s %.0f RPM", tostring(turbine_id or "turbine"), rpm),
            details = { rpm = rpm, threshold = warn_low }
          }
        end)

        local high_active = rpm > crit_high
        local high_key = string.format("TURBINE_OVERSPEED|%s|%s", tostring(node.id), tostring(turbine_id))
        emit(high_key, high_active, base_opts, function()
          return {
            code = "TURBINE_OVERSPEED",
            severity = "CRITICAL",
            scope = "DEVICE",
            source = build_source(node, turbine_id),
            title = "Turbine overspeed",
            message = string.format("%s %.0f RPM", tostring(turbine_id or "turbine"), rpm),
            details = { rpm = rpm, threshold = crit_high }
          }
        end)

        local coil_active = turbine.coil_engaged and rpm > 0 and rpm < warn_low
        local coil_key = string.format("COIL_EARLY|%s|%s", tostring(node.id), tostring(turbine_id))
        emit(coil_key, coil_active, base_opts, function()
          return {
            code = "COIL_EARLY",
            severity = "WARN",
            scope = "DEVICE",
            source = build_source(node, turbine_id),
            title = "Coil engaged early",
            message = string.format("%s coil at %.0f RPM", tostring(turbine_id or "turbine"), rpm),
            details = { rpm = rpm, threshold = warn_low }
          }
        end)
      end

      local reactors = node.reactors or {}
      local steam_target = node.steam or 0
      local steam_prod = 0
      for _, reactor in ipairs(reactors) do
        steam_prod = steam_prod + (reactor.steam_production or 0)
      end
      local deficit = steam_target > 0 and steam_prod < steam_target * (cfg.steam_deficit_pct or 0.9)
      for _, reactor in ipairs(reactors) do
        local reactor_id = reactor.id or reactor.name
        local rod_key = string.format("REACTOR_RODS_STUCK|%s|%s", tostring(node.id), tostring(reactor_id))
        local rod_state = rule_state(self, rod_key)
        local rods = reactor.rods_level
        if rods ~= nil then
          if rod_state.last_rods ~= rods then
            rod_state.last_rods = rods
            rod_state.last_change = now
          end
        end
        local stuck_active = deficit and rods ~= nil and rod_state.last_change and (now - rod_state.last_change) >= (cfg.rod_stuck_secs or 20) * 1000
        emit(rod_key, stuck_active, base_opts, function()
          return {
            code = "REACTOR_RODS_STUCK",
            severity = "WARN",
            scope = "DEVICE",
            source = build_source(node, reactor_id),
            title = "Reactor rods stuck",
            message = string.format("%s rods %.0f%%, steam %.0f/%.0f", tostring(reactor_id or "reactor"), rods or 0, steam_prod, steam_target),
            details = { rods = rods, steam_target = steam_target, steam_production = steam_prod }
          }
        end)
      end
    end
  end

  if context.recovery_notice then
    local recovery = context.recovery_notice
    local active = recovery.active
    local key = "UPDATE_RECOVERY"
    emit(key, active, base_opts, function()
      return {
        code = "UPDATE_RECOVERY",
        severity = "WARN",
        scope = "SYSTEM",
        source = { node_id = "MASTER", role = "MASTER" },
        title = "Update recovery",
        message = recovery.message or "Update recovery executed",
        details = recovery.details
      }
    end)
  end

  return alerts, clears
end

return rules
