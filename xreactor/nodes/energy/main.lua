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
local network_lib = require("core.network")
local ui = require("core.ui")
local colors = require("shared.colors")

local DEFAULT_CONFIG = {
  role = constants.roles.ENERGY_NODE, -- Node role identifier.
  node_id = "ENERGY-1", -- Default node_id used if none is set.
  debug_logging = false, -- Enable debug logging to /xreactor/logs/energy.log.
  wireless_modem = "right", -- Default wireless modem side.
  wired_modem = nil, -- Optional wired modem side.
  matrix = nil, -- Optional induction matrix peripheral name (legacy override).
  matrix_names = {}, -- Optional list of matrix peripheral names (legacy override).
  matrix_aliases = {}, -- Optional mapping of matrix peripheral name -> display label.
  cubes = {}, -- Optional list of energy cube names (legacy override).
  scan_interval = 15, -- Seconds between peripheral discovery scans.
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
  channels = {
    control = constants.channels.CONTROL, -- Control channel for MASTER commands.
    status = constants.channels.STATUS -- Status channel for telemetry.
  }
}

local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}

local function add_config_warning(message)
  table.insert(config_warnings, message)
end

local function validate_config(config_values, defaults)
  local normalized = utils.normalize_node_id(config_values.node_id)
  if normalized == "UNKNOWN" then
    config_values.node_id = defaults.node_id
    add_config_warning("node_id missing/invalid; defaulting to " .. tostring(defaults.node_id))
  else
    config_values.node_id = normalized
  end
  if type(config_values.role) ~= "string" then
    config_values.role = defaults.role
    add_config_warning("role missing/invalid; defaulting to " .. tostring(defaults.role))
  end
  if type(config_values.debug_logging) ~= "boolean" then
    config_values.debug_logging = defaults.debug_logging
    add_config_warning("debug_logging missing/invalid; defaulting to " .. tostring(defaults.debug_logging))
  end
  if type(config_values.wireless_modem) ~= "string" then
    config_values.wireless_modem = defaults.wireless_modem
    add_config_warning("wireless_modem missing/invalid; defaulting to " .. tostring(defaults.wireless_modem))
  end
  if config_values.wired_modem ~= nil and type(config_values.wired_modem) ~= "string" then
    config_values.wired_modem = defaults.wired_modem
    add_config_warning("wired_modem invalid; defaulting to " .. tostring(defaults.wired_modem))
  end
  if config_values.matrix ~= nil and type(config_values.matrix) ~= "string" then
    config_values.matrix = defaults.matrix
    add_config_warning("matrix invalid; defaulting to " .. tostring(defaults.matrix))
  end
  if type(config_values.matrix_names) ~= "table" then
    config_values.matrix_names = utils.deep_copy(defaults.matrix_names)
    add_config_warning("matrix_names missing/invalid; defaulting to configured list")
  end
  if type(config_values.matrix_aliases) ~= "table" then
    config_values.matrix_aliases = utils.deep_copy(defaults.matrix_aliases)
    add_config_warning("matrix_aliases missing/invalid; defaulting to configured mapping")
  end
  if type(config_values.cubes) ~= "table" then
    config_values.cubes = utils.deep_copy(defaults.cubes)
    add_config_warning("cubes missing/invalid; defaulting to configured list")
  end
  if type(config_values.scan_interval) ~= "number" or config_values.scan_interval <= 0 then
    config_values.scan_interval = defaults.scan_interval
    add_config_warning("scan_interval missing/invalid; defaulting to " .. tostring(defaults.scan_interval))
  end
  if type(config_values.ui_refresh_interval) ~= "number" or config_values.ui_refresh_interval <= 0 then
    config_values.ui_refresh_interval = defaults.ui_refresh_interval
    add_config_warning("ui_refresh_interval missing/invalid; defaulting to " .. tostring(defaults.ui_refresh_interval))
  end
  if type(config_values.ui_scale) ~= "number" or config_values.ui_scale <= 0 then
    config_values.ui_scale = defaults.ui_scale
    add_config_warning("ui_scale missing/invalid; defaulting to " .. tostring(defaults.ui_scale))
  end
  if type(config_values.monitor) ~= "table" then
    config_values.monitor = utils.deep_copy(defaults.monitor)
    add_config_warning("monitor config missing/invalid; defaulting to configured monitor options")
  end
  if config_values.monitor.preferred_name ~= nil and type(config_values.monitor.preferred_name) ~= "string" then
    config_values.monitor.preferred_name = defaults.monitor.preferred_name
    add_config_warning("monitor.preferred_name invalid; defaulting to configured value")
  end
  if type(config_values.monitor.strategy) ~= "string" then
    config_values.monitor.strategy = defaults.monitor.strategy
    add_config_warning("monitor.strategy invalid; defaulting to " .. tostring(defaults.monitor.strategy))
  end
  if type(config_values.storage_filters) ~= "table" then
    config_values.storage_filters = utils.deep_copy(defaults.storage_filters)
    add_config_warning("storage_filters missing/invalid; defaulting to configured filters")
  end
  if config_values.storage_filters.include_names ~= nil and type(config_values.storage_filters.include_names) ~= "table" then
    config_values.storage_filters.include_names = defaults.storage_filters.include_names
    add_config_warning("storage_filters.include_names invalid; defaulting to configured value")
  end
  if type(config_values.storage_filters.exclude_names) ~= "table" then
    config_values.storage_filters.exclude_names = utils.deep_copy(defaults.storage_filters.exclude_names)
    add_config_warning("storage_filters.exclude_names missing/invalid; defaulting to configured list")
  end
  if type(config_values.storage_filters.prefer_names) ~= "table" then
    config_values.storage_filters.prefer_names = utils.deep_copy(defaults.storage_filters.prefer_names)
    add_config_warning("storage_filters.prefer_names missing/invalid; defaulting to configured list")
  end
  if type(config_values.heartbeat_interval) ~= "number" or config_values.heartbeat_interval <= 0 then
    config_values.heartbeat_interval = defaults.heartbeat_interval
    add_config_warning("heartbeat_interval missing/invalid; defaulting to " .. tostring(defaults.heartbeat_interval))
  end
  if type(config_values.channels) ~= "table" then
    config_values.channels = utils.deep_copy(defaults.channels)
    add_config_warning("channels missing/invalid; defaulting to control/status defaults")
  end
  if type(config_values.channels.control) ~= "number" then
    config_values.channels.control = defaults.channels.control
    add_config_warning("channels.control missing/invalid; defaulting to " .. tostring(defaults.channels.control))
  end
  if type(config_values.channels.status) ~= "number" then
    config_values.channels.status = defaults.channels.status
    add_config_warning("channels.status missing/invalid; defaulting to " .. tostring(defaults.channels.status))
  end
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
utils.init_logger({ log_name = log_name, prefix = CONFIG.LOG_PREFIX, enabled = debug_enabled })
utils.log(CONFIG.LOG_PREFIX, "Startup", "INFO")
if config_meta and config_meta.reason then
  utils.log(CONFIG.LOG_PREFIX, "Config issue (" .. tostring(config_meta.reason) .. ") at " .. tostring(config_meta.path) .. "; using defaults where needed.", "WARN")
end
for _, warning in ipairs(config_warnings) do
  utils.log(CONFIG.LOG_PREFIX, warning, "WARN")
end

local network
local devices = {
  storages = {},
  matrices = {},
  monitor = nil,
  monitor_name = nil,
  bound_storage_names = {},
  degraded_reason = nil,
  last_scan_ts = nil,
  last_scan_result = nil,
  peripheral_count = 0,
  last_error = nil,
  last_error_ts = nil
}
local last_heartbeat = 0
local last_scan = 0
local ui_state = { last_snapshot = nil, last_draw = 0, page = 1, pages = {} }

local function to_set(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[value] = true
  end
  return out
end

local function get_method_list(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    return {}
  end
  return methods
end

local function build_method_set(method_list)
  return to_set(method_list or {})
end

local function resolve_storage_profile(methods)
  if methods.getEnergy and methods.getMaxEnergy then
    return { stored = "getEnergy", capacity = "getMaxEnergy", input = "getLastInput", output = "getLastOutput" }
  end
  if methods.getEnergyStored and methods.getMaxEnergyStored then
    return { stored = "getEnergyStored", capacity = "getMaxEnergyStored" }
  end
  if methods.getStoredPower and methods.getMaxStoredPower then
    return { stored = "getStoredPower", capacity = "getMaxStoredPower" }
  end
  return nil
end

local function resolve_first_method(methods, candidates)
  for _, name in ipairs(candidates or {}) do
    if methods[name] then
      return name
    end
  end
  return nil
end

local function is_matrix_method_set(methods)
  local keys = {
    "getInstalledCells",
    "getInstalledProviders",
    "getInstalledPorts",
    "getCells",
    "getProviders",
    "getPorts",
    "getInductionCells",
    "getInductionProviders",
    "getInductionPorts"
  }
  for _, key in ipairs(keys) do
    if methods[key] then
      return true
    end
  end
  return false
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
  if config.monitor and config.monitor.preferred_name then
    local preferred = config.monitor.preferred_name
    if peripheral.getType(preferred) == "monitor" then
      return preferred
    end
  end
  local monitors = { peripheral.find("monitor") }
  local candidates = {}
  for _, mon in ipairs(monitors) do
    local ok, name = pcall(peripheral.getName, mon)
    if ok and name then
      table.insert(candidates, { name = name, mon = mon })
    end
  end
  if #candidates == 0 then
    return nil
  end
  if config.monitor and tostring(config.monitor.strategy):lower() == "first" then
    table.sort(candidates, function(a, b) return a.name < b.name end)
    return candidates[1].name
  end
  local best_name, best_area
  for _, entry in ipairs(candidates) do
    local w, h = entry.mon.getSize()
    local area = w * h
    if not best_area or area > best_area then
      best_area = area
      best_name = entry.name
    end
  end
  if best_name then
    return best_name
  end
  table.sort(candidates, function(a, b) return a.name < b.name end)
  return candidates[1].name
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
    utils.log("ENERGY", ("Discovery candidate: %s methods=%s"):format(tostring(candidate.name), textutils.serialize(candidate.method_list)))
  end
  if monitor_name then
    utils.log("ENERGY", ("Discovery monitor selection: %s"):format(tostring(monitor_name)))
  end
  for _, matrix in ipairs(matrices or {}) do
    utils.log("ENERGY", ("Discovery matrix: %s methods=%s"):format(tostring(matrix.name), textutils.serialize(matrix.method_list or {})))
  end
end

local function record_error(context, err)
  if not err or err == "" then
    return
  end
  devices.last_error = string.format("%s: %s", tostring(context), tostring(err))
  devices.last_error_ts = os.epoch("utc")
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

  local monitor_name = pick_monitor()
  local previous_monitor = devices.monitor_name
  local monitor, monitor_err = monitor_name and utils.safe_wrap(monitor_name) or nil
  if monitor_name and not monitor then
    utils.log("ENERGY", "WARN: monitor wrap failed for " .. tostring(monitor_name))
    record_error("monitor", monitor_err or "wrap failed")
  elseif not monitor_name then
    record_error("monitor", "not found")
  end
  if monitor and monitor.setTextScale then
    monitor.setTextScale(config.ui_scale)
  end
  if monitor_name and monitor_name ~= previous_monitor then
    utils.log("ENERGY", "Monitor selected: " .. tostring(monitor_name))
  end

  local storages = {}
  local bound_names = {}
  local candidates = {}
  local matrices = {}

  local function consider_name(name)
    if exclude_set[name] then
      return
    end
    if is_blocked_type(name) then
      return
    end
    if include_set and not include_set[name] then
      return
    end
    local method_list = get_method_list(name)
    local methods = build_method_set(method_list)
    local profile = resolve_storage_profile(methods)
    if profile then
      local is_matrix = is_matrix_method_set(methods) or is_matrix_override(name)
      if is_matrix then
        table.insert(matrices, { name = name, profile = profile, method_list = method_list })
      end
      table.insert(candidates, { name = name, profile = profile, methods = methods, method_list = method_list })
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

  local matrix_set = {}
  table.sort(matrices, function(a, b) return a.name < b.name end)
  for _, matrix in ipairs(matrices) do
    matrix_set[matrix.name] = true
  end
  local seen = {}
  for _, candidate in ipairs(candidates) do
    if not seen[candidate.name] and not matrix_set[candidate.name] then
      seen[candidate.name] = true
      local wrapped, wrap_err = utils.safe_wrap(candidate.name)
      if wrapped then
        table.insert(storages, {
          name = candidate.name,
          profile = candidate.profile
        })
        table.insert(bound_names, candidate.name)
      elseif wrap_err then
        record_error(candidate.name, wrap_err)
      end
    end
  end

  local degraded_reason
  if #names == 0 then
    degraded_reason = "no_peripherals"
  else
    local reasons = {}
    if not monitor then
      table.insert(reasons, "no_monitor")
    end
    if #storages == 0 then
      table.insert(reasons, "no_storage")
    end
    if #reasons > 0 then
      degraded_reason = table.concat(reasons, ",")
    end
  end

  devices.monitor = monitor
  devices.monitor_name = monitor_name
  devices.storages = storages
  devices.matrices = matrices
  devices.bound_storage_names = bound_names
  devices.degraded_reason = degraded_reason
  devices.last_scan_ts = os.epoch("utc")
  devices.last_scan_result = ("monitor=%s storages=%d"):format(monitor_name or "none", #storages)

  log_discovery_snapshot(names, candidates, monitor_name, matrices)
end

local function hello()
  network:broadcast(protocol.hello(network.id, network.role, {
    storages = #(devices.storages or {}),
    monitor = devices.monitor and 1 or 0
  }))
end

local function read_storage_stats()
  local total, capacity, input, output = 0, 0, 0, 0
  local stores = {}
  for _, storage in ipairs(devices.storages or {}) do
    local profile = storage.profile or {}
    local function read_metric(method)
      if not method then
        return 0
      end
      local value, err = utils.safe_peripheral_call(storage.name, method)
      if err then
        record_error(storage.name .. "." .. tostring(method), err)
      end
      return tonumber(value) or 0
    end
    local stored = read_metric(profile.stored)
    local cap = read_metric(profile.capacity)
    local in_rate = read_metric(profile.input)
    local out_rate = read_metric(profile.output)
    stored = tonumber(stored) or 0
    cap = tonumber(cap) or stored
    in_rate = tonumber(in_rate) or 0
    out_rate = tonumber(out_rate) or 0
    total = total + stored
    capacity = capacity + cap
    input = input + in_rate
    output = output + out_rate
    table.insert(stores, {
      id = storage.name,
      stored = stored,
      capacity = cap,
      input = in_rate,
      output = out_rate,
      is_matrix = storage.is_matrix or false
    })
  end
  return { stored = total, capacity = capacity, input = input, output = output, stores = stores }
end

local function read_matrix_stats()
  local matrices = {}
  local total = { stored = 0, capacity = 0, input = 0, output = 0, has_flow = false }
  for idx, matrix in ipairs(devices.matrices or {}) do
    local methods = build_method_set(matrix.method_list or {})
    local profile = resolve_storage_profile(methods)
    local function read_metric(method)
      if not method then
        return nil, "missing method"
      end
      local value, err = utils.safe_peripheral_call(matrix.name, method)
      if err then
        record_error(matrix.name .. "." .. tostring(method), err)
      end
      return tonumber(value), err
    end
    local stored, stored_err = read_metric(profile and profile.stored)
    local capacity, cap_err = read_metric(profile and profile.capacity)
    stored = stored or 0
    capacity = capacity or stored
    local input = select(1, read_metric(profile and profile.input))
    local output = select(1, read_metric(profile and profile.output))
    local cells_method = resolve_first_method(methods, { "getInstalledCells", "getCells", "getInductionCells" })
    local providers_method = resolve_first_method(methods, { "getInstalledProviders", "getProviders", "getInductionProviders" })
    local ports_method = resolve_first_method(methods, { "getInstalledPorts", "getPorts", "getInductionPorts" })
    local cells = select(1, read_metric(cells_method))
    local providers = select(1, read_metric(providers_method))
    local ports = select(1, read_metric(ports_method))
    local degraded = stored_err or cap_err
    if debug_enabled and (cells == nil or providers == nil or ports == nil) then
      utils.log("ENERGY", ("Matrix component counts unavailable (%s). Methods=%s"):format(
        matrix.name, textutils.serialize(matrix.method_list or {})
      ))
    end
    if input ~= nil or output ~= nil then
      total.has_flow = true
      total.input = total.input + (input or 0)
      total.output = total.output + (output or 0)
    end
    total.stored = total.stored + stored
    total.capacity = total.capacity + capacity
    local display = config.matrix_aliases and config.matrix_aliases[matrix.name] or matrix.name or ("Matrix " .. tostring(idx))
    table.insert(matrices, {
      id = matrix.name,
      name = display,
      stored = stored,
      capacity = capacity,
      percent = capacity > 0 and (stored / capacity) or 0,
      input = input,
      output = output,
      cells = cells,
      providers = providers,
      ports = ports,
      status = degraded and "DEGRADED" or "OK"
    })
  end
  local percent = total.capacity > 0 and (total.stored / total.capacity) or 0
  return {
    matrices = matrices,
    total = {
      stored = total.stored,
      capacity = total.capacity,
      percent = percent,
      input = total.has_flow and total.input or nil,
      output = total.has_flow and total.output or nil
    }
  }
end

local function send_status()
  local energy = read_storage_stats()
  local matrix = read_matrix_stats()
  local total_stored = energy.stored + (matrix.total.stored or 0)
  local total_capacity = energy.capacity + (matrix.total.capacity or 0)
  local total_input = energy.input + (matrix.total.input or 0)
  local total_output = energy.output + (matrix.total.output or 0)
  energy.monitor_bound = devices.monitor ~= nil
  energy.storage_bound_count = #(devices.storages or {})
  energy.bound_storage_names = devices.bound_storage_names or {}
  energy.degraded_reason = devices.degraded_reason
  if devices.degraded_reason then
    energy.status = constants.status_levels.WARNING
  else
    energy.status = constants.status_levels.OK
  end
  energy.matrices = matrix.matrices
  energy.total = matrix.total
  energy.matrix_present = #(matrix.matrices or {}) > 0
  energy.matrix_energy = matrix.total.stored
  energy.matrix_capacity = matrix.total.capacity
  energy.matrix_percent = matrix.total.percent
  energy.matrix_in = matrix.total.input
  energy.matrix_out = matrix.total.output
  energy.storages_count = energy.storage_bound_count
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
  energy.last_scan_ts = devices.last_scan_ts
  energy.last_scan_result = devices.last_scan_result
  energy.last_error = devices.last_error
  energy.last_error_ts = devices.last_error_ts
  energy.peripheral_count = devices.peripheral_count
  network:send(constants.channels.STATUS, protocol.status(network.id, network.role, energy))
  last_heartbeat = os.epoch("utc")
end

local function format_value(value)
  if value == nil then
    return "n/a"
  end
  return string.format("%.0f", value)
end

local function format_energy(value)
  if value == nil then
    return "n/a"
  end
  local suffixes = { "", "k", "M", "G", "T", "P", "E" }
  local v = math.abs(value)
  local idx = 1
  while v >= 1000 and idx < #suffixes do
    v = v / 1000
    idx = idx + 1
  end
  local formatted = v >= 100 and string.format("%.0f", v) or string.format("%.1f", v)
  if value < 0 then
    formatted = "-" .. formatted
  end
  return formatted .. suffixes[idx]
end

local function format_percent(value)
  if value == nil then
    return "n/a"
  end
  return string.format("%.0f%%", value * 100)
end

local function format_age(ts, now)
  if not ts then
    return "n/a"
  end
  return ("%ds"):format(math.max(0, math.floor((now - ts) / 1000)))
end

local function build_pages(matrices, storages, height)
  local pages = {}
  local header_lines = 3
  local footer_lines = 1
  local card_lines = 4
  local total_lines = 4
  local available = math.max(1, height - header_lines - footer_lines - total_lines)
  local per_page = math.max(1, math.floor(available / card_lines))
  local count = #matrices
  local total_pages = math.max(1, math.ceil(count / per_page))
  for page = 1, total_pages do
    table.insert(pages, { type = "matrices", start_index = (page - 1) * per_page + 1, end_index = math.min(count, page * per_page) })
  end
  if #storages > 0 then
    table.insert(pages, { type = "storages" })
  end
  table.insert(pages, { type = "diagnostics" })
  return pages
end

local function update_page(delta)
  local total = #ui_state.pages
  if total == 0 then
    return
  end
  local next_page = ui_state.page + delta
  if next_page < 1 then
    next_page = total
  elseif next_page > total then
    next_page = 1
  end
  if next_page ~= ui_state.page then
    ui_state.page = next_page
    ui_state.last_snapshot = nil
    if debug_enabled then
      utils.log("ENERGY", ("UI page -> %d/%d"):format(ui_state.page, total))
    end
  end
end

local function render_monitor()
  if not devices.monitor then
    return
  end
  local now = os.epoch("utc")
  if now - ui_state.last_draw < config.ui_refresh_interval * 1000 then
    return
  end
  local energy = read_storage_stats()
  local matrix = read_matrix_stats()
  local degraded = devices.degraded_reason ~= nil
  local matrices = matrix.matrices or {}
  local storages = energy.stores or {}
  local model = {
    node_id = network and network.id or config.node_id,
    degraded_reason = devices.degraded_reason,
    last_scan_ts = devices.last_scan_ts,
    scan_result = devices.last_scan_result,
    last_error = devices.last_error,
    last_error_ts = devices.last_error_ts,
    peripheral_count = devices.peripheral_count,
    monitor_bound = devices.monitor ~= nil,
    storages_count = #(devices.storages or {}),
    storages = storages,
    matrices = matrices,
    total = matrix.total
  }
  local snapshot = textutils.serialize(model)
  if ui_state.last_snapshot == snapshot then
    return
  end
  ui_state.last_snapshot = snapshot
  ui_state.last_draw = now

  local mon = devices.monitor
  local w, h = mon.getSize()
  local status = degraded and "WARNING" or "OK"
  ui_state.pages = build_pages(matrices, storages, h)
  local pages = ui_state.pages
  if ui_state.page > #pages then
    ui_state.page = #pages
  end
  local page = pages[ui_state.page] or { type = "matrices", start_index = 1, end_index = 0 }
  ui.panel(mon, 1, 1, w, h, "ENERGY NODE", status)
  ui.text(mon, 2, 2, ("ID: %s"):format(model.node_id or "UNKNOWN"), colors.get("text"), colors.get("background"))
  local status_label = degraded and "DEGRADED" or "OK"
  ui.rightText(mon, 2, 2, w - 2, status_label, colors.get(status), colors.get("background"))

  local line = 4
  if page.type == "matrices" then
    ui.text(mon, 2, line, ("Induction Matrices (%d)"):format(#matrices), colors.get("text"), colors.get("background"))
    line = line + 1
    local start_idx = page.start_index
    local end_idx = page.end_index
    if #matrices == 0 then
      ui.text(mon, 2, line, "No matrices detected", colors.get("WARNING"), colors.get("background"))
      line = line + 2
    else
      for idx = start_idx, end_idx do
        local entry = matrices[idx]
        local pct = entry and entry.percent or 0
        if entry then
          local label = string.format("%s", entry.name or ("Matrix " .. tostring(idx)))
          ui.text(mon, 2, line, label, colors.get("text"), colors.get("background"))
          ui.rightText(mon, 2, line, w - 2, format_percent(pct), colors.get(entry.status == "DEGRADED" and "WARNING" or status), colors.get("background"))
          line = line + 1
          ui.progress(mon, 2, line, w - 4, pct or 0, entry.status == "DEGRADED" and "WARNING" or status)
          line = line + 1
          ui.text(mon, 2, line, ("E: %s / %s"):format(format_energy(entry.stored), format_energy(entry.capacity)), colors.get("text"), colors.get("background"))
          line = line + 1
          local in_text = entry.input and format_energy(entry.input) or "n/a"
          local out_text = entry.output and format_energy(entry.output) or "n/a"
          ui.text(mon, 2, line, ("IN %s  OUT %s"):format(in_text, out_text), colors.get("text"), colors.get("background"))
          line = line + 1
        end
      end
    end
    ui.text(mon, 2, line, ("GESAMT (%d)"):format(#matrices), colors.get("text"), colors.get("background"))
    line = line + 1
    ui.progress(mon, 2, line, w - 4, model.total and model.total.percent or 0, status)
    line = line + 1
    ui.text(mon, 2, line, ("E: %s / %s (%s)"):format(
      format_energy(model.total and model.total.stored),
      format_energy(model.total and model.total.capacity),
      format_percent(model.total and model.total.percent)
    ), colors.get("text"), colors.get("background"))
    line = line + 1
    local total_in = model.total and model.total.input or nil
    local total_out = model.total and model.total.output or nil
    local total_flow = (total_in ~= nil or total_out ~= nil) and ("IN " .. format_energy(total_in) .. "  OUT " .. format_energy(total_out)) or "IN/OUT n/a"
    ui.text(mon, 2, line, total_flow, colors.get("text"), colors.get("background"))
  elseif page.type == "storages" then
    ui.text(mon, 2, line, ("Storages (%d)"):format(model.storages_count or 0), colors.get("text"), colors.get("background"))
    line = line + 1
    local rows = {}
    table.sort(storages, function(a, b) return (a.capacity or 0) > (b.capacity or 0) end)
    for _, s in ipairs(storages) do
      local pct = s.capacity and s.capacity > 0 and (s.stored / s.capacity) or 0
      table.insert(rows, { text = string.format("%s %s", s.id, format_percent(pct)), status = status })
    end
    if #rows == 0 then
      table.insert(rows, { text = "none", status = "WARNING" })
    end
    ui.list(mon, 2, line, w - 2, rows, { max_rows = math.max(1, h - line - 2) })
  else
    local info_rows = {
      { text = ("Peripherals found: %d"):format(model.peripheral_count or 0) },
      { text = ("Monitor bound: %s"):format(model.monitor_bound and "yes" or "no") },
      { text = ("Storages bound: %d"):format(model.storages_count or 0) },
      { text = ("Matrices bound: %d"):format(#matrices) },
      { text = ("Degraded reason: %s"):format(model.degraded_reason or "none") },
      { text = ("Last scan: %s (%s)"):format(model.scan_result or "n/a", format_age(model.last_scan_ts, now)) },
      { text = ("Last error: %s (%s)"):format(model.last_error or "none", format_age(model.last_error_ts, now)) }
    }
    ui.text(mon, 2, line, "Diagnostics", colors.get("text"), colors.get("background"))
    line = line + 1
    ui.list(mon, 2, line, w - 2, info_rows, { max_rows = math.max(1, h - line - 2) })
  end

  local footer = h
  local scan_age = ""
  if model.last_scan_ts then
    scan_age = string.format("scan %ds", math.max(0, math.floor((now - model.last_scan_ts) / 1000)))
  end
  local warning = degraded and ("WARN: " .. tostring(model.degraded_reason)) or ""
  local page_text = ("< Page %d/%d >"):format(ui_state.page, math.max(1, #pages))
  local footer_text = string.format("%s  %s  %s", textutils.formatTime(os.time(), true), scan_age, warning)
  ui.text(mon, 2, footer, footer_text, colors.get("text"), colors.get("background"))
  ui.rightText(mon, 2, footer, w - 2, page_text, colors.get("text"), colors.get("background"))
  local start = 2 + math.max(0, (w - 2) - #page_text)
  ui_state.controls = {
    prev = { x = start, y = footer },
    next = { x = start + #page_text - 1, y = footer }
  }
end

local function handle_monitor_touch(name, x, y)
  if not devices.monitor_name or name ~= devices.monitor_name then
    return
  end
  local controls = ui_state.controls or {}
  if controls.prev and y == controls.prev.y and x == controls.prev.x then
    update_page(-1)
  elseif controls.next and y == controls.next.y and x == controls.next.x then
    update_page(1)
  end
end

local warned = {}
local function warn_once(key, message)
  if warned[key] then return end
  warned[key] = true
  utils.log("ENERGY", message, "WARN")
end

local function main_loop()
  while true do
    if os.epoch("utc") - last_scan > config.scan_interval * 1000 then
      discover()
      last_scan = os.epoch("utc")
    end
    render_monitor()
    if os.epoch("utc") - last_heartbeat > config.heartbeat_interval * 1000 then
      send_status()
    end
    local timer = os.startTimer(CONFIG.RECEIVE_TIMEOUT)
    while true do
      local event = { os.pullEvent() }
      if event[1] == "modem_message" then
        local _, _, _, _, message = table.unpack(event)
        local ok, err = protocol.validateMessage(message)
        if ok then
          local sanitized = protocol.sanitize_message(message)
          if sanitized and sanitized.type == constants.message_types.HELLO then
            -- master seen
          end
        else
          warn_once("schema:" .. tostring(err), "WARN: invalid message ignored (" .. tostring(err) .. ")")
        end
      elseif event[1] == "monitor_touch" then
        handle_monitor_touch(event[2], event[3], event[4])
      elseif event[1] == "key" then
        if event[2] == keys.left then
          update_page(-1)
        elseif event[2] == keys.right then
          update_page(1)
        end
      elseif event[1] == "timer" and event[2] == timer then
        break
      end
    end
  end
end

local function init()
  discover()
  last_scan = os.epoch("utc")
  network = network_lib.init(config)
  hello()
  send_status()
  utils.log("ENERGY", "Node ready: " .. network.id)
end

init()
main_loop()
