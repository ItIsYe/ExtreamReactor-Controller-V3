local M = {}

function M.new(opts)
  opts = opts or {}
  local runtime = {
    now_ms = assert(opts.now_ms, "now_ms required"),
    config = assert(opts.config, "config required"),
    utils = assert(opts.utils, "utils required"),
    health = assert(opts.health, "health required"),
    registry = assert(opts.registry, "registry required"),
    devices = assert(opts.devices, "devices required"),
    energy_health = assert(opts.energy_health, "energy_health required"),
    read_storage_stats = assert(opts.read_storage_stats, "read_storage_stats required"),
    read_matrix_stats = assert(opts.read_matrix_stats, "read_matrix_stats required"),
    is_master_connected = assert(opts.is_master_connected, "is_master_connected required"),
    status_payload_cache = opts.status_payload_cache or { ts = 0, payload = nil },
    log = assert(opts.log, "log required")
  }

  local function build_status_payload_uncached(payload_opts)
    payload_opts = payload_opts or {}
    local started_at = runtime.now_ms()
    local energy_started_at = started_at
    local energy = runtime.read_storage_stats(payload_opts)
    local energy_duration = runtime.now_ms() - energy_started_at
    local matrix_started_at = runtime.now_ms()
    local matrix = runtime.read_matrix_stats(payload_opts)
    local matrix_duration = runtime.now_ms() - matrix_started_at
    local total_stored = energy.stored + (matrix.total.stored or 0)
    local total_capacity = energy.capacity + (matrix.total.capacity or 0)
    local total_input = energy.input + (matrix.total.input or 0)
    local total_output = energy.output + (matrix.total.output or 0)
    local registry_summary = runtime.devices.registry_summary or runtime.registry:get_summary()
    local effective_matrix_count = #(runtime.devices.matrix_groups or {})
    local effective_storage_count = #(runtime.devices.storages or {})
    energy.monitor_bound = runtime.devices.monitor ~= nil
    energy.storage_bound_count = effective_storage_count
    energy.bound_storage_names = runtime.devices.bound_storage_names or {}
    energy.matrices = matrix.matrices
    energy.total = matrix.total
    energy.matrix_snapshot_freshness_ms = matrix.freshness_ms
    energy.matrix_snapshot_stale = matrix.stale == true
    energy.matrix_present = effective_matrix_count > 0
    energy.matrix_energy = matrix.total.stored
    energy.matrix_capacity = matrix.total.capacity
    energy.matrix_percent = matrix.total.percent
    energy.matrix_in = matrix.total.input
    energy.matrix_out = matrix.total.output
    energy.storages_count = effective_storage_count
    energy.storage_snapshot_freshness_ms = energy.freshness_ms
    energy.storage_snapshot_stale = energy.stale == true
    energy.aggregate_stored = total_stored
    energy.aggregate_capacity = total_capacity
    energy.aggregate_input = total_input
    energy.aggregate_output = total_output
    energy.storage_stored = energy.stored
    energy.storage_capacity = energy.capacity
    energy.storage_input = energy.input
    energy.storage_output = energy.output
    -- Backward compatibility: stored/capacity/input/output remain aggregate totals.
    energy.stored = total_stored
    energy.capacity = total_capacity
    energy.input = total_input
    energy.output = total_output
    local summary = {}
    table.sort(energy.stores, function(a, b) return (a.capacity or 0) > (b.capacity or 0) end)
    for i = 1, math.min(3, #energy.stores) do
      local s = energy.stores[i]
      local pct = s.capacity and s.capacity > 0 and (s.stored / s.capacity) or 0
      table.insert(summary, { name = s.id, percent = pct })
    end
    energy.storages_summary = summary
    energy.last_scan_ts = runtime.devices.last_scan_ts
    energy.last_scan_result = runtime.devices.last_scan_result
    energy.last_error = runtime.devices.last_error
    energy.last_error_ts = runtime.devices.last_error_ts
    energy.peripheral_count = runtime.devices.peripheral_count

    local reasons = {}
    local degrade_reasons = {}
    if not energy.monitor_bound then reasons[runtime.health.reasons.NO_MONITOR] = true end
    if effective_storage_count == 0 then reasons[runtime.health.reasons.NO_STORAGE] = true end
    if effective_matrix_count == 0 then
      reasons[runtime.health.reasons.NO_MATRIX] = true
      degrade_reasons[runtime.health.reasons.NO_MATRIX] = true
    end
    if runtime.devices.discovery_failed or runtime.devices.registry_load_error then
      reasons[runtime.health.reasons.DISCOVERY_FAILED] = true
      degrade_reasons[runtime.health.reasons.DISCOVERY_FAILED] = true
    end
    if runtime.devices.proto_mismatch then
      reasons[runtime.health.reasons.PROTO_MISMATCH] = true
      degrade_reasons[runtime.health.reasons.PROTO_MISMATCH] = true
    end
    if not runtime.is_master_connected() then
      reasons[runtime.health.reasons.COMMS_DOWN] = true
      degrade_reasons[runtime.health.reasons.COMMS_DOWN] = true
    end

    runtime.energy_health.status = (next(degrade_reasons) and runtime.health.status.DEGRADED) or runtime.health.status.OK
    runtime.energy_health.reasons = reasons
    runtime.energy_health.last_seen_ts = os.epoch("utc")
    runtime.energy_health.bindings = {
      storages = effective_storage_count,
      matrices = effective_matrix_count,
      monitor = energy.monitor_bound and 1 or 0
    }
    runtime.energy_health.capabilities = {
      storage_count = effective_storage_count,
      matrix_count = effective_matrix_count,
      monitor = energy.monitor_bound
    }
    energy.health = {
      status = runtime.energy_health.status,
      reasons = runtime.health.reasons_list(runtime.energy_health),
      last_seen_ts = runtime.energy_health.last_seen_ts,
      bindings = runtime.energy_health.bindings,
      capabilities = runtime.energy_health.capabilities
    }
    energy.bindings_summary = runtime.health.summarize_bindings(runtime.energy_health.bindings)
    energy.registry = {
      summary = registry_summary,
      devices = runtime.registry:get_devices_by_kind(),
      diagnostics = runtime.registry:get_diagnostics()
    }

    local total_duration = runtime.now_ms() - started_at
    local matrix_mode = (effective_matrix_count > 0 and effective_storage_count > 0 and "mixed") or (effective_matrix_count > 0 and "matrix_only") or (effective_storage_count > 0 and "storage_only") or "empty"
    if runtime.last_matrix_mode ~= matrix_mode then
      runtime.log(("Energy payload mode %s -> %s (matrix=%d storage=%d aggregate=%.0f/%.0f)"):format(tostring(runtime.last_matrix_mode or "unknown"), matrix_mode, effective_matrix_count, effective_storage_count, total_stored, total_capacity))
      runtime.last_matrix_mode = matrix_mode
    end

    if total_duration > 1200 then
      runtime.log(("Status payload slow: total=%dms storage=%dms matrix=%dms storages=%d matrices=%d"):format(
        total_duration,
        energy_duration,
        matrix_duration,
        #(runtime.devices.storages or {}),
        #(runtime.devices.matrices or {})
      ), "WARN")
    end

    return energy
  end

  local function build_status_payload(payload_opts)
    payload_opts = payload_opts or {}
    local max_age_ms = tonumber(payload_opts.max_age_ms) or 0
    local ts = runtime.now_ms()
    local cache_age = ts - (runtime.status_payload_cache.ts or 0)
    if runtime.status_payload_cache.payload and cache_age >= 0 and cache_age <= max_age_ms then
      return runtime.status_payload_cache.payload
    end
    local payload = build_status_payload_uncached(payload_opts)
    runtime.status_payload_cache.ts = runtime.now_ms()
    runtime.status_payload_cache.payload = payload
    return payload
  end

  return {
    build_status_payload = build_status_payload,
    build_status_payload_uncached = build_status_payload_uncached
  }
end

return M
