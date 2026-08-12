-- master/runtime_ops_profile.lua
-- Profile and trend control for MASTER.

local M = {}

local function number_or(value, fallback)
  if type(value) == "number" then return value end
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed then return parsed end
  end
  return fallback
end

local function node_available(node, constants)
  if type(node) ~= "table" then return false end
  if node.offline == true or node.stale == true then return false end
  local offline = constants and constants.status_levels and constants.status_levels.OFFLINE or "OFFLINE"
  if tostring(node.status or ""):upper() == tostring(offline):upper() then return false end
  return true
end

function M.estimate_base_power(runtime)
  local measured_total = 0
  local learned_capacity_total = 0
  local rt_count = 0
  local available_count = 0
  local constants = runtime.libs.constants

  for _, node in pairs(runtime.state.nodes or {}) do
    if node.role == constants.roles.RT_NODE then
      rt_count = rt_count + 1
      if node_available(node, constants) then
        available_count = available_count + 1
        local output = number_or(node.actual_output, nil)
          or number_or(node.power_actual, nil)
          or number_or(node.output, 0)
        measured_total = measured_total + output

        -- Capacity is a control input, so both freshness/availability and the
        -- RT's explicit learning-ready signal are mandatory. A remembered
        -- max from an offline/stale node must never inflate the current fleet
        -- basis.
        local capacity_ready = (node.rt and node.rt.capacity_ready == true)
          or node.capacity_ready == true
        local cap = number_or(node.capacity_max, nil)
          or number_or(node.rt and node.rt.capacity_max, nil)
        if capacity_ready and cap and cap > 0 then
          learned_capacity_total = learned_capacity_total + cap
        end
      end
    end
  end

  if learned_capacity_total > 0 then return learned_capacity_total, "learned-capacity" end
  if measured_total > 0 then return measured_total, "measured" end
  -- If no RT is currently available, an old target is not a trustworthy
  -- capacity estimate. Returning 0 keeps profile math from reviving stale
  -- fleet capacity.
  if available_count == 0 then return 0, "no-available-rt" end
  if runtime.state.power_target and runtime.state.power_target > 0 then
    return runtime.state.power_target, "previous-target"
  end
  return 0, "unavailable"
end

function M.apply_profile(runtime, name)
  if runtime.state.rt_global_off_hold then
    runtime.log("Ignoring profile change while RT-OFF hold is active", "WARN")
    return
  end
  local profile = runtime.libs.profiles[name]
  if not profile then return end
  runtime.state.active_profile = name
  runtime.refs.sequencer.ramp_profile = profile.ramp or runtime.refs.sequencer.ramp_profile
  runtime.log(("Profile applied: %s (target_factor=%s, ramp=%s)"):format(
    tostring(name), tostring(profile.target), tostring(runtime.refs.sequencer.ramp_profile)), "INFO")
  local base, base_source = M.estimate_base_power(runtime)
  if base > 0 then
    runtime.state.power_target = base * profile.target
    runtime.log(("Power target recalculated from profile %s: base=%.2f source=%s -> target=%.2f"):format(
      tostring(name), base, tostring(base_source or "unknown"), runtime.state.power_target), "INFO")
    for _, node in pairs(runtime.state.nodes or {}) do
      if node.role == runtime.libs.constants.roles.RT_NODE then
        runtime.mark_rt_sync_dirty(node, "profile_change")
      end
    end
    runtime.flush_rt_sync_queue({ force = true })
  else
    runtime.log(("Profile %s applied but base power is unavailable; target unchanged at %.2f"):format(
      tostring(name), tonumber(runtime.state.power_target) or 0), "WARN")
    runtime.state.pending_profile_retry = name
  end
end

function M.retry_pending_profile(runtime)
  local pending = runtime.state.pending_profile_retry
  if not pending then return end
  local current_target = tonumber(runtime.state.power_target) or 0
  if current_target > 0 then
    runtime.state.pending_profile_retry = nil
    return
  end
  runtime.log(("Profile retry: %s (power_target war 0)"):format(tostring(pending)), "INFO")
  runtime.state.pending_profile_retry = nil
  M.apply_profile(runtime, pending)
end

function M.set_rt_global_hold(runtime, enabled)
  local next_value = enabled == true
  if runtime.state.rt_global_off_hold == next_value then return end
  runtime.state.rt_global_off_hold = next_value
  runtime.log("RT global hold " .. (runtime.state.rt_global_off_hold and "ENABLED (0%)" or "DISABLED (normal control)"), "WARN")
  for _, node in pairs(runtime.state.nodes or {}) do
    if node.role == runtime.libs.constants.roles.RT_NODE then
      runtime.mark_rt_sync_dirty(node, "global_hold_toggle")
    end
  end
  runtime.flush_rt_sync_queue({ force = true })
end

function M.sample_trends(runtime)
  local now = os.epoch("utc")
  if now - runtime.state.last_trend_sample < 1000 then return end
  runtime.state.last_trend_sample = now
  local power, stored, capacity, water_total = 0, 0, 0, 0
  local seen_energy_nodes, fresh_energy_nodes = 0, 0
  local constants = runtime.libs.constants

  for _, node in pairs(runtime.state.nodes or {}) do
    if node.role == constants.roles.RT_NODE then
      if node_available(node, constants) then
        power = power + (number_or(node.actual_output, nil)
          or number_or(node.power_actual, nil) or number_or(node.output, 0))
      end
    elseif node.role == constants.roles.ENERGY_NODE then
      seen_energy_nodes = seen_energy_nodes + 1
      if node_available(node, constants) and node.data_stale ~= true then
        fresh_energy_nodes = fresh_energy_nodes + 1
        stored = stored + (number_or(node.stored, 0) or 0)
        capacity = capacity + (number_or(node.capacity, 0) or 0)
      end
    elseif node.role == constants.roles.WATER_NODE then
      if node_available(node, constants) then water_total = node.total_water or water_total end
    end
  end

  local energy_pct = capacity > 0 and (stored / capacity) * 100 or 0
  runtime.refs.trends:push("power", power)
  if runtime.refs.trends:push("energy", energy_pct) then
    local trend_values = runtime.refs.trends:values("energy")
    runtime.state.trend_cache.energy = trend_values
    if #trend_values >= 2 then
      local last = trend_values[#trend_values]
      local prev = trend_values[#trend_values - 1]
      if last > prev + 0.5 then runtime.state.trend_cache.energy_arrow = "↑"
      elseif last < prev - 0.5 then runtime.state.trend_cache.energy_arrow = "↓"
      else runtime.state.trend_cache.energy_arrow = "→" end
    else
      runtime.state.trend_cache.energy_arrow = "→"
    end
  end
  runtime.refs.trends:push("water", water_total)

  local auto_profile_has_trustworthy_energy = not (seen_energy_nodes > 0 and fresh_energy_nodes == 0)
  if runtime.state.auto_profile and auto_profile_has_trustworthy_energy then
    local idle_threshold = tonumber(runtime.state.idle_threshold_pct)
      or tonumber(runtime.config and runtime.config.idle_threshold_pct) or 90
    local peak_threshold = tonumber(runtime.state.peak_threshold_pct)
      or tonumber(runtime.config and runtime.config.peak_threshold_pct) or 30
    local shed_threshold = tonumber(runtime.state.shed_threshold_pct)
      or tonumber(runtime.config and runtime.config.shed_threshold_pct) or 98
    shed_threshold = math.max(shed_threshold, idle_threshold + 1)
    idle_threshold = math.max(idle_threshold, peak_threshold + 5)

    if energy_pct >= shed_threshold then
      if runtime.state.power_target ~= 0 or runtime.state.active_profile ~= "IDLE" then
        runtime.state.active_profile = "IDLE"
        runtime.state.power_target = 0
        if runtime.log then
          runtime.log(("Energy %.1f%% >= Shed-Schwelle %.1f%% — power_target auf 0 gesetzt, alle RT auf shed"):format(
            energy_pct, shed_threshold), "INFO")
        end
      end
    elseif (not runtime.state.power_target or runtime.state.power_target <= 0) then
      M.apply_profile(runtime, runtime.state.active_profile or "BASELOAD")
    elseif energy_pct > idle_threshold and runtime.state.active_profile ~= "IDLE" then
      M.apply_profile(runtime, "IDLE")
    elseif energy_pct < peak_threshold and runtime.state.active_profile ~= "PEAK" then
      M.apply_profile(runtime, "PEAK")
    else
      runtime.state.last_capacity_recheck = runtime.state.last_capacity_recheck or 0
      if now - runtime.state.last_capacity_recheck >= 30000 then
        runtime.state.last_capacity_recheck = now
        local base = M.estimate_base_power(runtime)
        local current_target = tonumber(runtime.state.power_target) or 0
        if base > 0 and current_target > 0 and base > current_target * 1.05 then
          M.apply_profile(runtime, runtime.state.active_profile or "BASELOAD")
        end
      end
    end
  end
end

return M
