local binding = {}

local function normalize_names(list)
  local normalized = {}
  if type(list) ~= "table" then
    return normalized
  end
  for _, value in ipairs(list) do
    if type(value) == "string" and value ~= "" then
      normalized[#normalized + 1] = value
    end
  end
  return normalized
end

local function to_set(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[value] = true
  end
  return out
end

function binding.build_policy(configured_reactors, configured_turbines)
  local reactors = normalize_names(configured_reactors)
  local turbines = normalize_names(configured_turbines)
  return {
    reactors = reactors,
    turbines = turbines,
    reactor_set = to_set(reactors),
    turbine_set = to_set(turbines),
    allow_all_reactors = #reactors == 0,
    allow_all_turbines = #turbines == 0
  }
end

function binding.should_bind(kind, name, policy)
  local allowed = binding.should_bind_with_reason(kind, name, policy)
  return allowed
end

function binding.should_bind_with_reason(kind, name, policy)
  if kind == "reactor" then
    if policy.allow_all_reactors then
      return true, "auto-discovery enabled (reactors list empty)"
    end
    if policy.reactor_set[name] then
      return true, "configured reactor name match"
    end
    return false, "reactor not listed in explicit config"
  end
  if kind == "turbine" then
    if policy.allow_all_turbines then
      return true, "auto-discovery enabled (turbines list empty)"
    end
    if policy.turbine_set[name] then
      return true, "configured turbine name match"
    end
    return false, "turbine not listed in explicit config"
  end
  return false, "unsupported device kind"
end

function binding.mode_label(kind, policy)
  if kind == "reactor" then
    return policy.allow_all_reactors and "auto-discovery" or "explicit"
  end
  if kind == "turbine" then
    return policy.allow_all_turbines and "auto-discovery" or "explicit"
  end
  return "unknown"
end

function binding.detect_kind(type_name, methods)
  local method_set = methods or {}
  local normalized_type = tostring(type_name or ""):lower()
  if normalized_type:find("turbine", 1, true) then
    return "turbine", "type=" .. tostring(type_name)
  end
  if normalized_type:find("reactor", 1, true) then
    return "reactor", "type=" .. tostring(type_name)
  end
  if method_set.getRotorSpeed or method_set.getRotorRPM or method_set.setFluidFlowRateMax or method_set.setFluidFlowRate then
    return "turbine", "turbine method signature"
  end
  if method_set.getControlRodLevel or method_set.setAllControlRodLevels or method_set.getFuelAmount then
    return "reactor", "reactor method signature"
  end
  return nil, "unsupported signature"
end

function binding.missing_devices_message(kind, policy)
  local noun = kind == "reactor" and "reactors" or "turbines"
  if binding.mode_label(kind, policy) == "auto-discovery" then
    return string.format(
      "No %s are currently bound. RT auto-discovery is active; attach local %s peripherals or add explicit names in /xreactor/nodes/rt/config.lua.",
      noun,
      noun
    )
  end
  local configured = kind == "reactor" and policy.reactors or policy.turbines
  return string.format(
    "No %s are currently bound. RT is restricted to explicit names: %s. Update /xreactor/nodes/rt/config.lua or clear the list to enable auto-discovery.",
    noun,
    table.concat(configured, ", ")
  )
end

return binding
