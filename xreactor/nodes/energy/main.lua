-- CONFIG
local CONFIG = {
  LOG_NAME = "energy", -- Log file name for this node.
  LOG_PREFIX = "ENERGY", -- Default log prefix for energy events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_energy.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  CONFIG_PATH = "/xreactor/nodes/energy/config.lua", -- Config file path.
  RECEIVE_TIMEOUT = 0.5 -- Network receive timeout (seconds).
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "energy",
  log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED,
  log_path = CONFIG.BOOTSTRAP_LOG_PATH
})
local require = bootstrap.require
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local health = require("core.health")
local ui = require("core.ui")
local ui_router = require("core.ui_router")
local colors = require("shared.colors")
local registry_lib = require("core.registry")
local storage_adapter = require("adapters.energy_storage")
local matrix_adapter = require("adapters.induction_matrix")
local monitor_adapter = require("adapters.monitor")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local discovery_service = require("services.discovery_service")
local telemetry_service = require("services.telemetry_service")
local ui_service = require("services.ui_service")
local control_service = require("services.control_service")
local matrix_sampling_service = require("services.matrix_sampling_service")
local discovery_log = require("nodes.energy.discovery_log")
local matrix_snapshot_runtime = require("nodes.energy.matrix_snapshot_runtime")
local matrix_topology_cache = require("nodes.energy.matrix_topology_cache")
local config_normalizer = require("nodes.energy.config_normalizer")
local command_handler = require("nodes.energy.command_handler")
local status_payload_runtime = require("nodes.energy.status_payload")
local ui_model_runtime = require("nodes.energy.ui_model")
local energy_ui_pages = require("nodes.energy.ui_pages")

local DEFAULT_CONFIG = {
  role = constants.roles.ENERGY_NODE, -- Node role identifier.
  node_id = "ENERGY-1", -- Default node_id used if none is set.
  debug_logging = true, -- Keep ENERGY logging enabled by default for field diagnostics and terminate/shutdown traces.
  reset_log_on_start = true, -- Truncate runtime log at startup to keep disk usage bounded.
  wireless_modem = nil, -- Autodetect wireless modem unless explicitly configured.
  wired_modem = nil, -- Optional wired modem side.
  matrix = nil, -- Optional induction matrix peripheral name (legacy override).
  matrix_names = {}, -- Optional list of matrix peripheral names (legacy override).
  matrix_aliases = {}, -- Optional mapping of matrix peripheral name -> display label.
  cubes = {}, -- Optional list of energy cube names (legacy override).
  scan_interval = 2, -- Seconds between lightweight discovery checks (heavy discovery runs only on topology change/forced interval).
  discovery_force_rescan_interval = 300, -- Defensive full discovery interval (seconds) even without observed topology changes.
  matrix_metric_poll_interval = 2.0, -- Seconds between expensive matrix energy metric reads (stored/capacity/input/output).
  matrix_metric_call_budget = 4, -- Max expensive matrix metric peripheral calls per payload build to avoid long blocking ticks.
  matrix_metric_time_budget_ms = 800, -- Max cumulative time spent on expensive matrix metric calls per payload build.
  matrix_metric_slow_call_ms = 150, -- Calls above this duration are treated as expensive outliers and polled less frequently.
  matrix_metric_slow_poll_multiplier = 4.0, -- Extra cadence multiplier for expensive outlier matrix metric calls.
  matrix_metric_per_matrix_budget = 1, -- Max expensive matrix metric calls per matrix/per payload build so one port cannot dominate a tick.
  matrix_component_poll_interval = 30, -- Seconds between matrix component count reads (cells/providers/ports).
  matrix_component_call_budget = 2, -- Max matrix component count calls per sampling tick to avoid periodic spikes.
  matrix_component_time_budget_ms = 400, -- Max time budget for matrix component calls per sampling tick.
  ui_refresh_interval = 1.0, -- Seconds between monitor UI refreshes.
  ui_scale = 0.5, -- Monitor text scale for the ENERGY node UI.
  monitor = {
    preferred_name = nil, -- Optional monitor name to pin (overrides auto-selection).
    strategy = "largest" -- "largest" or "first" when choosing among multiple monitors.
  },
  storage_filters = {
    include_names = nil, -- Optional allow-list; when set only these names are considered.
    exclude_names = {}, -- Optional deny-list of peripheral names to ignore.
    prefer_names = {} -- Optional names to prioritize in selection order.
  },
  heartbeat_interval = 2, -- Seconds between status heartbeats.
  status_interval = 5, -- Seconds between status payloads.
  channels = {
    control = constants.channels.CONTROL, -- Control channel for MASTER commands.
    status = constants.channels.STATUS -- Status channel for telemetry.
  },
  comms = {
    ack_timeout_s = 3.0, -- Seconds before retrying a command.
    max_retries = 4, -- Maximum retries per message.
    backoff_base_s = 0.6, -- Base backoff seconds.
    backoff_cap_s = 6.0, -- Max backoff seconds.
    dedupe_ttl_s = 30, -- Seconds to keep dedupe entries.
    dedupe_limit = 200, -- Max dedupe entries per peer.
    peer_timeout_s = 12.0, -- Seconds before marking peer down.
    peer_down_grace_s = 2.0, -- Extra stale window before logging peer down.
    peer_down_min_observations = 2, -- Consecutive stale checks required before logging peer down.
    peer_up_debounce_s = 1.5, -- Stable visibility window before logging peer up after down.
    peer_up_min_observations = 2, -- Fresh peer messages required before logging peer up after down.
    queue_limit = 200, -- Max queued outbound messages.
    drop_simulation = 0 -- Drop rate (0-1) for testing comms.
  }
}

local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}

local function add_config_warning(message)
  table.insert(config_warnings, message)
end

local function validate_config(config_values, defaults)
  return config_normalizer.normalize(config_values, defaults, utils, add_config_warning)
end

validate_config(config, DEFAULT_CONFIG)

-- Initialize file logging early to capture startup events.
local node_id = utils.read_node_id(CONFIG.NODE_ID_PATH)
local log_name = utils.build_log_name(CONFIG.LOG_NAME, node_id)
local debug_enabled = config.debug_logging
if CONFIG.DEBUG_LOG_ENABLED ~= nil then
  debug_enabled = CONFIG.DEBUG_LOG_ENABLED
end
if (config_meta and config_meta.reason) or #config_warnings > 0 then
  debug_enabled = true
end
local log_status = utils.init_logger({
  log_name = log_name,
  prefix = CONFIG.LOG_PREFIX,
  enabled = debug_enabled,
  truncate = config.reset_log_on_start == true
})
if log_status and log_status.enabled then
  utils.log(CONFIG.LOG_PREFIX, string.format("Logfile %s (startup=%s)", tostring(log_status.log_path), tostring(log_status.startup_action)), "INFO")
end
utils.log(CONFIG.LOG_PREFIX, "Startup", "INFO")
if config_meta and config_meta.reason then
  utils.log(CONFIG.LOG_PREFIX, "Config issue (" .. tostring(config_meta.reason) .. ") at " .. tostring(config_meta.path) .. "; using defaults where needed.", "WARN")
end
for _, warning in ipairs(config_warnings) do
  utils.log(CONFIG.LOG_PREFIX, warning, "WARN")
end

local registry = registry_lib.new({
  node_id = node_id,
  role = "energy",
  log_prefix = CONFIG.LOG_PREFIX,
  aliases = config.matrix_aliases or {}
})

local comms
local services
local matrix_runtime
local topology_cache
local energy_health = health.new({})
local devices = {
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
}
local master_alerts = {}
local last_heartbeat = 0
local last_heartbeat_warn = 0
local last_scan = 0
local master_peer_state
local is_master_connected
local ui_state = {
  matrix_page = 1,
  storage_page = 1,
  router = nil,
  model = nil
}
local master_seen_ts = nil
local status_payload_cache = { ts = 0, payload = nil }
local ui_model_cache = { ts = 0, model = nil, key = nil }
local storage_snapshot = {
  ts = 0,
  stale = true,
  stores = {},
  total = { stored = 0, capacity = 0, input = 0, output = 0 }
}

local function now_ms()
  return os.epoch("utc")
end

local function heartbeat_interval_ms()
  return math.max(1, tonumber(config.heartbeat_interval) or 2) * 1000
end

local function minimal_presence_state(ts_ms)
  return {
    ts = ts_ms,
    node_id = comms and comms.network and comms.network.id or config.node_id,
    role = config.role
  }
end

local function send_presence_heartbeat(ts_ms)
  ts_ms = ts_ms or now_ms()
  local interval_ms = heartbeat_interval_ms()
  if last_heartbeat > 0 then
    local delayed_by = ts_ms - last_heartbeat
    local warn_threshold = interval_ms * 2
    if delayed_by > warn_threshold and (ts_ms - last_heartbeat_warn) >= warn_threshold then
      utils.log(
        "ENERGY",
        ("Heartbeat tick delayed by %dms (interval=%dms)"):format(delayed_by, interval_ms),
        "WARN"
      )
      last_heartbeat_warn = ts_ms
    end
  end
  comms:send_heartbeat(minimal_presence_state(ts_ms))
  -- Flush heartbeat immediately on its own lightweight path so liveness does
  -- not wait for a heavy status/UI service manager tick.
  comms:tick(ts_ms)
  last_heartbeat = ts_ms
end

local function run_heartbeat_pump(ts_ms)
  ts_ms = ts_ms or now_ms()
  if ts_ms - last_heartbeat >= heartbeat_interval_ms() then
    send_presence_heartbeat(ts_ms)
  end
end

local function to_set(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[value] = true
  end
  return out
end

local function is_matrix_override(name)
  if config.matrix and name == config.matrix then
    return true
  end
  for _, entry in ipairs(config.matrix_names or {}) do
    if entry == name then
      return true
    end
  end
  return false
end

local function is_blocked_type(name)
  local type_name = peripheral.getType(name)
  if not type_name then
    return false
  end
  type_name = tostring(type_name):lower()
  return type_name == "monitor" or type_name == "modem" or type_name == "peripheral_hub"
end

local function pick_monitor()
  local preferred = config.monitor and config.monitor.preferred_name or nil
  local strategy = config.monitor and config.monitor.strategy or "largest"
  return monitor_adapter.find(preferred, strategy, config.ui_scale, CONFIG.LOG_PREFIX)
end

local function log_discovery_snapshot(names, candidates, monitor_name, matrices)
  if not debug_enabled then
    return
  end
  utils.log("ENERGY", "Discovery snapshot: names=" .. textutils.serialize(names))
  for _, name in ipairs(names) do
    utils.log("ENERGY", ("Discovery peripheral: %s type=%s"):format(tostring(name), tostring(peripheral.getType(name))))
  end
  for _, candidate in ipairs(candidates) do
    local method_list = candidate.adapter and candidate.adapter.getMethodList and candidate.adapter.getMethodList() or candidate.method_list or {}
    local kind = candidate.kind or "unknown"
    utils.log("ENERGY", ("Discovery candidate: %s kind=%s methods=%s"):format(tostring(candidate.name), tostring(kind), textutils.serialize(method_list)))
  end
  if monitor_name then
    utils.log("ENERGY", ("Discovery monitor selection: %s"):format(tostring(monitor_name)))
  end
  for _, matrix in ipairs(matrices or {}) do
    local method_list = matrix.adapter and matrix.adapter.getMethodList and matrix.adapter.getMethodList() or matrix.method_list or {}
    utils.log("ENERGY", ("Discovery matrix: %s methods=%s"):format(tostring(matrix.name), textutils.serialize(method_list)))
  end
end

local function record_error(context, err)
  if not err or err == "" then
    return
  end
  devices.last_error = string.format("%s: %s", tostring(context), tostring(err))
  devices.last_error_ts = os.epoch("utc")
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

local function discover()
  local names = peripheral.getNames() or {}
  devices.peripheral_count = #names
  local include_set = config.storage_filters and config.storage_filters.include_names and to_set(config.storage_filters.include_names) or nil
  local exclude_set = to_set(config.storage_filters and config.storage_filters.exclude_names or {})
  local prefer_names = {}
  for _, name in ipairs(config.storage_filters and config.storage_filters.prefer_names or {}) do
    table.insert(prefer_names, name)
  end
  if config.matrix then
    table.insert(prefer_names, config.matrix)
  end
  for _, name in ipairs(config.cubes or {}) do
    table.insert(prefer_names, name)
  end

  local monitor_entry = pick_monitor()
  local monitor_name = monitor_entry and monitor_entry.name or nil
  local monitor = monitor_entry and monitor_entry.mon or nil
  local previous_monitor = devices.monitor_name
  if monitor_name and monitor_name ~= previous_monitor then
    utils.log("ENERGY", "Monitor selected: " .. tostring(monitor_name))
  end
  if not monitor_name then
    record_error("monitor", "not found")
  end

  local candidates = {}
  local registry_devices = {}
  local seen = {}
  local adapter_map = { matrices = {}, storages = {} }
  local previous_adapters = devices.adapters or { matrices = {}, storages = {} }
  local next_matrix_identity_cache = {}

  for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
      table.insert(registry_devices, {
        name = name,
        type = "monitor",
        methods = utils.safe_get_methods(name) or {},
        kind = "monitor",
        bound = monitor_name == name
      })
    end
  end

  local function consider_name(name)
    if seen[name] then
      return
    end
    seen[name] = true
    if exclude_set[name] then
      return
    end
    if is_blocked_type(name) then
      return
    end
    local forced_matrix = is_matrix_override(name)
    if include_set and not include_set[name] and not forced_matrix then
      return
    end
    local existing_matrix = previous_adapters.matrices and previous_adapters.matrices[name] or nil
    local matrix
    if existing_matrix and existing_matrix.isValid and existing_matrix.isValid() then
      matrix = existing_matrix
    else
      local cached_identity = devices.matrix_identity_cache and devices.matrix_identity_cache[name] or nil
      matrix = matrix_adapter.detect(name, CONFIG.LOG_PREFIX, {
        group_key = cached_identity and cached_identity.group_key or nil,
        group_key_source = cached_identity and cached_identity.group_key_source or nil
      })
    end
    if matrix then
      table.insert(candidates, { name = name, adapter = matrix, kind = "matrix" })
      adapter_map.matrices[name] = matrix
      next_matrix_identity_cache[name] = {
        group_key = matrix.group_key,
        group_key_source = matrix.group_key_source
      }
      table.insert(registry_devices, {
        name = name,
        type = matrix.getType(),
        methods = matrix.getMethodList and matrix.getMethodList() or {},
        kind = "matrix",
        alias = config.matrix_aliases and config.matrix_aliases[name] or nil,
        bound = true,
        features = matrix.features,
        schema = matrix.schema
      })
      return
    end
    if forced_matrix then
      record_error(name, "matrix override set but methods missing")
      return
    end
    local storage = previous_adapters.storages and previous_adapters.storages[name] or nil
    if not (storage and storage.isValid and storage.isValid()) then
      storage = storage_adapter.detect(name, CONFIG.LOG_PREFIX)
    end
    if storage then
      table.insert(candidates, { name = name, adapter = storage, kind = "storage" })
      adapter_map.storages[name] = storage
      table.insert(registry_devices, {
        name = name,
        type = storage.getType(),
        methods = storage.getMethodList and storage.getMethodList() or {},
        kind = "storage",
        bound = true,
        features = storage.features,
        schema = storage.schema
      })
    end
  end

  for _, name in ipairs(names) do
    consider_name(name)
  end
  for _, name in ipairs(prefer_names) do
    if peripheral.isPresent(name) then
      consider_name(name)
    end
  end

  registry:sync(registry_devices)

  local order_index = registry:get_order_index()
  local prefer_rank = {}
  for idx, name in ipairs(prefer_names) do
    prefer_rank[name] = idx
  end

  local storage_entries = {}
  for _, entry in ipairs(registry:get_bound_devices("storage")) do
    local adapter = adapter_map.storages[entry.name]
    if adapter then
      table.insert(storage_entries, { adapter = adapter, entry = entry })
    end
  end
  table.sort(storage_entries, function(a, b)
    local rank_a = prefer_rank[a.adapter.name] or math.huge
    local rank_b = prefer_rank[b.adapter.name] or math.huge
    if rank_a ~= rank_b then
      return rank_a < rank_b
    end
    local order_a = order_index[a.entry.id] or math.huge
    local order_b = order_index[b.entry.id] or math.huge
    if order_a ~= order_b then
      return order_a < order_b
    end
    return tostring(a.adapter.name) < tostring(b.adapter.name)
  end)

  local matrix_entries = {}
  for _, entry in ipairs(registry:get_bound_devices("matrix")) do
    local adapter = adapter_map.matrices[entry.name]
    if adapter then
      table.insert(matrix_entries, { adapter = adapter, entry = entry })
    end
  end
  table.sort(matrix_entries, function(a, b)
    local order_a = order_index[a.entry.id] or math.huge
    local order_b = order_index[b.entry.id] or math.huge
    if order_a ~= order_b then
      return order_a < order_b
    end
    return tostring(a.adapter.name) < tostring(b.adapter.name)
  end)

  local storages = {}
  local bound_names = {}
  for _, item in ipairs(storage_entries) do
    table.insert(storages, {
      id = item.entry.id,
      alias = item.entry.alias,
      name = item.adapter.name,
      adapter = item.adapter
    })
    table.insert(bound_names, item.entry.alias or item.entry.id)
  end

  local matrices = {}
  for _, item in ipairs(matrix_entries) do
    table.insert(matrices, {
      id = item.entry.id,
      alias = item.entry.alias,
      name = item.adapter.name,
      adapter = item.adapter
    })
  end
  local matrix_groups = matrix_adapter.group_ports(matrices)
  local next_topology_signature = matrix_group_signature(matrix_groups)
  local topology_changed = next_topology_signature ~= (devices.topology_signature or "")
  if not topology_changed then
    -- Keep the existing logical matrix objects stable when topology did not
    -- change. This avoids rebuilding matrix groups in the hot path and keeps
    -- snapshot/UI identity stable even while adapters are refreshed.
    matrix_groups = reconcile_matrix_groups(devices.matrix_groups or {}, matrix_groups)
  end

  local bound_lookup = {}
  for _, storage in ipairs(storages) do
    bound_lookup[storage.name] = true
  end
  for _, matrix in ipairs(matrices) do
    bound_lookup[matrix.name] = true
  end
  for _, entry in ipairs(registry_devices) do
    entry.bound = bound_lookup[entry.name] or false
  end

  -- Keep the existing wrapped monitor object when the selected monitor name did
  -- not change. Re-wrapping every discovery cycle invalidates UI dirty caches
  -- and causes visible full redraw flicker on otherwise unchanged frames.
  if monitor_name and monitor_name == devices.monitor_name and devices.monitor then
    monitor = devices.monitor
  end
  devices.monitor = monitor
  devices.monitor_name = monitor_name
  devices.storages = storages
  devices.matrices = matrices
  devices.matrix_groups = matrix_groups
  devices.bound_storage_names = bound_names
  devices.adapters = adapter_map
  devices.registry_snapshot = registry:get_devices_by_kind()
  devices.registry_summary = registry:get_summary()
  devices.registry_load_error = registry.state.load_error
  devices.last_scan_ts = os.epoch("utc")
  devices.last_scan_result = ("monitor=%s storages=%d"):format(monitor_name or "none", #storages)
  devices.matrix_identity_cache = next_matrix_identity_cache
  devices.topology_signature = next_topology_signature
  if topology_cache then
    topology_cache:record_discovery(devices.last_scan_ts, next_topology_signature)
  end
  if matrix_runtime and topology_changed then
    -- Invalidate matrix sampling cache only when matrix topology/grouping really
    -- changed. Invalidating on every discovery tick caused false "missing" data
    -- windows and visible UI/master flapping under load.
    matrix_runtime:invalidate()
  end
  if topology_changed then
    status_payload_cache.ts = 0
    status_payload_cache.payload = nil
    ui_model_cache.ts = 0
    ui_model_cache.model = nil
    ui_model_cache.key = nil
  end

  local peripheral_types = {}
  for _, name in ipairs(names) do
    peripheral_types[name] = peripheral.getType(name)
  end
  local candidate_snapshot = {}
  for _, candidate in ipairs(candidates) do
    candidate_snapshot[#candidate_snapshot + 1] = {
      name = candidate.name,
      kind = candidate.kind,
      methods = candidate.adapter and candidate.adapter.getMethodList and candidate.adapter.getMethodList() or candidate.method_list or {}
    }
  end
  local matrix_snapshot = {}
  for _, matrix in ipairs(matrices or {}) do
    matrix_snapshot[#matrix_snapshot + 1] = {
      name = matrix.name,
      methods = matrix.adapter and matrix.adapter.getMethodList and matrix.adapter.getMethodList() or matrix.method_list or {}
    }
  end
  local matrix_group_snapshot = {}
  for _, group in ipairs(matrix_groups or {}) do
    local group_ports = {}
    for _, port in ipairs(group.ports or {}) do
      group_ports[#group_ports + 1] = port.name
    end
    matrix_group_snapshot[#matrix_group_snapshot + 1] = {
      key = group.key,
      reader = group.representative and group.representative.name or nil,
      ports = group_ports
    }
  end
  local signature = discovery_log.build_signature({
    names = names,
    peripheral_types = peripheral_types,
    candidates = candidate_snapshot,
    monitor_name = monitor_name,
    matrices = matrix_snapshot,
    matrix_groups = matrix_group_snapshot,
    registry_summary = devices.registry_summary
  })
  if debug_enabled and topology_changed and #matrix_groups > 0 then
    for _, group in ipairs(matrix_groups) do
      local port_names = {}
      for _, port in ipairs(group.ports or {}) do
        port_names[#port_names + 1] = tostring(port.name)
      end
      utils.log("ENERGY", ("Matrix group %s source=%s via %s ports=%s"):format(
        tostring(group.key),
        tostring(group.key_source or "n/a"),
        tostring(group.representative and group.representative.name or "n/a"),
        table.concat(port_names, ",")
      ))
    end
  end
  if discovery_log.should_log_details(devices.discovery_signature, signature, devices.discovery_failed) then
    log_discovery_snapshot(names, candidates, monitor_name, matrices)
  end
  devices.discovery_signature = signature
  return registry_devices
end

-- Storage sampling is kept off the telemetry/UI path: both layers consume this
-- cached snapshot only, so heavy peripheral reads cannot block rendering/comms.
local function sample_storage_stats(ts)
  local total, capacity, input, output = 0, 0, 0, 0
  local stores = {}
  for _, storage in ipairs(devices.storages or {}) do
    local adapter = storage.adapter
    local had_error = false
    local function read_metric(label, fn)
      if not fn then
        return 0
      end
      local value, err = fn()
      if err then
        record_error(storage.name .. "." .. tostring(label), err)
        had_error = true
      end
      return tonumber(value) or 0
    end
    local stored = read_metric("stored", adapter and adapter.getStored)
    local cap = read_metric("capacity", adapter and adapter.getCapacity)
    local in_rate = read_metric("input", adapter and adapter.getInput)
    local out_rate = read_metric("output", adapter and adapter.getOutput)
    stored = tonumber(stored) or 0
    cap = tonumber(cap) or stored
    in_rate = tonumber(in_rate) or 0
    out_rate = tonumber(out_rate) or 0
    total = total + stored
    capacity = capacity + cap
    input = input + in_rate
    output = output + out_rate
    table.insert(stores, {
      id = storage.id or storage.name,
      alias = storage.alias,
      name = storage.name,
      stored = stored,
      capacity = cap,
      input = in_rate,
      output = out_rate,
      is_matrix = storage.is_matrix or false,
      ok = not had_error
    })
  end
  storage_snapshot = {
    ts = ts or now_ms(),
    stale = false,
    stores = stores,
    total = { stored = total, capacity = capacity, input = input, output = output }
  }
end

local function read_storage_stats(opts)
  opts = opts or {}
  local max_age_ms = tonumber(opts.max_age_ms) or math.max(3000, math.floor((tonumber(config.status_interval) or 5) * 1000))
  local now = now_ms()
  local age = now - (storage_snapshot.ts or 0)
  if max_age_ms > 0 and age > max_age_ms and #storage_snapshot.stores == 0 then
    sample_storage_stats(now)
    age = now - (storage_snapshot.ts or 0)
  end
  return {
    stored = tonumber(storage_snapshot.total and storage_snapshot.total.stored) or 0,
    capacity = tonumber(storage_snapshot.total and storage_snapshot.total.capacity) or 0,
    input = tonumber(storage_snapshot.total and storage_snapshot.total.input) or 0,
    output = tonumber(storage_snapshot.total and storage_snapshot.total.output) or 0,
    stores = utils.deep_copy(storage_snapshot.stores or {}),
    freshness_ms = age,
    stale = (storage_snapshot.ts or 0) <= 0 or (max_age_ms > 0 and age > max_age_ms)
  }
end

local function read_matrix_stats(opts)
  opts = opts or {}
  local snapshot_max_age_ms = tonumber(opts.max_age_ms) or math.max(3000, math.floor((tonumber(config.status_interval) or 5) * 1000))
  if not matrix_runtime then
    return {
      matrices = {},
      total = { stored = 0, capacity = 0, percent = 0, input = nil, output = nil },
      diag = { metric_calls = {}, metric_totals = {}, throttled = nil },
      stale = true
    }
  end
  local snapshot = matrix_runtime:get_snapshot(snapshot_max_age_ms)
  return {
    matrices = snapshot.matrices or {},
    total = snapshot.total or { stored = 0, capacity = 0, percent = 0, input = nil, output = nil },
    diag = snapshot.diag or { metric_calls = {}, metric_totals = {}, throttled = nil },
    stale = snapshot.stale,
    freshness_ms = snapshot.freshness_ms
  }
end

local status_payload_builder
local ui_model_builder
local ui_pages

local function build_status_payload_uncached(opts)
  return status_payload_builder.build_status_payload_uncached(opts)
end

local function build_status_payload(opts)
  return status_payload_builder.build_status_payload(opts)
end

local function build_ui_model(opts)
  return ui_model_builder.build_ui_model(opts)
end

local function build_snapshot_key(model)
  return ui_model_builder.build_snapshot_key(model)
end

local function get_ui_snapshot_key(opts)
  return ui_model_builder.get_ui_snapshot_key(opts)
end

local function render_overview(mon, model)
  return ui_pages.render_overview(mon, model)
end

local function render_matrices(mon, model)
  return ui_pages.render_matrices(mon, model)
end

local function render_storages(mon, model)
  return ui_pages.render_storages(mon, model)
end

local function render_diagnostics(mon, model)
  return ui_pages.render_diagnostics(mon, model)
end

local function render_monitor()
  if not devices.monitor then
    return
  end
  local model = build_ui_model({
    max_age_ms = math.max(
      math.floor((tonumber(config.ui_refresh_interval) or 1.0) * 1000),
      math.floor((tonumber(config.status_interval) or 5) * 1000)
    )
  })
  ui_state.model = model
  local expected_pages = 3 + (#model.storages > 0 and 1 or 0)
  if not ui_state.router or ui_state.router:count() ~= expected_pages then
    local pages = {
      { name = "Overview", render = function(target, view)
        render_overview(target, view.data or view)
      end },
      { name = "Matrices", render = function(target, view)
        render_matrices(target, view.data or view)
      end }
    }
    if #model.storages > 0 then
      table.insert(pages, { name = "Storages", render = function(target, view)
        render_storages(target, view.data or view)
      end })
    end
    table.insert(pages, { name = "Diagnostics", render = function(target, view)
      render_diagnostics(target, view.data or view)
    end })
    ui_state.router = ui_router.new(devices.monitor, {
      title = "ENERGY",
      pages = pages,
      interval = config.ui_refresh_interval,
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true }
    })
  end
  local snapshot = ui_model_cache.key or build_snapshot_key(model)
  ui_state.router:render(devices.monitor, {
    snapshot = {
      data = snapshot,
      matrix_page = ui_state.matrix_page,
      storage_page = ui_state.storage_page
    },
    data = model
  })
end

local warned = {}
local function warn_once(key, message)
  if warned[key] then return end
  warned[key] = true
  utils.log("ENERGY", message, "WARN")
end

master_peer_state = function()
  local peers = comms and comms:get_peers() or {}
  for _, data in pairs(peers) do
    if data.role == constants.roles.MASTER then
      return data
    end
  end
  return nil
end

is_master_connected = function()
  local peer = master_peer_state()
  if peer then
    return not peer.down, peer.age
  end
  if master_seen_ts then
    local age = (os.epoch("utc") - master_seen_ts) / 1000
    return age <= config.heartbeat_interval * 6, age
  end
  return false, nil
end

local message_handler = nil

local function handle_message(message)
  return message_handler and message_handler.handle_message(message)
end

local function handle_command(message)
  return message_handler and message_handler.handle_command(message)
end

local function init()
  utils.log("ENERGY", "Initializing services (comms, discovery, telemetry, ui)", "INFO")
  message_handler = command_handler.new({
    protocol = protocol,
    constants = constants,
    get_comms_id = function() return comms and comms.network and comms.network.id or config.node_id end,
    set_last_command = function(command_error)
      devices.last_command = command_error
      devices.last_command_ts = os.epoch("utc")
    end,
    mark_master_seen = function() master_seen_ts = os.epoch("utc") end,
    on_master_alerts = function(alerts) master_alerts = alerts end,
    on_proto_mismatch = function() devices.proto_mismatch = true end
  })
  comms = comms_service.new({
    name = "COMMS",
    config = config,
    log_prefix = "ENERGY",
    on_message = handle_message,
    on_command = handle_command
  })
  services = service_manager.new({
    log_prefix = "ENERGY",
    inter_service_hook = function(_, _, phase)
      if phase == "before_service" or phase == "after_service" then
        run_heartbeat_pump(now_ms())
      end
    end
  })
  matrix_runtime = matrix_snapshot_runtime.new({
    log_prefix = "ENERGY",
    config = config,
    debug_enabled = debug_enabled,
    get_groups = function()
      return devices.matrix_groups or {}
    end,
    heartbeat_pump = run_heartbeat_pump,
    record_error = record_error
  })
  topology_cache = matrix_topology_cache.new({
    log_prefix = "ENERGY",
    forced_rescan_interval_s = config.discovery_force_rescan_interval
  })
  status_payload_builder = status_payload_runtime.new({
    now_ms = now_ms,
    config = config,
    utils = utils,
    health = health,
    registry = registry,
    devices = devices,
    energy_health = energy_health,
    read_storage_stats = read_storage_stats,
    read_matrix_stats = read_matrix_stats,
    is_master_connected = function() return is_master_connected() end,
    status_payload_cache = status_payload_cache,
    log = function(message, level) utils.log("ENERGY", message, level or "INFO") end
  })
  ui_pages = energy_ui_pages.new({
    ui = ui,
    colors = colors,
    ui_router = ui_router,
    ui_state = ui_state
  })
  ui_model_builder = ui_model_runtime.new({
    now_ms = now_ms,
    config = config,
    utils = utils,
    health = health,
    registry = registry,
    comms = comms,
    devices = devices,
    master_peer_state = function() return master_peer_state() end,
    master_alerts = function() return master_alerts end,
    build_status_payload = function(args) return build_status_payload(args) end,
    ui_model_cache = ui_model_cache
  })
  services:add(comms)
  services:add(discovery_service.new({
    name = "DISCOVERY",
    log_prefix = "DISCOVERY",
    registry = registry,
    discover = discover,
    interval = config.scan_interval,
    -- Discovery must stay out of the hot path: we only execute full discovery
    -- when topology changed (peripheral attach/detach/signature drift) or when
    -- a defensive forced-rescan interval elapsed.
    should_discover = function(_, ts, event, due)
      if not topology_cache then
        return due
      end
      return topology_cache:should_discover(ts, event, due)
    end,
    managed_registry = false,
    update_health = function(ok, reason)
      devices.discovery_failed = not ok
    end
  }))
  services:add(matrix_sampling_service.new({
    name = "STORAGE_SAMPLE",
    interval = 0.5,
    runtime = {
      tick = function(_, ts)
        sample_storage_stats(ts or now_ms())
      end
    }
  }))
  services:add(matrix_sampling_service.new({
    name = "MATRIX_SAMPLE",
    interval = 0.25,
    runtime = matrix_runtime
  }))
  services:add(telemetry_service.new({
    name = "TELEMETRY",
    log_prefix = "TELEMETRY",
    comms = comms,
    status_interval = config.status_interval or config.heartbeat_interval,
    heartbeat_interval = config.heartbeat_interval,
    enable_heartbeat = false,
    status_max_age_ms = 1000,
    build_payload = build_status_payload
  }))
  services:add(ui_service.new({
    name = "UI",
    interval = config.ui_refresh_interval,
    snapshot = function()
      return {
        page = ui_state.router and ui_state.router.index or 1,
        matrix_page = ui_state.matrix_page,
        storage_page = ui_state.storage_page,
        data = get_ui_snapshot_key({
          max_age_ms = math.max(1000, math.floor((tonumber(config.status_interval) or 5) * 1000))
        })
      }
    end,
    render = render_monitor,
    handle_input = function(event)
      if ui_state.router then
        ui_state.router:handle_input(event)
      end
    end
  }))
  services:init()
  sample_storage_stats(now_ms())
  local summary = registry:get_summary()
  comms:send_hello({
    storages = summary.kinds.storage and summary.kinds.storage.bound or 0,
    matrices = summary.kinds.matrix and summary.kinds.matrix.bound or 0,
    monitor = devices.monitor and 1 or 0
  })
  utils.log("ENERGY", "Node ready: " .. comms.network.id)
end

local function is_terminate_error(err)
  local message = tostring(err or ""):lower()
  return message:find("terminate", 1, true) ~= nil
end

local function shutdown(reason)
  local shutdown_reason = tostring(reason or "requested")
  if shutdown_reason:lower():find("terminate", 1, true) then
    utils.log("ENERGY", "terminate received", "WARN")
  else
    utils.log("ENERGY", "shutdown requested: " .. shutdown_reason, "WARN")
  end
  utils.log("ENERGY", "shutting down services", "INFO")
  if services then
    local ok, err = pcall(function()
      services:stop()
    end)
    if not ok and not is_terminate_error(err) then
      utils.log("ENERGY", "service shutdown error: " .. tostring(err), "ERROR")
    end
  end
  utils.log("ENERGY", "shutdown complete", "INFO")
end

local function main_loop()
  utils.log("ENERGY", "Entering event loop", "INFO")
  local hb_interval_ms = heartbeat_interval_ms()
  local heartbeat_timer = os.startTimer(hb_interval_ms / 1000)
  local function rearm_heartbeat_timer()
    heartbeat_timer = os.startTimer(hb_interval_ms / 1000)
  end
  while true do
    local timer = os.startTimer(CONFIG.RECEIVE_TIMEOUT)
    while true do
      local event = { os.pullEventRaw() }
      if event[1] == "terminate" then
        return "terminate received"
      end
      if event[1] == "modem_message" then
        comms:handle_event(event)
        run_heartbeat_pump(now_ms())
      elseif event[1] == "monitor_touch" or event[1] == "key" then
        services:tick(nil, event)
      elseif event[1] == "timer" and event[2] == heartbeat_timer then
        run_heartbeat_pump(now_ms())
        rearm_heartbeat_timer()
      elseif event[1] == "timer" and event[2] == timer then
        break
      end
    end
    if now_ms() - last_heartbeat >= hb_interval_ms then
      run_heartbeat_pump(now_ms())
      rearm_heartbeat_timer()
    end
    run_heartbeat_pump(now_ms())
    services:tick()
    run_heartbeat_pump(now_ms())
  end
end

local ok, result_or_err = xpcall(function()
  init()
  send_presence_heartbeat(now_ms())
  return main_loop()
end, function(err)
  return err
end)

if ok then
  shutdown(result_or_err)
else
  if is_terminate_error(result_or_err) then
    shutdown("terminate received")
  else
    shutdown("runtime error: " .. tostring(result_or_err))
    error(result_or_err, 0)
  end
end
