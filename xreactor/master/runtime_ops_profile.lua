local M = {}

function M.estimate_base_power(runtime)
  local total = 0
  for _, node in pairs(runtime.state.nodes) do
    if node.role == runtime.libs.constants.roles.RT_NODE then
      total = total + (node.output or 0)
    end
  end
  if total > 0 then return total end
  if runtime.state.power_target > 0 then return runtime.state.power_target end
  return 0
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
  runtime.log(("Profile applied: %s (target_factor=%s, ramp=%s)"):format(tostring(name), tostring(profile.target), tostring(runtime.refs.sequencer.ramp_profile)), "INFO")
  local base = M.estimate_base_power(runtime)
  if base > 0 then
    runtime.state.power_target = base * profile.target
    runtime.log(("Power target recalculated from profile %s: base=%.2f -> target=%.2f"):format(tostring(name), base, runtime.state.power_target), "INFO")
    for _, node in pairs(runtime.state.nodes) do
      if node.role == runtime.libs.constants.roles.RT_NODE then
        runtime.mark_rt_sync_dirty(node, "profile_change")
      end
    end
    runtime.flush_rt_sync_queue({ force = true })
  else
    runtime.log(("Profile %s applied but base power is unavailable; target unchanged"):format(tostring(name)), "WARN")
  end
end

function M.set_rt_global_hold(runtime, enabled)
  local next_value = enabled == true
  if runtime.state.rt_global_off_hold == next_value then return end
  runtime.state.rt_global_off_hold = next_value
  runtime.log("RT global hold " .. (runtime.state.rt_global_off_hold and "ENABLED (0%)" or "DISABLED (normal control)"), "WARN")
  for _, node in pairs(runtime.state.nodes) do
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
  for _, node in pairs(runtime.state.nodes) do
    if node.role == runtime.libs.constants.roles.RT_NODE then
      power = power + (node.output or 0)
    elseif node.role == runtime.libs.constants.roles.ENERGY_NODE then
      stored = stored + (node.stored or 0)
      capacity = capacity + (node.capacity or 0)
    elseif node.role == runtime.libs.constants.roles.WATER_NODE then
      water_total = node.total_water or water_total
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
    else runtime.state.trend_cache.energy_arrow = "→" end
  end
  runtime.refs.trends:push("water", water_total)
  if runtime.state.auto_profile then
    if energy_pct > 90 and runtime.state.active_profile ~= "IDLE" then
      M.apply_profile(runtime, "IDLE")
    elseif energy_pct < 30 and runtime.state.active_profile ~= "PEAK" then
      M.apply_profile(runtime, "PEAK")
    end
  end
end

return M
