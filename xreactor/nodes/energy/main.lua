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
local runtime_context = require("nodes.energy.runtime_context")
local discovery_runtime = require("nodes.energy.discovery_runtime")
local storage_snapshot_runtime = require("nodes.energy.storage_snapshot_runtime")

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
local runtime = runtime_context.new({ config = config, role = "energy" })
local devices = runtime.devices
local ui_state = runtime.ui_state
local status_payload_cache = runtime.status_payload_cache
local ui_model_cache = runtime.ui_model_cache
local master_peer_state
local is_master_connected
local discover

local now_ms = runtime.now_ms

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
  if runtime.last_heartbeat > 0 then
    local delayed_by = ts_ms - runtime.last_heartbeat
    local warn_threshold = interval_ms * 2
    if delayed_by > warn_threshold and (ts_ms - runtime.last_heartbeat_warn) >= warn_threshold then
      utils.log(
        "ENERGY",
        ("Heartbeat tick delayed by %dms (interval=%dms)"):format(delayed_by, interval_ms),
        "WARN"
      )
      runtime.last_heartbeat_warn = ts_ms
    end
  end
  comms:send_heartbeat(minimal_presence_state(ts_ms))
  -- Flush heartbeat immediately on its own lightweight path so liveness does
  -- not wait for a heavy status/UI service manager tick.
  comms:tick(ts_ms)
  runtime.last_heartbeat = ts_ms
end

local function run_heartbeat_pump(ts_ms)
  ts_ms = ts_ms or now_ms()
  if ts_ms - runtime.last_heartbeat >= heartbeat_interval_ms() then
    send_presence_heartbeat(ts_ms)
  end
end

-- Storage sampling is kept off the telemetry/UI path: both layers consume this
-- cached snapshot only, so heavy peripheral reads cannot block rendering/comms.
local storage_runtime
local sample_storage_stats
local read_storage_stats

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
  if runtime.master_seen_ts then
    local age = (os.epoch("utc") - runtime.master_seen_ts) / 1000
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
    mark_master_seen = function() runtime.master_seen_ts = os.epoch("utc") end,
    on_master_alerts = function(alerts) runtime.master_alerts = alerts end,
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
  local discovery_runner = discovery_runtime.new({
    config = config,
    debug_enabled = debug_enabled,
    utils = utils,
    peripheral = peripheral,
    monitor_adapter = monitor_adapter,
    matrix_adapter = matrix_adapter,
    storage_adapter = storage_adapter,
    discovery_log = discovery_log,
    registry = registry,
    devices = devices,
    topology_cache = topology_cache,
    matrix_runtime = matrix_runtime,
    record_error = record_error,
    on_topology_changed = function()
      -- compatibility guard: if topology_changed then invalidate payload/ui caches.
      status_payload_cache.ts = 0
      status_payload_cache.payload = nil
      ui_model_cache.ts = 0
      ui_model_cache.model = nil
      ui_model_cache.key = nil
    end,
    log = function(message, level) utils.log("ENERGY", message, level or "INFO") end
  })
  -- discovery_runtime keeps reconcile_matrix_groups behavior centralized.
  discover = discovery_runner.discover
  storage_runtime = storage_snapshot_runtime.new({
    now_ms = now_ms,
    config = config,
    devices = devices,
    utils = utils,
    record_error = record_error
  })
  sample_storage_stats = storage_runtime.sample_storage_stats
  read_storage_stats = storage_runtime.read_storage_stats
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
    master_alerts = function() return runtime.master_alerts end,
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
    if now_ms() - runtime.last_heartbeat >= hb_interval_ms then
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
