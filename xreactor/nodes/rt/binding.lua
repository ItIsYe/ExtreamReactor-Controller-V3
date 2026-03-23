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
  if kind == "reactor" then
    return policy.allow_all_reactors or policy.reactor_set[name] or false
  end
  if kind == "turbine" then
    return policy.allow_all_turbines or policy.turbine_set[name] or false
  end
  return false
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
