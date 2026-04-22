local M = {}

local function normalize_bound_names(ctx, kind, names)
  local normalized = {}
  for _, name in ipairs(names or {}) do
    local ok, methods = pcall(peripheral.getMethods, name)
    local type_name = peripheral.getType(name)
    local method_set = {}
    if ok and type(methods) == "table" then
      for _, method in ipairs(methods) do
        method_set[method] = true
      end
    end
    local detected, reason = ctx.binding.detect_kind(type_name, method_set)
    if detected == kind then
      normalized[#normalized + 1] = name
    else
      ctx.log("WARN", string.format(
        "Skipping configured %s %s: detected kind=%s type=%s reason=%s",
        tostring(kind),
        tostring(name),
        tostring(detected or "unknown"),
        tostring(type_name or "n/a"),
        tostring(reason or "n/a")
      ))
    end
  end
  return normalized
end

function M.cache(ctx)
  ctx.config.reactors = normalize_bound_names(ctx, "reactor", ctx.config.reactors or {})
  ctx.config.turbines = normalize_bound_names(ctx, "turbine", ctx.config.turbines or {})
  ctx.peripherals.reactors = ctx.utils.cache_peripherals(ctx.config.reactors) or {}
  ctx.peripherals.turbines = ctx.utils.cache_peripherals(ctx.config.turbines) or {}
  for _, name in ipairs(ctx.config.reactors) do
    ctx.capability_cache.reactors[name] = ctx.build_capabilities(name)
  end
  for _, name in ipairs(ctx.config.turbines) do
    ctx.capability_cache.turbines[name] = ctx.build_capabilities(name)
  end
end

function M.build_binding_signature(reactors, turbines)
  local ids = {}
  for _, entry in ipairs(reactors or {}) do
    table.insert(ids, tostring(entry.id))
  end
  for _, entry in ipairs(turbines or {}) do
    table.insert(ids, tostring(entry.id))
  end
  table.sort(ids)
  return table.concat(ids, "|")
end

function M.refresh_bindings(ctx)
  local reactors = ctx.registry:get_bound_devices("reactor")
  local turbines = ctx.registry:get_bound_devices("turbine")
  local signature = M.build_binding_signature(reactors, turbines)
  if ctx.devices.binding_signature == signature then
    return
  end
  ctx.devices.binding_signature = signature
  local reactor_names = {}
  local turbine_names = {}
  for _, entry in ipairs(reactors) do
    table.insert(reactor_names, entry.name)
  end
  for _, entry in ipairs(turbines) do
    table.insert(turbine_names, entry.name)
  end
  ctx.config.reactors = reactor_names
  ctx.config.turbines = turbine_names
  ctx.devices.reactors = reactors
  ctx.devices.turbines = turbines
  M.cache(ctx)
  ctx.build_modules()
  ctx.refresh_module_peripherals()
end

function M.discover(ctx)
  local names = peripheral.getNames() or {}
  table.sort(names)
  local binding_policy = ctx.binding.build_policy(ctx.configured_reactors, ctx.configured_turbines)
  local adapter_map = { reactors = {}, turbines = {} }
  local registry_devices = {}
  local visible_counts = { reactor = 0, turbine = 0 }
  local bound_counts = { reactor = 0, turbine = 0 }
  local binding_decisions = {}
  local discovery_had_errors = false

  local function add_binding_decision(kind, name, type_name, bound, reason, is_error)
    table.insert(binding_decisions, {
      kind = kind,
      name = name,
      type_name = type_name,
      bound = bound and true or false,
      reason = reason,
      error = is_error and true or false
    })
    if is_error then
      discovery_had_errors = true
    end
  end

  for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
      table.insert(registry_devices, {
        name = name,
        type = "monitor",
        methods = ctx.utils.safe_get_methods(name) or {},
        kind = "monitor",
        bound = ctx.monitor_name == name
      })
    end
  end

  for _, name in ipairs(names) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if not ok or type(methods) ~= "table" then
      add_binding_decision("unknown", name, peripheral.getType(name), false, "methods unavailable", true)
      goto continue
    end
    local method_set = {}
    for _, method in ipairs(methods) do
      method_set[method] = true
    end
    local type_name = peripheral.getType(name)
    local kind, kind_reason = ctx.binding.detect_kind(type_name, method_set)
    if kind == "reactor" then
      visible_counts.reactor = visible_counts.reactor + 1
      local info = ctx.reactor_adapter.inspect(name, ctx.log_prefix)
      if info then
        local bound, reason = ctx.binding.should_bind_with_reason("reactor", name, binding_policy)
        if bound then
          adapter_map.reactors[name] = info
          bound_counts.reactor = bound_counts.reactor + 1
        end
        add_binding_decision("reactor", name, type_name, bound, reason)
        table.insert(registry_devices, {
          name = name,
          type = info.type,
          methods = info.methods,
          kind = "reactor",
          bound = bound,
          features = info.features,
          schema = info.schema
        })
      else
        add_binding_decision("reactor", name, type_name, false, "adapter inspect failed", true)
      end
    elseif kind == "turbine" then
      visible_counts.turbine = visible_counts.turbine + 1
      local info = ctx.turbine_adapter.inspect(name, ctx.log_prefix)
      if info then
        local bound, reason = ctx.binding.should_bind_with_reason("turbine", name, binding_policy)
        if bound then
          adapter_map.turbines[name] = info
          bound_counts.turbine = bound_counts.turbine + 1
        end
        add_binding_decision("turbine", name, type_name, bound, reason)
        table.insert(registry_devices, {
          name = name,
          type = info.type,
          methods = info.methods,
          kind = "turbine",
          bound = bound,
          features = info.features,
          schema = info.schema
        })
      else
        add_binding_decision("turbine", name, type_name, false, "adapter inspect failed", true)
      end
    else
      add_binding_decision("unknown", name, type_name, false, tostring(kind_reason), false)
    end
    ::continue::
  end

  local summary = {
    visible_reactors = visible_counts.reactor,
    visible_turbines = visible_counts.turbine,
    bound_reactors = bound_counts.reactor,
    bound_turbines = bound_counts.turbine
  }
  local discovery_signature = ctx.discovery_log.build_signature(summary, binding_decisions)
  local log_details = ctx.discovery_log.should_log_details(ctx.devices.discovery_log_signature, discovery_signature, discovery_had_errors)
  ctx.devices.discovery_log_signature = discovery_signature
  if log_details then
    for _, decision in ipairs(binding_decisions) do
      local action = decision.bound and "bound" or "rejected"
      ctx.log("INFO", string.format(
        "Discovery %s %s type=%s (%s): %s",
        tostring(decision.kind),
        tostring(decision.name),
        tostring(decision.type_name or "n/a"),
        tostring(action),
        tostring(decision.reason or "n/a")
      ))
    end
    ctx.log("INFO", string.format(
      "Discovery summary visible reactors=%d turbines=%d | bound reactors=%d turbines=%d",
      visible_counts.reactor,
      visible_counts.turbine,
      bound_counts.reactor,
      bound_counts.turbine
    ))
  else
    ctx.log("DEBUG", string.format(
      "Discovery unchanged visible reactors=%d turbines=%d | bound reactors=%d turbines=%d",
      visible_counts.reactor,
      visible_counts.turbine,
      bound_counts.reactor,
      bound_counts.turbine
    ))
  end

  ctx.registry:sync(registry_devices)
  ctx.devices.adapters = adapter_map
  ctx.devices.registry_summary = ctx.registry:get_summary()
  ctx.devices.registry_load_error = ctx.registry.state.load_error
  ctx.devices.last_scan_ts = os.epoch("utc")
  M.refresh_bindings(ctx)
  return registry_devices
end

return M
