-- nodes/rt/capacity_learning.lua
-- Continuous RT turbine-capacity learning.

local M = {}

local TARGET_RPM = 900
local TOLERANCE_RPM = 15
local MIN_FRACTION = 0.8

local function numeric_value(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then local n = tonumber(v); if n then return n end end
  return nil
end

local function measure(turbines)
  local total = type(turbines) == "table" and #turbines or 0
  if total == 0 then return nil, 0, 0 end
  local at_target, at_target_output = 0, 0
  for _, t in ipairs(turbines) do
    local rpm = numeric_value(t.rpm)
    local energy = numeric_value(t.energy) or 0
    if rpm and t.coil_engaged ~= false
        and math.abs(rpm - TARGET_RPM) <= TOLERANCE_RPM
        and energy > 0 then
      at_target = at_target + 1
      at_target_output = at_target_output + energy
    end
  end
  local min_required = math.max(1, math.ceil(total * MIN_FRACTION))
  if at_target < min_required then return nil, at_target, total end
  return math.floor((at_target_output / at_target) * total), at_target, total
end

local function topology_signature(turbines)
  local ids = {}
  for index, turbine in ipairs(type(turbines) == "table" and turbines or {}) do
    ids[#ids + 1] = tostring(turbine.id or turbine.name or ("#" .. tostring(index)))
  end
  table.sort(ids)
  return table.concat(ids, "|")
end

local function copy_state(source)
  local out = {}
  for key, value in pairs(type(source) == "table" and source or {}) do out[key] = value end
  return out
end

function M.new_state()
  return {
    ready = false,
    max_output = 0,
    at_target = 0,
    total_turbines = 0,
    reason = "INIT",
    topology_signature = nil,
    topology_generation = 0,
    topology_changed_at = nil,
  }
end

function M.update(ctx, turbines)
  local previous_state = type(ctx.capacity_learning) == "table"
      and ctx.capacity_learning or M.new_state()

  -- Copy-on-write is intentional. RT main keeps the last committed state in
  -- capacity_learning_state and compares it with ctx.capacity_learning to
  -- decide whether to persist. In-place mutation made both variables point
  -- at the same already-updated table, so an increased maximum was invisible
  -- to that comparison and was never saved after the first measurement.
  local learning = copy_state(previous_state)
  ctx.capacity_learning = learning
  local log = type(ctx.log) == "function" and ctx.log or function() end

  local signature = topology_signature(turbines)
  if learning.topology_signature ~= signature then
    local had_learned_value = learning.ready == true or (tonumber(learning.max_output) or 0) > 0
    local previous_signature = learning.topology_signature
    learning.topology_signature = signature
    learning.topology_generation = (tonumber(learning.topology_generation) or 0) + 1
    learning.topology_changed_at = os and os.epoch and os.epoch("utc") or nil
    if previous_signature ~= nil or had_learned_value then
      learning.ready = false
      learning.max_output = 0
      learning.reason = "TOPOLOGY_CHANGED"

      -- A changed topology may legitimately learn a LOWER maximum. The
      -- existing RT main persistence gate saves only when new > previous.
      -- Invalidate the old committed comparison baseline so the first valid
      -- measurement of this new topology is persisted regardless of whether
      -- it is lower or higher than the old hardware layout.
      if previous_state ~= learning then previous_state.max_output = 0 end

      pcall(log, "WARN", string.format(
        "RT capacity topology changed generation=%d old=%s new=%s; learned maximum invalidated",
        learning.topology_generation, tostring(previous_signature), tostring(signature)))
    else
      learning.reason = "TOPOLOGY_INIT"
    end
  end

  local measured, at_target, total = measure(turbines)
  learning.at_target = at_target
  learning.total_turbines = total

  if measured then
    if not learning.ready then
      learning.max_output = measured
      learning.ready = true
      learning.reason = "MEASURED"
      pcall(log, "INFO", string.format(
        "RT capacity measured output=%.2f at_target=%d/%d", measured, at_target, total))
    elseif measured > (tonumber(learning.max_output) or 0) then
      learning.max_output = measured
      learning.reason = "UPDATED"
      pcall(log, "INFO", string.format(
        "RT capacity updated output=%.2f at_target=%d/%d", measured, at_target, total))
    else
      learning.reason = "STABLE"
    end
  else
    learning.reason = total == 0 and "NO_TURBINES" or "NONE_AT_TARGET"
  end

  return learning
end

return M
