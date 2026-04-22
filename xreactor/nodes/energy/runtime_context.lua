local M = {}

local function now_ms()
  return os.epoch("utc")
end

function M.new(opts)
  opts = opts or {}
  local config = assert(opts.config, "config required")
  local role = opts.role or config.role or "energy"
  return {
    now_ms = now_ms,
    devices = {
      storages = {},
      matrices = {},
      matrix_groups = {},
      monitor = nil,
      monitor_name = nil,
      bound_storage_names = {},
      last_scan_ts = nil,
      last_scan_result = nil,
      peripheral_count = 0,
      last_error = nil,
      last_error_ts = nil,
      discovery_failed = false,
      adapters = {
        storages = {},
        matrices = {}
      },
      registry_snapshot = nil,
      registry_summary = nil,
      registry_load_error = nil,
      discovery_signature = nil,
      proto_mismatch = false,
      last_command = nil,
      last_command_ts = nil,
      matrix_identity_cache = {},
      topology_signature = nil
    },
    ui_state = {
      matrix_page = 1,
      storage_page = 1,
      router = nil,
      model = nil
    },
    status_payload_cache = { ts = 0, payload = nil },
    ui_model_cache = { ts = 0, model = nil, key = nil },
    storage_snapshot = {
      ts = 0,
      stale = true,
      stores = {},
      total = { stored = 0, capacity = 0, input = 0, output = 0 }
    },
    warned = {},
    last_heartbeat = 0,
    last_heartbeat_warn = 0,
    master_seen_ts = nil,
    master_alerts = {},
    role = role
  }
end

function M.warn_once(runtime, log_fn, key, message)
  if runtime.warned[key] then return end
  runtime.warned[key] = true
  log_fn(message, "WARN")
end

function M.heartbeat_interval_ms(config)
  return math.max(1, tonumber(config.heartbeat_interval) or 2) * 1000
end

function M.make_presence(config, comms, ts_ms)
  return {
    ts = ts_ms,
    node_id = comms and comms.network and comms.network.id or config.node_id,
    role = config.role
  }
end

return M
