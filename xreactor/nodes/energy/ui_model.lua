local M = {}

local function build_matrix_signature(matrices)
  local parts = {}
  for _, entry in ipairs(matrices or {}) do
    table.insert(parts, table.concat({
      tostring(entry.name or ""),
      tostring(entry.percent or 0),
      tostring(entry.stored or 0),
      tostring(entry.capacity or 0),
      tostring(entry.input or 0),
      tostring(entry.output or 0),
      tostring(entry.status or "")
    }, ":"))
  end
  return table.concat(parts, "|")
end

local function build_storage_signature(storages)
  local parts = {}
  for _, entry in ipairs(storages or {}) do
    table.insert(parts, table.concat({
      tostring(entry.id or ""),
      tostring(entry.stored or 0),
      tostring(entry.capacity or 0)
    }, ":"))
  end
  return table.concat(parts, "|")
end

function M.new(opts)
  opts = opts or {}
  local runtime = {
    now_ms = assert(opts.now_ms, "now_ms required"),
    config = assert(opts.config, "config required"),
    utils = assert(opts.utils, "utils required"),
    health = assert(opts.health, "health required"),
    registry = assert(opts.registry, "registry required"),
    comms = opts.comms,
    devices = assert(opts.devices, "devices required"),
    master_peer_state = assert(opts.master_peer_state, "master_peer_state required"),
    master_alerts = opts.master_alerts or function() return nil end,
    build_status_payload = assert(opts.build_status_payload, "build_status_payload required"),
    ui_model_cache = opts.ui_model_cache or { ts = 0, model = nil, key = nil }
  }

  local function build_ui_model(model_opts)
    model_opts = model_opts or {}
    local default_max_age_ms = math.max(1000, math.floor((tonumber(runtime.config.status_interval) or 5) * 1000))
    local max_age_ms = tonumber(model_opts.max_age_ms) or default_max_age_ms
    local ts = runtime.now_ms()
    local cache_age = ts - (runtime.ui_model_cache.ts or 0)
    if runtime.ui_model_cache.model and cache_age >= 0 and cache_age <= max_age_ms then
      return runtime.ui_model_cache.model
    end

    local payload = runtime.build_status_payload({ reason = "ui_model", max_age_ms = max_age_ms })
    local degraded = payload.health and payload.health.status == runtime.health.status.DEGRADED
    local reasons_text = payload.health and table.concat(payload.health.reasons or {}, ",") or ""
    local matrices = runtime.utils.deep_copy(payload.matrices or {})
    local storages = runtime.utils.deep_copy(payload.stores or {})
    local registry_entries = payload.registry and payload.registry.devices or runtime.registry:list()
    local registry_summary = payload.registry and payload.registry.summary or runtime.registry:get_summary()

    local registry_rows = {}
    for _, entry in ipairs(registry_entries) do
      local state = entry.missing and "MISSING" or (entry.bound and "BOUND" or "FOUND")
      table.insert(registry_rows, {
        text = string.format("%s %s", entry.alias or entry.id, state),
        status = entry.missing and "WARNING" or "OK"
      })
    end

    local comms_diag = runtime.comms and runtime.comms:get_diagnostics() or {}
    local metrics = comms_diag.metrics or {}
    local master_peer = runtime.master_peer_state()
    local node_id = runtime.comms and runtime.comms.network and runtime.comms.network.id or runtime.config.node_id
    local alerts = runtime.master_alerts()
    local alert_payload = alerts and alerts.by_node and alerts.by_node[node_id] or nil

    local model = {
      node_id = node_id,
      degraded = degraded,
      health_status = payload.health and payload.health.status or runtime.health.status.OK,
      degraded_reason = reasons_text ~= "" and reasons_text or nil,
      last_scan_ts = runtime.devices.last_scan_ts,
      scan_result = runtime.devices.last_scan_result,
      last_error = runtime.devices.last_error,
      last_error_ts = runtime.devices.last_error_ts,
      last_command = runtime.devices.last_command,
      last_command_ts = runtime.devices.last_command_ts,
      peripheral_count = runtime.devices.peripheral_count,
      monitor_bound = runtime.devices.monitor ~= nil,
      storages_count = registry_summary.kinds.storage and registry_summary.kinds.storage.bound or 0,
      storages = storages,
      matrices = matrices,
      total = payload.total,
      registry_rows = registry_rows,
      registry_summary = registry_summary,
      comms = comms_diag,
      metrics = metrics,
      master_state = master_peer and (master_peer.down and "DOWN" or "OK") or "UNKNOWN",
      master_age = master_peer and master_peer.age and string.format("%ds", math.floor(master_peer.age)) or "n/a",
      local_alerts = alert_payload and alert_payload.top or {},
      local_alerts_critical = alert_payload and alert_payload.critical or 0
    }

    runtime.ui_model_cache.ts = ts
    runtime.ui_model_cache.model = model
    return model
  end

  local function build_snapshot_key(model)
    return runtime.utils.safe_serialize({
      health = model.health_status,
      degraded = model.degraded,
      reason = model.degraded_reason,
      scan = model.last_scan_ts,
      scan_result = model.scan_result,
      err = model.last_error,
      err_ts = model.last_error_ts,
      cmd = model.last_command,
      cmd_ts = model.last_command_ts,
      matrices = build_matrix_signature(model.matrices),
      storages = build_storage_signature(model.storages),
      total = model.total,
      registry = model.registry_summary,
      comms = model.comms and model.comms.metrics,
      master_state = model.master_state,
      master_age = model.master_age,
      local_alerts = model.local_alerts_critical
    }) or tostring(model)
  end

  local function get_ui_snapshot_key(snapshot_opts)
    local model = build_ui_model(snapshot_opts)
    local key = build_snapshot_key(model)
    runtime.ui_model_cache.key = key
    return key
  end

  return {
    build_ui_model = build_ui_model,
    build_snapshot_key = build_snapshot_key,
    get_ui_snapshot_key = get_ui_snapshot_key
  }
end

return M
