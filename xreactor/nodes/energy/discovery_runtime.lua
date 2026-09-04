local M = {}

local function to_set(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[value] = true
  end
  return out
end

function M.new(opts)
  opts = opts or {}
  local runtime = {
    config = assert(opts.config, "config required"),
    debug_enabled = opts.debug_enabled == true,
    utils = assert(opts.utils, "utils required"),
    peripheral = assert(opts.peripheral, "peripheral required"),
    monitor_adapter = assert(opts.monitor_adapter, "monitor_adapter required"),
    matrix_adapter = assert(opts.matrix_adapter, "matrix_adapter required"),
    storage_adapter = assert(opts.storage_adapter, "storage_adapter required"),
    discovery_log = assert(opts.discovery_log, "discovery_log required"),
    registry = assert(opts.registry, "registry required"),
    devices = assert(opts.devices, "devices required"),
    topology_cache = opts.topology_cache,
    matrix_runtime = opts.matrix_runtime,
    record_error = opts.record_error,
    log = assert(opts.log, "log required"),
    on_topology_changed = opts.on_topology_changed
  }

  local function is_matrix_override(name)
    if runtime.config.matrix and name == runtime.config.matrix then
      return true
    end
    for _, entry in ipairs(runtime.config.matrix_names or {}) do
      if entry == name then
        return true
      end
    end
    return false
  end

  local function is_blocked_type(name)
    local type_name = runtime.peripheral.getType(name)
    if not type_name then
      return false
    end
    type_name = tostring(type_name):lower()
    return type_name == "monitor" or type_name == "modem" or type_name == "peripheral_hub"
  end

  local function pick_monitor()
    local preferred = runtime.config.monitor and runtime.config.monitor.preferred_name or nil
    local strategy = runtime.config.monitor and runtime.config.monitor.strategy or "largest"
    return runtime.monitor_adapter.find(preferred, strategy, runtime.config.ui_scale, "ENERGY")
  end

  local function matrix_group_signature(groups)
    local rows = {}
    for _, group in ipairs(groups or {}) do
      local ports = {}
      for _, port in ipairs(group.ports or {}) do
        ports[#ports + 1] = tostring(port.name)
      end
      table.sort(ports)
      rows[#rows + 1] = table.concat({
        tostring(group.key),
        tostring(group.representative and group.representative.name or "n/a"),
        table.concat(ports, ",")
      }, "|")
    end
    table.sort(rows)
    return table.concat(rows, ";")
  end

  local function reconcile_matrix_groups(previous_groups, next_groups)
    local previous_by_key = {}
    for _, group in ipairs(previous_groups or {}) do
      previous_by_key[tostring(group.key)] = group
    end
    local stable = {}
    for _, next_group in ipairs(next_groups or {}) do
      local key = tostring(next_group.key)
      local existing = previous_by_key[key]
      if existing then
        existing.key_source = next_group.key_source
        local ports_by_name = {}
        for _, port in ipairs(existing.ports or {}) do
          ports_by_name[tostring(port.name)] = port
        end
        local rebuilt_ports = {}
        local representative
        for _, next_port in ipairs(next_group.ports or {}) do
          local port = ports_by_name[tostring(next_port.name)] or {}
          port.id = next_port.id
          port.alias = next_port.alias
          port.name = next_port.name
          port.adapter = next_port.adapter
          rebuilt_ports[#rebuilt_ports + 1] = port
          if next_group.representative and next_group.representative.name == port.name then
            representative = port
          end
        end
        existing.ports = rebuilt_ports
        existing.representative = representative or rebuilt_ports[1] or nil
        stable[#stable + 1] = existing
      else
        stable[#stable + 1] = next_group
      end
    end
    return stable
  end

  local function log_discovery_snapshot(names, candidates, monitor_name, matrices)
    if not runtime.debug_enabled then
      return
    end
    runtime.log("Discovery snapshot: names=" .. textutils.serialize(names))
    for _, name in ipairs(names) do
      runtime.log(("Discovery peripheral: %s type=%s"):format(tostring(name), tostring(runtime.peripheral.getType(name))))
    end
    for _, candidate in ipairs(candidates) do
      local method_list = candidate.adapter and candidate.adapter.getMethodList and candidate.adapter.getMethodList() or candidate.method_list or {}
      local kind = candidate.kind or "unknown"
      runtime.log(("Discovery candidate: %s kind=%s methods=%s"):format(tostring(candidate.name), tostring(kind), textutils.serialize(method_list)))
    end
    if monitor_name then
      runtime.log(("Discovery monitor selection: %s"):format(tostring(monitor_name)))
    end
    for _, matrix in ipairs(matrices or {}) do
      local method_list = matrix.adapter and matrix.adapter.getMethodList and matrix.adapter.getMethodList() or matrix.method_list or {}
      runtime.log(("Discovery matrix: %s methods=%s"):format(tostring(matrix.name), textutils.serialize(method_list)))
    end
  end

  local function discover()
    local names = runtime.peripheral.getNames() or {}
    runtime.devices.peripheral_count = #names
    local include_set = runtime.config.storage_filters and runtime.config.storage_filters.include_names and to_set(runtime.config.storage_filters.include_names) or nil
    local exclude_set = to_set(runtime.config.storage_filters and runtime.config.storage_filters.exclude_names or {})
    local prefer_names = {}
    for _, name in ipairs(runtime.config.storage_filters and runtime.config.storage_filters.prefer_names or {}) do
      prefer_names[#prefer_names + 1] = name
    end
    if runtime.config.matrix then
      prefer_names[#prefer_names + 1] = runtime.config.matrix
    end
    for _, name in ipairs(runtime.config.cubes or {}) do
      prefer_names[#prefer_names + 1] = name
    end

    local monitor_entry = pick_monitor()
    local monitor_name = monitor_entry and monitor_entry.name or nil
    local monitor = monitor_entry and monitor_entry.mon or nil
    if monitor_name and monitor_name ~= runtime.devices.monitor_name then
      runtime.log("Monitor selected: " .. tostring(monitor_name))
    end
    if not monitor_name and type(runtime.record_error) == "function" then
      runtime.record_error("monitor", "not found")
    end

    local candidates, registry_devices, seen = {}, {}, {}
    local adapter_map = { matrices = {}, storages = {} }
    local previous_adapters = runtime.devices.adapters or { matrices = {}, storages = {} }
    local next_matrix_identity_cache = {}

    for _, name in ipairs(names) do
      if runtime.peripheral.getType(name) == "monitor" then
        registry_devices[#registry_devices + 1] = {
          name = name,
          type = "monitor",
          methods = runtime.utils.safe_get_methods(name) or {},
          kind = "monitor",
          bound = monitor_name == name
        }
      end
    end

    local function consider_name(name)
      if seen[name] then return end
      seen[name] = true
      if exclude_set[name] or is_blocked_type(name) then return end
      local forced_matrix = is_matrix_override(name)
      if include_set and not include_set[name] and not forced_matrix then return end

      local existing_matrix = previous_adapters.matrices and previous_adapters.matrices[name] or nil
      local matrix = existing_matrix and existing_matrix.isValid and existing_matrix.isValid() and existing_matrix or nil
      if not matrix then
        local cached_identity = runtime.devices.matrix_identity_cache and runtime.devices.matrix_identity_cache[name] or nil
        matrix = runtime.matrix_adapter.detect(name, "ENERGY", {
          group_key = cached_identity and cached_identity.group_key or nil,
          group_key_source = cached_identity and cached_identity.group_key_source or nil
        })
      end
      if matrix then
        candidates[#candidates + 1] = { name = name, adapter = matrix, kind = "matrix" }
        adapter_map.matrices[name] = matrix
        next_matrix_identity_cache[name] = { group_key = matrix.group_key, group_key_source = matrix.group_key_source }
        registry_devices[#registry_devices + 1] = {
          name = name,
          type = matrix.getType(),
          methods = matrix.getMethodList and matrix.getMethodList() or {},
          kind = "matrix",
          alias = runtime.config.matrix_aliases and runtime.config.matrix_aliases[name] or nil,
          bound = true,
          features = matrix.features,
          schema = matrix.schema
        }
        return
      end
      if forced_matrix then
        if type(runtime.record_error) == "function" then
          runtime.record_error(name, "matrix override set but methods missing")
        end
        return
      end

      local storage = previous_adapters.storages and previous_adapters.storages[name] or nil
      if not (storage and storage.isValid and storage.isValid()) then
        storage = runtime.storage_adapter.detect(name, "ENERGY")
      end
      if storage then
        candidates[#candidates + 1] = { name = name, adapter = storage, kind = "storage" }
        adapter_map.storages[name] = storage
        registry_devices[#registry_devices + 1] = {
          name = name,
          type = storage.getType(),
          methods = storage.getMethodList and storage.getMethodList() or {},
          kind = "storage",
          bound = true,
          features = storage.features,
          schema = storage.schema
        }
      end
    end

    for _, name in ipairs(names) do consider_name(name) end
    for _, name in ipairs(prefer_names) do
      if runtime.peripheral.isPresent(name) then consider_name(name) end
    end

    runtime.registry:sync(registry_devices)
    local order_index = runtime.registry:get_order_index()
    local prefer_rank = {}
    for idx, name in ipairs(prefer_names) do prefer_rank[name] = idx end

    local function sort_by_order(a, b)
      local order_a = order_index[a.entry.id] or math.huge
      local order_b = order_index[b.entry.id] or math.huge
      if order_a ~= order_b then return order_a < order_b end
      return tostring(a.adapter.name) < tostring(b.adapter.name)
    end

    local storage_entries = {}
    for _, entry in ipairs(runtime.registry:get_bound_devices("storage")) do
      local adapter = adapter_map.storages[entry.name]
      if adapter then storage_entries[#storage_entries + 1] = { adapter = adapter, entry = entry } end
    end
    table.sort(storage_entries, function(a, b)
      local rank_a = prefer_rank[a.adapter.name] or math.huge
      local rank_b = prefer_rank[b.adapter.name] or math.huge
      if rank_a ~= rank_b then return rank_a < rank_b end
      return sort_by_order(a, b)
    end)

    local matrix_entries = {}
    for _, entry in ipairs(runtime.registry:get_bound_devices("matrix")) do
      local adapter = adapter_map.matrices[entry.name]
      if adapter then matrix_entries[#matrix_entries + 1] = { adapter = adapter, entry = entry } end
    end
    table.sort(matrix_entries, sort_by_order)

    local storages, bound_names = {}, {}
    local selected_storage = storage_entries[1]
    if selected_storage then
      storages[1] = {
        id = selected_storage.entry.id,
        alias = selected_storage.entry.alias,
        name = selected_storage.adapter.name,
        adapter = selected_storage.adapter
      }
      bound_names[1] = selected_storage.entry.alias or selected_storage.entry.id
      if #storage_entries > 1 then
        runtime.log(("Storage discovery: %d candidates found, using %s only (single-storage model)"):format(#storage_entries, tostring(selected_storage.adapter.name)))
      end
    end

    local matrices = {}
    local selected_matrix = matrix_entries[1]
    if selected_matrix then
      matrices[1] = {
        id = selected_matrix.entry.id,
        alias = selected_matrix.entry.alias,
        name = selected_matrix.adapter.name,
        adapter = selected_matrix.adapter
      }
      if #matrix_entries > 1 then
        runtime.log(("Matrix discovery: %d candidates found, using %s only (single-matrix model)"):format(#matrix_entries, tostring(selected_matrix.adapter.name)))
      end
    end

    local matrix_groups = runtime.matrix_adapter.group_ports(matrices)
    local next_topology_signature = matrix_group_signature(matrix_groups)
    local topology_changed = next_topology_signature ~= (runtime.devices.topology_signature or "")
    if not topology_changed then
      matrix_groups = reconcile_matrix_groups(runtime.devices.matrix_groups or {}, matrix_groups)
    end

    local bound_lookup = {}
    for _, storage in ipairs(storages) do bound_lookup[storage.name] = true end
    for _, matrix in ipairs(matrices) do bound_lookup[matrix.name] = true end
    for _, entry in ipairs(registry_devices) do entry.bound = bound_lookup[entry.name] or false end

    if monitor_name and monitor_name == runtime.devices.monitor_name and runtime.devices.monitor then
      monitor = runtime.devices.monitor
    end

    runtime.devices.monitor = monitor
    runtime.devices.monitor_name = monitor_name
    -- Fallback: render to the computer's own terminal if no Monitor peripheral
    -- is attached, so Diagnostics (incl. log mode buttons) is visible on the PC.
    if not runtime.devices.monitor and term and type(term.current) == "function" then
      runtime.devices.monitor = term.current()
      runtime.devices.monitor_name = runtime.devices.monitor_name or "term"
      runtime.devices.monitor_is_term = true
    end
    runtime.devices.storages = storages
    runtime.devices.matrices = matrices
    runtime.devices.matrix_groups = matrix_groups
    runtime.devices.bound_storage_names = bound_names
    runtime.devices.adapters = adapter_map
    runtime.devices.registry_snapshot = runtime.registry:get_devices_by_kind()
    runtime.devices.registry_summary = runtime.registry:get_summary()
    runtime.devices.registry_load_error = runtime.registry.state.load_error
    runtime.devices.last_scan_ts = os.epoch("utc")
    runtime.devices.last_scan_result = ("monitor=%s storages=%d matrices=%d"):format(monitor_name or "none", #storages, #matrices)
    runtime.devices.matrix_identity_cache = next_matrix_identity_cache
    runtime.devices.topology_signature = next_topology_signature

    if runtime.topology_cache then
      runtime.topology_cache:record_discovery(runtime.devices.last_scan_ts, next_topology_signature)
    end
    if runtime.matrix_runtime and topology_changed then
      runtime.matrix_runtime:invalidate()
    end
    if topology_changed and type(runtime.on_topology_changed) == "function" then
      runtime.on_topology_changed()
    end

    local peripheral_types = {}
    for _, name in ipairs(names) do
      peripheral_types[name] = runtime.peripheral.getType(name)
    end
    local candidate_snapshot, matrix_snapshot = {}, {}
    for _, candidate in ipairs(candidates) do
      candidate_snapshot[#candidate_snapshot + 1] = {
        name = candidate.name,
        kind = candidate.kind,
        methods = candidate.adapter and candidate.adapter.getMethodList and candidate.adapter.getMethodList() or candidate.method_list or {}
      }
    end
    for _, matrix in ipairs(matrices or {}) do
      matrix_snapshot[#matrix_snapshot + 1] = {
        name = matrix.name,
        methods = matrix.adapter and matrix.adapter.getMethodList and matrix.adapter.getMethodList() or matrix.method_list or {}
      }
    end
    local matrix_group_snapshot = {}
    for _, group in ipairs(matrix_groups or {}) do
      local group_ports = {}
      for _, port in ipairs(group.ports or {}) do group_ports[#group_ports + 1] = port.name end
      matrix_group_snapshot[#matrix_group_snapshot + 1] = { key = group.key, reader = group.representative and group.representative.name or nil, ports = group_ports }
    end

    local signature = runtime.discovery_log.build_signature({
      names = names,
      peripheral_types = peripheral_types,
      candidates = candidate_snapshot,
      monitor_name = monitor_name,
      matrices = matrix_snapshot,
      matrix_groups = matrix_group_snapshot,
      registry_summary = runtime.devices.registry_summary
    })

    if runtime.debug_enabled and topology_changed and #matrix_groups > 0 then
      for _, group in ipairs(matrix_groups) do
        local port_names = {}
        for _, port in ipairs(group.ports or {}) do port_names[#port_names + 1] = tostring(port.name) end
        runtime.log(("Matrix group %s source=%s via %s ports=%s"):format(
          tostring(group.key), tostring(group.key_source or "n/a"), tostring(group.representative and group.representative.name or "n/a"), table.concat(port_names, ",")
        ))
      end
    end
    if runtime.discovery_log.should_log_details(runtime.devices.discovery_signature, signature, runtime.devices.discovery_failed) then
      log_discovery_snapshot(names, candidates, monitor_name, matrices)
    end
    runtime.devices.discovery_signature = signature

    return registry_devices
  end

  return {
    discover = discover
  }
end

return M
