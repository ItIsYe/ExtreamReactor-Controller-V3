-- Continuous turbine-capacity learning tied to the physical topology.

local M = {}

local TARGET_RPM = 900
local TOLERANCE_RPM = 15
local MIN_FRACTION = 0.8

local function numeric(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then return tonumber(value) end
  return nil
end

local function copy_state(source)
  local result = {}
  for key, value in pairs(type(source) == "table" and source or {}) do
    result[key] = value
  end
  return result
end

function M.topology_signature(turbines)
  local identities = {}
  for index, turbine in ipairs(type(turbines) == "table" and turbines or {}) do
    if type(turbine) == "table" then
      identities[#identities + 1] = tostring(turbine.id or turbine.name or ("#" .. index))
    else
      identities[#identities + 1] = tostring(turbine)
    end
  end
  table.sort(identities)
  return table.concat(identities, "|")
end

local function measure(turbines)
  local total = type(turbines) == "table" and #turbines or 0
  if total == 0 then return nil, 0, 0 end

  local at_target, output = 0, 0
  for _, turbine in ipairs(turbines) do
    local rpm = numeric(turbine.rpm)
    local energy = numeric(turbine.energy) or 0
    if rpm and turbine.coil_engaged ~= false
        and math.abs(rpm - TARGET_RPM) <= TOLERANCE_RPM
        and energy > 0 then
      at_target = at_target + 1
      output = output + energy
    end
  end
  if at_target < math.max(1, math.ceil(total * MIN_FRACTION)) then
    return nil, at_target, total
  end
  return math.floor((output / at_target) * total), at_target, total
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
    dirty = false,
  }
end

function M.update(ctx, turbines)
  local previous = type(ctx.capacity_learning) == "table"
    and ctx.capacity_learning or M.new_state()
  local learning = copy_state(previous)
  ctx.capacity_learning = learning
  local log = type(ctx.log) == "function" and ctx.log or function() end

  local signature = M.topology_signature(turbines)
  if learning.topology_signature ~= signature then
    local old_signature = learning.topology_signature
    local had_capacity = learning.ready == true or (tonumber(learning.max_output) or 0) > 0
    learning.topology_signature = signature
    learning.topology_generation = (tonumber(learning.topology_generation) or 0) + 1
    learning.topology_changed_at = os and os.epoch and os.epoch("utc") or nil
    learning.ready = false
    learning.max_output = 0
    learning.reason = old_signature == nil and not had_capacity
      and "TOPOLOGY_INIT" or "TOPOLOGY_CHANGED"
    learning.dirty = true
    if old_signature ~= nil or had_capacity then
      pcall(log, "WARN", "RT capacity topology changed; learned maximum invalidated")
    end
  end

  local measured, at_target, total = measure(turbines)
  learning.at_target = at_target
  learning.total_turbines = total
  if measured then
    if learning.ready ~= true then
      learning.max_output = measured
      learning.ready = true
      learning.reason = "MEASURED"
      learning.dirty = true
      pcall(log, "INFO", string.format(
        "RT capacity measured output=%.2f at_target=%d/%d", measured, at_target, total))
    elseif measured > (tonumber(learning.max_output) or 0) then
      learning.max_output = measured
      learning.reason = "UPDATED"
      learning.dirty = true
      pcall(log, "INFO", string.format(
        "RT capacity updated output=%.2f at_target=%d/%d", measured, at_target, total))
    else
      learning.reason = "STABLE"
    end
  elseif learning.reason ~= "TOPOLOGY_CHANGED" and learning.reason ~= "TOPOLOGY_INIT" then
    learning.reason = total == 0 and "NO_TURBINES" or "NONE_AT_TARGET"
  end
  return learning
end

return M
