-- CONFIG
local CONFIG = {
  LOG_NAME = "master", -- Log file name for this role.
  LOG_PREFIX = "MASTER", -- Default log prefix for master events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_master.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt" -- Node ID storage path.
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "master",
  log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED,
  log_path = CONFIG.BOOTSTRAP_LOG_PATH
})
local require = bootstrap.require

_G.turbine_ctrl = type(_G.turbine_ctrl) == "table" and _G.turbine_ctrl or {}

local function ensure_turbine_ctrl(name)
  _G.turbine_ctrl = type(_G.turbine_ctrl) == "table" and _G.turbine_ctrl or {}
  _G.ensure_turbine_ctrl = ensure_turbine_ctrl
  if not name then
    name = "__unknown__"
  end
  local ctrl = _G.turbine_ctrl[name]
  if type(ctrl) ~= "table" then
    ctrl = {}
    _G.turbine_ctrl[name] = ctrl
  end
  if ctrl.mode == nil then
    ctrl.mode = "INIT"
  end
  if ctrl.flow == nil then
    ctrl.flow = 0
  end
  if ctrl.target_flow == nil then
    ctrl.target_flow = 0
  end
  if ctrl.last_rpm == nil then
    ctrl.last_rpm = 0
  end
  if ctrl.last_update == nil then
    ctrl.last_update = os.clock()
  end
  return ctrl
end

_G.ensure_turbine_ctrl = ensure_turbine_ctrl
local constants = require("shared.constants")
local colors = require("shared.colors")
local utils = require("core.utils")
local health = require("core.health")
local sequencer_lib = require("master.startup_sequencer")
local overview_ui = require("master.ui.overview")
local rt_ui = require("master.ui.rt_dashboard")
local energy_ui = require("master.ui.energy")
local resources_ui = require("master.ui.resources")
local alarms_ui = require("master.ui.alarms")
local profiles = require("master.profiles")
local trends_lib = require("core.trends")
local ui = require("core.ui")
local config = require("master.config")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local ui_service = require("services.ui_service")

-- Initialize file logging early to capture startup events.
local node_id = utils.read_node_id(CONFIG.NODE_ID_PATH)
local log_name = utils.build_log_name(CONFIG.LOG_NAME, node_id)
local debug_enabled = config.debug_logging
if CONFIG.DEBUG_LOG_ENABLED ~= nil then
  debug_enabled = CONFIG.DEBUG_LOG_ENABLED
end
utils.init_logger({ log_name = log_name, prefix = CONFIG.LOG_PREFIX, enabled = debug_enabled })
utils.log(CONFIG.LOG_PREFIX, "Startup", "INFO")

local function clamp_interval(value, fallback, min, max)
  local num = tonumber(value)
  if not num or num <= 0 then
    num = fallback
  end
  if min and num < min then
    num = min
  end
  if max and num > max then
    num = max
  end
  return num
end

config.heartbeat_interval = clamp_interval(config.heartbeat_interval, 5, 1, 60)
config.status_interval = clamp_interval(config.status_interval or config.heartbeat_interval, config.heartbeat_interval, 1, 60)
config.rt_default_mode = config.rt_default_mode or "MASTER"
config.rt_setpoints = config.rt_setpoints or {}
config.rt_setpoints.target_rpm = config.rt_setpoints.target_rpm or 900
if config.rt_setpoints.enable_reactors == nil then
  config.rt_setpoints.enable_reactors = true
end
if config.rt_setpoints.enable_turbines == nil then
  config.rt_setpoints.enable_turbines = true
end

local monitor_roles = {
  OVERVIEW = {},
  RT = {},
  ENERGY = {},
  RESOURCES = {},
  ALARMS = {}
}
local monitor_cache = {}
local nodes = {}
local alarms = {}
local power_target = 0
local sequencer
local comms
local services
local last_draw = 0
local monitor_scan_last = 0
local trends = trends_lib.new(600)
local last_trend_sample = 0
local active_profile = "BASELOAD"
local auto_profile = profiles.AUTO_ENABLED or false
local critical_blink_until = 0
local trend_cache = { energy = {}, energy_arrow = "→" }
local warned = {}

local function warn_once(key, message)
  if warned[key] then return end
  warned[key] = true
  utils.log("MASTER", message)
end

local function normalize_setpoints(setpoints)
  local payload = setpoints or {}
  return {
    target_rpm = payload.target_rpm,
    power_target = payload.power_target,
    steam_target = payload.steam_target,
    enable_reactors = payload.enable_reactors,
    enable_turbines = payload.enable_turbines
  }
end

local function build_rt_setpoints()
  return normalize_setpoints({
    target_rpm = config.rt_setpoints.target_rpm,
    power_target = power_target,
    steam_target = config.rt_setpoints.steam_target,
    enable_reactors = config.rt_setpoints.enable_reactors,
    enable_turbines = config.rt_setpoints.enable_turbines
  })
end

local function send_rt_mode(node, mode)
  if not node or not mode then return end
  comms:send_command(utils.normalize_node_id(node.id), {
    target = constants.command_targets.SET_MODE or constants.command_targets.MODE,
    value = mode
  }, { requires_applied = true })
  node.last_mode_request = os.epoch("utc")
  node.desired_mode = mode
end

local function send_rt_setpoints(node, setpoints)
  if not node then return end
  local payload = normalize_setpoints(setpoints)
  comms:send_command(utils.normalize_node_id(node.id), {
    target = constants.command_targets.SET_SETPOINTS or constants.command_targets.POWER_TARGET,
    value = payload
  }, { requires_applied = true })
  node.last_setpoints = payload
  node.last_setpoints_ts = os.epoch("utc")
end

local function discover_monitors()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      table.insert(names, name)
    end
  end
  table.sort(names)
  local monitors = {}
  for _, name in ipairs(names) do
    local mon, err = utils.safe_wrap(name)
    if mon then
      ui.setScale(mon, config.ui_scale_default or 0.5)
      table.insert(monitors, { name = name, mon = mon })
    elseif err then
      utils.log("MASTER", "WARN: monitor wrap failed for " .. tostring(name) .. ": " .. tostring(err))
    end
  end
  return monitors
end

local function assign_roles(monitors)
  for k in pairs(monitor_roles) do monitor_roles[k] = {} end
  if #monitors == 0 then return end
  local map = {
    "OVERVIEW",
    "RT",
    "ENERGY",
    "RESOURCES",
    "ALARMS"
  }
  for idx, entry in ipairs(monitors) do
    local role = map[math.min(idx, #map)] or "OVERVIEW"
    if idx > #map and #monitors >= 5 then role = "OVERVIEW" end
    monitor_roles[role] = monitor_roles[role] or {}
    table.insert(monitor_roles[role], entry)
  end
end

local function refresh_monitors(force)
  local now = os.epoch("utc")
  if not force and now - monitor_scan_last < 5000 then return end
  monitor_scan_last = now
  local monitors = discover_monitors()
  if #monitors == 0 then
    monitors = { { name = "term", mon = term } }
  end
  local signature_parts = {}
  for _, entry in ipairs(monitors) do
    table.insert(signature_parts, entry.name)
  end
  local signature = table.concat(signature_parts, "|")
  if monitor_cache.signature ~= signature or force then
    monitor_cache = { list = monitors, signature = signature }
    assign_roles(monitors)
    for _, roleList in pairs(monitor_roles) do
      for _, entry in ipairs(roleList) do
        ui.clear(entry.mon)
      end
    end
  end
end

local function add_alarm(sender, severity, message)
  table.insert(alarms, 1, {
    sender_id = sender,
    severity = severity,
    message = message,
    timestamp = textutils.formatTime(os.time(), true)
  })
  if #alarms > 50 then table.remove(alarms) end
  if severity == constants.status_levels.EMERGENCY then
    critical_blink_until = os.epoch("utc") + 5000
  end
end

local function set_default_mode(node)
  if not node.desired_mode then
    node.desired_mode = config.rt_default_mode
  end
end

local function same_setpoints(a, b)
  if not a or not b then return false end
  return a.target_rpm == b.target_rpm
    and a.power_target == b.power_target
    and a.steam_target == b.steam_target
    and a.enable_reactors == b.enable_reactors
    and a.enable_turbines == b.enable_turbines
end

local function sync_rt_node(node)
  if not node or node.role ~= constants.roles.RT_NODE then return end
  set_default_mode(node)
  local now = os.epoch("utc")
  if node.desired_mode and node.mode ~= node.desired_mode then
    if not node.last_mode_request or now - node.last_mode_request > 5000 then
      send_rt_mode(node, node.desired_mode)
    end
    return
  end
  if node.mode == "MASTER" then
    local desired = build_rt_setpoints()
    if not node.last_setpoints or not same_setpoints(node.last_setpoints, desired) then
      send_rt_setpoints(node, desired)
    end
  end
end

local function update_node(message)
  if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then
    local mismatch_id = utils.normalize_node_id(message.src)
    if mismatch_id ~= "UNKNOWN" then
      nodes[mismatch_id] = nodes[mismatch_id] or { id = mismatch_id, role = "UNKNOWN" }
      nodes[mismatch_id].health = nodes[mismatch_id].health or health.new({})
      nodes[mismatch_id].health.status = health.status.DEGRADED
      nodes[mismatch_id].health.reasons = { [health.reasons.PROTO_MISMATCH] = true }
      nodes[mismatch_id].status = health.status.DEGRADED
      nodes[mismatch_id].last_seen = os.epoch("utc")
      nodes[mismatch_id].last_seen_str = textutils.formatTime(os.time(), true)
      nodes[mismatch_id].proto_ver = message.payload.proto_ver
    end
    return
  end
  local id = utils.normalize_node_id(message.sender_id)
  local existing = nodes[id]
  nodes[id] = existing or { id = id, role = message.role, status = constants.status_levels.OFFLINE }
  if nodes[id].down_since then
    nodes[id].down_since = nil
    utils.log("MASTER", "Node comms restored: " .. tostring(id))
  end
  if nodes[id].id ~= id then
    nodes[id].id = id
  end
  if message.node_id then
    local normalized = utils.normalize_node_id(message.node_id)
    if normalized ~= "UNKNOWN" then
      nodes[id].node_id = normalized
    end
  end
  nodes[id].last_seen = os.epoch("utc")
  nodes[id].last_seen_str = textutils.formatTime(os.time(), true)
  nodes[id].proto_ver = message.proto_ver
  if message.type == constants.message_types.HELLO or message.type == constants.message_types.REGISTER then
    if nodes[id].status == constants.status_levels.OFFLINE then
      utils.log("MASTER", "Node online: " .. tostring(id))
    end
    nodes[id].status = constants.status_levels.OK
    nodes[id].state = constants.node_states.OFF
    if message.role == constants.roles.RT_NODE then
      sequencer:enqueue(id)
    end
    sync_rt_node(nodes[id])
  elseif message.type == constants.message_types.HEARTBEAT then
    nodes[id].state = message.payload.state
    sync_rt_node(nodes[id])
  elseif message.type == constants.message_types.STATUS then
    local previous_mode = nodes[id].mode
    nodes[id] = utils.merge(nodes[id], message.payload)
    if message.payload.health then
      nodes[id].health = message.payload.health
      nodes[id].status = message.payload.health.status or nodes[id].status
    else
      nodes[id].status = message.payload.status or nodes[id].status
    end
    nodes[id].bindings = message.payload.bindings or nodes[id].bindings
    nodes[id].bindings_summary = message.payload.bindings_summary or nodes[id].bindings_summary
    nodes[id].capabilities = message.payload.capabilities or nodes[id].capabilities
    nodes[id].mode = message.payload.mode or nodes[id].mode
    nodes[id].registry = message.payload.registry or nodes[id].registry
    nodes[id].last_error = message.payload.last_error or nodes[id].last_error
    nodes[id].last_error_ts = message.payload.last_error_ts or nodes[id].last_error_ts
    if previous_mode and nodes[id].mode and previous_mode ~= nodes[id].mode then
      utils.log("MASTER", ("Node %s mode: %s"):format(id, tostring(nodes[id].mode)))
    end
    if sequencer.active and sequencer.active.node_id == id then
      if message.payload.modules then
        local module = message.payload.modules[sequencer.active.module_id]
        if not module then
          utils.log("SEQ", ("WARN: module %s missing from status, waiting"):format(sequencer.active.module_id))
          return
        end
        if module.state == "STABLE" then
          sequencer:notify_stable(id, sequencer.active.module_id, module.state)
        else
          utils.log("SEQ", ("Waiting for module %s, state=%s"):format(sequencer.active.module_id, module.state or "UNKNOWN"))
        end
      elseif nodes[id].state == constants.node_states.RUNNING then
        sequencer:notify_stable(id, sequencer.active.module_id, nodes[id].state)
      end
    end
    sync_rt_node(nodes[id])
  elseif message.type == constants.message_types.ACK_APPLIED then
    local result = message.payload and message.payload.result or {}
    nodes[id].last_command_result = {
      ok = result.ok ~= false,
      error = result.error,
      reason_code = result.reason_code,
      module_id = result.module_id,
      ack_for = message.ack_for,
      at = os.epoch("utc"),
      command_target = result.command_target,
      command_value = result.command_value
    }
    nodes[id].last_command_error = result.ok == false and (result.error or "unknown") or nil
    if result.ok == false then
      utils.log("MASTER", ("Command failed on %s: %s"):format(id, result.error or "unknown"), "WARN")
    end
    sequencer:notify_ack(id, result.module_id)
  elseif message.type == constants.message_types.ALERT then
    add_alarm(id, message.payload.severity, message.payload.message)
  end
end

local function handle_command_timeouts()
  local timeouts = comms:consume_timeouts() or {}
  if #timeouts == 0 then
    return
  end
  for _, entry in ipairs(timeouts) do
    local msg = entry.message or {}
    if msg.type == constants.message_types.COMMAND then
      local node_id = utils.normalize_node_id(msg.dst or (msg.payload and msg.payload.target))
      if node_id ~= "UNKNOWN" then
        nodes[node_id] = nodes[node_id] or { id = node_id, role = "UNKNOWN", status = constants.status_levels.OFFLINE }
        local command = msg.payload and msg.payload.command or {}
        nodes[node_id].last_command_result = {
          ok = false,
          error = "ack timeout",
          reason_code = "ACK_TIMEOUT",
          ack_for = msg.message_id,
          at = os.epoch("utc"),
          command_target = command.target,
          command_value = command.value
        }
        nodes[node_id].last_command_error = "ack timeout"
        utils.log("MASTER", ("Command timeout for %s (%s)"):format(
          tostring(node_id),
          tostring(command.target or "unknown")
        ), "WARN")
      end
    end
  end
end

local function check_timeouts()
  local peers = comms:get_peers() or {}
  local now = os.epoch("utc")
  local timeout_ms = (config.comms and config.comms.peer_timeout_s or config.heartbeat_interval * 4) * 1000
  for _, node in pairs(nodes) do
    local peer = peers[node.id]
    local last_seen = peer and peer.last_seen or node.last_seen
    if peer and peer.age then
      node.last_seen_age = math.floor(peer.age)
    end
    if last_seen and (now - last_seen > timeout_ms) then
      if node.status ~= constants.status_levels.OFFLINE then
        utils.log("MASTER", "Node offline: " .. tostring(node.id))
      end
      if not node.down_since then
        node.down_since = now
      end
      node.status = health.status.DOWN
      node.health = node.health or health.new({})
      node.health.status = health.status.DOWN
      node.health.reasons = { [health.reasons.COMMS_DOWN] = true }
    elseif node.health and node.health.reasons then
      node.health.reasons[health.reasons.COMMS_DOWN] = nil
      node.down_since = nil
    end
  end
end

local function estimate_base_power()
  local total = 0
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      total = total + (node.output or 0)
    end
  end
  if total > 0 then return total end
  if power_target > 0 then return power_target end
  return 0
end

local function apply_profile(name)
  local profile = profiles[name]
  if not profile then return end
  active_profile = name
  sequencer.ramp_profile = profile.ramp or sequencer.ramp_profile
  local base = estimate_base_power()
  if base > 0 then
    power_target = base * profile.target
    for _, node in pairs(nodes) do
      if node.role == constants.roles.RT_NODE then
        if node.mode == "MASTER" then
          send_rt_setpoints(node, build_rt_setpoints())
        else
          comms:send_command(node.id, {
            target = constants.command_targets.POWER_TARGET,
            value = power_target
          }, { requires_applied = true })
        end
      end
    end
  end
end

local function sample_trends()
  local now = os.epoch("utc")
  if now - last_trend_sample < 1000 then return end
  last_trend_sample = now
  local power = 0
  local stored, capacity = 0, 0
  local water_total = 0
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      power = power + (node.output or 0)
    elseif node.role == constants.roles.ENERGY_NODE then
      stored = stored + (node.stored or 0)
      capacity = capacity + (node.capacity or 0)
    elseif node.role == constants.roles.WATER_NODE then
      water_total = node.total_water or water_total
    end
  end
  local energy_pct = capacity > 0 and (stored / capacity) * 100 or 0
  trends:push("power", power)
  if trends:push("energy", energy_pct) then
    local trend_values = trends:values("energy")
    trend_cache.energy = trend_values
    if #trend_values >= 2 then
      local last = trend_values[#trend_values]
      local prev = trend_values[#trend_values - 1]
      if last > prev + 0.5 then
        trend_cache.energy_arrow = "↑"
      elseif last < prev - 0.5 then
        trend_cache.energy_arrow = "↓"
      else
        trend_cache.energy_arrow = "→"
      end
    else
      trend_cache.energy_arrow = "→"
    end
  end
  trends:push("water", water_total)

  if auto_profile then
    if energy_pct > 90 and active_profile ~= "IDLE" then
      apply_profile("IDLE")
    elseif energy_pct < 30 and active_profile ~= "PEAK" then
      apply_profile("PEAK")
    end
  end
end

local function compute_system_status()
  local status = constants.status_levels.OK
  for _, node in pairs(nodes) do
    if node.status == constants.status_levels.EMERGENCY then
      return constants.status_levels.EMERGENCY
    elseif node.status == constants.status_levels.LIMITED then
      status = constants.status_levels.LIMITED
    elseif node.status == constants.status_levels.WARNING then
      status = constants.status_levels.WARNING
    end
  end
  for _, alarm in ipairs(alarms) do
    if alarm.severity == constants.status_levels.EMERGENCY then
      return constants.status_levels.EMERGENCY
    elseif alarm.severity == constants.status_levels.WARNING then
      status = constants.status_levels.WARNING
    end
  end
  return status
end

local function draw()
  local now = os.epoch("utc")
  if now - last_draw < 400 then return end
  last_draw = now
  local overview_data = {
    nodes = {},
    power_target = power_target,
    alarms = alarms,
    tiles = {},
    system_status = compute_system_status(),
    profile_list = { "BASELOAD", "PEAK", "IDLE" },
    active_profile = active_profile,
    auto_profile = auto_profile
  }
  local rt_data = { rt_nodes = {}, ramp_profile = sequencer.ramp_profile, sequence_state = sequencer.state, queue = sequencer.queue, active_step = sequencer.active }
  local energy_data = { stored = 0, capacity = 0, input = 0, output = 0, stores = {}, nodes = {}, trend_values = trend_cache.energy, trend_arrow = trend_cache.energy_arrow, trend_dirty = trends:is_dirty("energy"), now_ms = os.epoch("utc") }
  local resource_data = { fuel = { reserve = 0, minimum = 0, sources = {}, total = 0 }, water = { total = 0, buffers = {}, target = nil }, reprocessor = {}, node_details = {}, comms = comms:get_diagnostics() or {} }

  for _, node in pairs(nodes) do
    local reasons = node.health and node.health.reasons or {}
    local reason_list = type(reasons) == "table" and (#reasons > 0 and reasons or health.reasons_list({ reasons = reasons })) or {}
    local reason_text = type(reason_list) == "table" and table.concat(reason_list, ",") or nil
    local bindings_summary = node.bindings_summary
    if not bindings_summary and node.health and type(node.health.bindings) == "table" then
      bindings_summary = health.summarize_bindings(node.health.bindings)
    end
    local age = node.last_seen_age or (node.last_seen and math.max(0, math.floor((os.epoch("utc") - node.last_seen) / 1000)) or nil)
    table.insert(overview_data.nodes, {
      id = node.id,
      role = node.role,
      status = node.status or constants.status_levels.OFFLINE,
      last_seen = node.last_seen_str,
      last_seen_age = age,
      mode = node.mode,
      reasons = reason_text,
      bindings = bindings_summary
    })
    table.insert(resource_data.node_details, {
      id = node.id,
      role = node.role,
      status = node.status or constants.status_levels.OFFLINE,
      reasons = reason_text,
      bindings = bindings_summary,
      last_seen_age = age,
      down_since = node.down_since,
      registry = node.registry,
      last_error = node.last_error,
      last_error_ts = node.last_error_ts,
      last_command_result = node.last_command_result,
      last_command_error = node.last_command_error
    })
    if node.role == constants.roles.RT_NODE then
      table.insert(rt_data.rt_nodes, { id = node.id, state = node.state or constants.node_states.OFF, output = node.output, modules = node.modules or {}, limits = node.limits, status = node.status })
    elseif node.role == constants.roles.ENERGY_NODE then
      energy_data.stored = energy_data.stored + (node.stored or 0)
      energy_data.capacity = energy_data.capacity + (node.capacity or 0)
      energy_data.input = energy_data.input + (node.input or 0)
      energy_data.output = energy_data.output + (node.output or 0)
      table.insert(energy_data.stores, { id = node.id, stored = node.stored, capacity = node.capacity, input = node.input, output = node.output })
      table.insert(energy_data.nodes, {
        id = node.id,
        monitor_bound = node.monitor_bound,
        storage_bound_count = node.storage_bound_count,
        bound_storage_names = node.bound_storage_names,
        degraded_reason = node.health and node.health.reasons and table.concat(node.health.reasons, ",") or node.degraded_reason,
        last_scan_ts = node.last_scan_ts,
        last_scan_result = node.last_scan_result,
        status = node.status,
        bindings_summary = node.bindings_summary,
        registry = node.registry
      })
    elseif node.role == constants.roles.FUEL_NODE then
      resource_data.fuel.reserve = node.reserve or resource_data.fuel.reserve
      resource_data.fuel.minimum = node.minimum_reserve or resource_data.fuel.minimum
      resource_data.fuel.sources = node.sources or resource_data.fuel.sources
    elseif node.role == constants.roles.WATER_NODE then
      resource_data.water.total = node.total_water or resource_data.water.total
      resource_data.water.buffers = node.buffers or resource_data.water.buffers
      resource_data.water.state = node.state
    elseif node.role == constants.roles.REPROCESSOR_NODE then
      resource_data.reprocessor = node.reprocessor or {}
    end
  end

  table.sort(rt_data.rt_nodes, function(a, b) return (a.id or "") < (b.id or "") end)
  table.sort(energy_data.stores, function(a, b) return (a.id or "") < (b.id or "") end)
  table.sort(energy_data.nodes, function(a, b) return (a.id or "") < (b.id or "") end)
  table.sort(resource_data.fuel.sources, function(a, b) return (a.id or "") < (b.id or "") end)

  local fuel_total = 0
  for _, src in ipairs(resource_data.fuel.sources or {}) do
    fuel_total = fuel_total + (src.amount or 0)
  end
  resource_data.fuel.total = fuel_total
  resource_data.fuel.mix_status = (#(resource_data.fuel.sources or {}) > 1) and "MIXED" or "SINGLE"
  energy_data.status = energy_data.capacity > 0 and (energy_data.stored / energy_data.capacity < 0.2 and "WARNING" or "OK") or "OFFLINE"
  local tile_map = {
    { label = "RT", role = constants.roles.RT_NODE },
    { label = "ENERGY", role = constants.roles.ENERGY_NODE },
    { label = "FUEL", role = constants.roles.FUEL_NODE },
    { label = "WATER", role = constants.roles.WATER_NODE },
    { label = "REPROCESSOR", role = constants.roles.REPROCESSOR_NODE }
  }
  local status_rank = {
    [constants.status_levels.EMERGENCY] = 1,
    [constants.status_levels.WARNING] = 2,
    [constants.status_levels.LIMITED] = 3,
    [constants.status_levels.OK] = 4,
    [constants.status_levels.OFFLINE] = 5,
    [constants.status_levels.MANUAL] = 6
  }
  for _, entry in ipairs(tile_map) do
    local tile_status = constants.status_levels.OFFLINE
    for _, node in pairs(nodes) do
      if node.role == entry.role then
        local node_status = node.status or constants.status_levels.OFFLINE
        if (status_rank[node_status] or 99) < (status_rank[tile_status] or 99) then
          tile_status = node_status
        end
      end
    end
    table.insert(overview_data.tiles, { label = entry.label, status = tile_status, detail = entry.role })
  end

  local function render(role, drawer, model)
    local rendered = false
    for _, entry in ipairs(monitor_roles[role] or {}) do
      drawer.render(entry.mon, model)
      rendered = true
    end
    return rendered
  end

  render("OVERVIEW", overview_ui, overview_data)
  render("RT", rt_ui, rt_data)
  local energy_rendered = render("ENERGY", energy_ui, energy_data)
  render("RESOURCES", resources_ui, resource_data)
  render("ALARMS", alarms_ui, { alarms = alarms, header_blink = os.epoch("utc") < critical_blink_until and math.floor(os.epoch("utc") / 400) % 2 == 0 })
  if energy_rendered and trends:is_dirty("energy") then
    trends:clear_dirty("energy")
  end
end

local function init()
  refresh_monitors(true)
  comms = comms_service.new({
    config = config,
    log_prefix = "MASTER",
    on_message = update_node
  })
  services = service_manager.new({ log_prefix = "MASTER" })
  services:add(comms)
  services:add(ui_service.new({
    interval = 0.5,
    render = function()
      refresh_monitors(false)
      handle_command_timeouts()
      sequencer:tick(nodes)
      check_timeouts()
      sample_trends()
      draw()
    end,
    handle_input = function(event)
      if event[1] == "monitor_touch" then
        handle_monitor_touch(event[2], event[3], event[4])
      end
    end
  }))
  services:init()
  sequencer = sequencer_lib.new(comms, config.startup_ramp)
  comms:send_hello({ monitors = monitor_cache.list and #monitor_cache.list or 0 })
  utils.log("MASTER", "Initialized as " .. comms.network.id)
end

local function handle_monitor_touch(name, x, y)
  for _, entry in ipairs(monitor_roles.OVERVIEW or {}) do
    if entry.name == name then
      local hit = overview_ui.hit_test(entry.mon, x, y)
      if hit then
        if hit.type == "profile" then
          apply_profile(hit.name)
        elseif hit.type == "auto" then
          auto_profile = not auto_profile
        end
      end
      return
    end
  end
end

local function main_loop()
  while true do
    local timer = os.startTimer(0.5)
    while true do
      local event = { os.pullEvent() }
      if event[1] == "modem_message" then
        comms:handle_event(event)
      elseif event[1] == "monitor_touch" then
        services:tick(nil, event)
      elseif event[1] == "timer" and event[2] == timer then
        break
      end
    end
    services:tick()
  end
end

init()
main_loop()
