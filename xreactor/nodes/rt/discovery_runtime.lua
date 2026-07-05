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

local function method_sample_for(name, limit)
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    return "methods unavailable"
  end
  table.sort(methods)
  local out = {}
  local max_methods = math.min(#methods, limit or 10)
  for i = 1, max_methods do
    out[#out + 1] = tostring(methods[i])
  end
  if #methods > max_methods then
    out[#out + 1] = "...+" .. tostring(#methods - max_methods)
  end
  if #out == 0 then
    return "no methods"
  end
  return table.concat(out, ",")
end

local function zero_visible_diagnostic_signature(names)
  local parts = {}
  for _, name in ipairs(names or {}) do
    local ok_type, type_name = pcall(peripheral.getType, name)
    parts[#parts + 1] = table.concat({
      tostring(name),
      ok_type and tostring(type_name or "n/a") or "type unavailable",
      method_sample_for(name, 10)
    }, "|")
  end
  table.sort(parts)
  return table.concat(parts, "\n")
end

local function log_zero_visible_diagnostics(ctx, names)
  ctx.log("WARN", string.format(
    "RT discovery found zero reactor/turbine peripherals; peripheral_count=%d config_path=/xreactor/config/rt.lua",
    #(names or {})
  ))
  ctx.log("WARN", "RT discovery note: empty reactors/turbines lists mean auto-discovery; zero visible means no supported peripheral signature was detected")
  if #(names or {}) == 0 then
    ctx.log("WARN", "RT discovery: peripheral.getNames() returned no peripherals for this computer")
    return
  end
  local max_lines = math.min(#names, 16)
  for i = 1, max_lines do
    local name = names[i]
    local ok_type, type_name = pcall(peripheral.getType, name)
    ctx.log("INFO", string.format(
      "RT discovery peripheral name=%s type=%s methods=%s",
      tostring(name),
      ok_type and tostring(type_name or "n/a") or "type unavailable",
      method_sample_for(name, 10)
    ))
  end
  if #names > max_lines then
    ctx.log("INFO", "RT discovery peripheral list truncated; remaining=" .. tostring(#names - max_lines))
  end
end

function M.refresh_bindings(ctx)
  local reactors = ctx.registry:get_bound_devices("reactor")
  local turbines = ctx.registry:get_bound_devices("turbine")
  local signature = M.build_binding_signature(reactors, turbines)
  -- Fix (2026-07-06): CRITICAL. ctx.devices.reactors/turbines wurden bisher
  -- NUR gesetzt, wenn sich die binding_signature seit dem letzten Aufruf
  -- geaendert hat — bei unveraenderter Signatur (der Normalfall bei jedem
  -- Tick, da sich die Bindung ja selten aendert) lief ein sofortiges
  -- return VOR der Zuweisung. Sollte devices.reactors/turbines aus
  -- irgendeinem Grund (Race-Condition beim allerersten Boot-Discover,
  -- oder schlicht weil binding_signature initial schon zufaellig
  -- uebereinstimmte) einmal leer geblieben sein, blieb es das FUER IMMER,
  -- da jeder folgende Aufruf denselben Skip nahm — beobachtet im Log als
  -- "Discovery unchanged ... bound reactors=1 turbines=25" GEFOLGT von
  -- "Re-Discovery: reactors=0 turbines=0" (das eigene Log direkt danach,
  -- das den tatsaechlichen, leeren Zustand von ctx.devices zeigte).
  -- Jetzt: reactors/turbines werden IMMER zugewiesen, der Signatur-
  -- Vergleich entscheidet nur noch ob die teuren Nebenoperationen
  -- (Cache-Schreiben, Modul-Neuaufbau) noetig sind.
  ctx.devices.reactors = reactors
  ctx.devices.turbines = turbines
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
  local zero_visible = visible_counts.reactor == 0 and visible_counts.turbine == 0
  local zero_diag_signature = zero_visible and zero_visible_diagnostic_signature(names) or nil
  local log_zero_diag = zero_visible and ctx.devices.zero_visible_diag_signature ~= zero_diag_signature
  if zero_visible then
    ctx.devices.zero_visible_diag_signature = zero_diag_signature
  else
    ctx.devices.zero_visible_diag_signature = nil
  end

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

  if log_zero_diag then
    log_zero_visible_diagnostics(ctx, names)
  end

  ctx.registry:sync(registry_devices)
  ctx.devices.adapters = adapter_map
  ctx.devices.registry_summary = ctx.registry:get_summary()
  ctx.devices.registry_load_error = ctx.registry.state.load_error
  ctx.devices.last_scan_ts = os.epoch("utc")
  M.refresh_bindings(ctx)
  return registry_devices
end

function M.build_modules(devices)
  local modules = {}
  for _, entry in ipairs(devices.turbines or {}) do
    local id = entry.id or ("turbine:" .. tostring(entry.name))
    modules[id] = {
      id = id,
      type = "turbine",
      state = "OFF",
      progress = 0,
      limits = {},
      name = entry.name,
      alias = entry.alias,
      stable_since = nil
    }
  end
  for _, entry in ipairs(devices.reactors or {}) do
    local id = entry.id or ("reactor:" .. tostring(entry.name))
    modules[id] = {
      id = id,
      type = "reactor",
      state = "OFF",
      progress = 0,
      limits = {},
      name = entry.name,
      alias = entry.alias,
      stable_since = nil,
      autonom_control_rod = nil
    }
  end
  return modules
end

function M.refresh_module_peripherals(modules, peripherals, get_device_caps)
  local turbines = peripherals.turbines or {}
  local reactors = peripherals.reactors or {}
  for _, module in pairs(modules or {}) do
    if module.type == "turbine" then
      module.peripheral = turbines[module.name]
      module.caps = module.peripheral and get_device_caps("turbines", module.name) or nil
    else
      module.peripheral = reactors[module.name]
      module.caps = module.peripheral and get_device_caps("reactors", module.name) or nil
    end
  end
end

return M