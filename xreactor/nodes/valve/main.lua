-- nodes/valve/main.lua
-- Dedicated wireless controller for one Mekanism Logistical Sorter.

local CONFIG = {
  LOG_NAME = "valve",
  LOG_PREFIX = "VALVE",
  DEBUG_LOG_ENABLED = nil,
  BOOTSTRAP_LOG_ENABLED = false,
  BOOTSTRAP_LOG_PATH = nil,
  NODE_ID_PATH = "/xreactor/config/node_id.txt",
  CONFIG_PATH = nil,
  RECEIVE_TIMEOUT = 0.5,
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({ role = "valve", log_enabled = false, log_path = nil })
local require = bootstrap.require
local constants = require("shared.constants")
local utils = require("core.utils")
local health = require("core.health")
local non_rt_payload = require("core.non_rt_payload")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local telemetry_service = require("services.telemetry_service")
local support_runtime = require("nodes.support.runtime")
local role_descriptor = require("nodes.valve.role_descriptor")
local valve_controller = require("nodes.valve.controller")

local DEFAULT_CONFIG = {
  role = constants.roles.VALVE_NODE,
  node_id = "VALVE-1",
  debug_logging = false,
  reset_log_on_start = true,
  wireless_modem = nil,
  sorter_name = nil,
  default_blocked = true,
  heartbeat_interval = 2,
  status_interval = 5,
  channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
  comms = {
    ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0,
    queue_limit = 200, drop_simulation = 0
  }
}

local VALVE_USER_CONFIG_PATH = "/xreactor/config/valve.lua"
if not fs.exists(VALVE_USER_CONFIG_PATH) and fs.exists(role_descriptor.config_path) then
  local ok_read, handle = pcall(fs.open, role_descriptor.config_path, "r")
  if ok_read and handle then
    local content = handle.readAll()
    handle.close()
    local dir = fs.getDir(VALVE_USER_CONFIG_PATH)
    if dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
    local ok_write, out = pcall(fs.open, VALVE_USER_CONFIG_PATH, "w")
    if ok_write and out then
      out.write(content)
      out.close()
      utils.log(CONFIG.LOG_PREFIX, "Config-Migration: " .. role_descriptor.config_path
        .. " -> " .. VALVE_USER_CONFIG_PATH, "INFO")
    end
  end
end
CONFIG.CONFIG_PATH = VALVE_USER_CONFIG_PATH

local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}
local function add_config_warning(message) table.insert(config_warnings, message) end
if config.sorter_name ~= nil and (type(config.sorter_name) ~= "string" or config.sorter_name == "") then
  add_config_warning("sorter_name ungueltig, wird ignoriert (automatische Suche)")
  config.sorter_name = nil
end

local node_id = support_runtime.init_logging({
  utils = utils, config = config, runtime_config = CONFIG,
  config_meta = config_meta, config_warnings = config_warnings
})

local valve_health = health.new({})
local desired_high = config.default_blocked ~= false
local controller = valve_controller.new({
  config = config,
  config_path = CONFIG.CONFIG_PATH,
  node_id = node_id,
  constants = constants,
  utils = utils,
  log_prefix = CONFIG.LOG_PREFIX,
})

-- Fail-safe write at boot before accepting any network command.
controller:apply_valve(desired_high, true)

local function find_valve_modem()
  local configured = type(config.wireless_modem) == "string" and config.wireless_modem or nil
  if configured and configured ~= "" then
    local present_ok, present = pcall(peripheral.isPresent, configured)
    if present_ok and present then
      local wrap_ok, modem = pcall(peripheral.wrap, configured)
      if wrap_ok and modem and type(modem.isWireless) == "function" then
        local wireless_ok, wireless = pcall(modem.isWireless)
        if wireless_ok and wireless == true then return modem, configured, nil end
      end
    end
    return nil, configured, "konfiguriertes Wireless Modem nicht verfuegbar oder nicht wireless"
  end
  local resolved_name = nil
  local ok_find, modem = pcall(peripheral.find, "modem", function(name, candidate)
    if not candidate or type(candidate.isWireless) ~= "function" then return false end
    local wireless_ok, wireless = pcall(candidate.isWireless)
    if wireless_ok and wireless == true then resolved_name = name; return true end
    return false
  end)
  if ok_find and modem then return modem, resolved_name, nil end
  return nil, nil, "kein Wireless Modem gefunden"
end

local valve_modem, valve_modem_name, valve_modem_error = find_valve_modem()
if valve_modem then
  local ok_open = pcall(valve_modem.open, constants.channels.VALVE)
  if ok_open then
    utils.log(CONFIG.LOG_PREFIX, "Eigener Ventil-Kanal " .. constants.channels.VALVE
      .. " geoeffnet via " .. tostring(valve_modem_name or "auto"), "INFO")
  else
    utils.log(CONFIG.LOG_PREFIX, "Ventil-Kanal " .. constants.channels.VALVE
      .. " konnte nicht geoeffnet werden", "ERROR")
  end
else
  utils.log(CONFIG.LOG_PREFIX, "Ventil-Kanal inaktiv: "
    .. tostring(valve_modem_error or "kein Wireless Modem"), "ERROR")
end

local teach_input_state = false
local function check_teach_input()
  local any_high = false
  local ok, sides = pcall(redstone.getSides)
  if ok and type(sides) == "table" then
    for _, side in ipairs(sides) do
      local input_ok, input = pcall(redstone.getInput, side)
      if input_ok and input then any_high = true; break end
    end
  end
  if any_high and not teach_input_state and valve_modem then
    pcall(valve_modem.transmit, constants.channels.VALVE, constants.channels.VALVE, {
      type = "ROUTE_TEACH_PULSE", src = node_id,
    })
  end
  teach_input_state = any_high
end

local comms = comms_service.new({ config = config, log_prefix = CONFIG.LOG_PREFIX })
local services = service_manager.new()
services:add(comms)
services:add({ name = "valve_channel", wants_events = true, tick = function(_self, dt, event)
  if event then controller:handle_event(event) end
end })

local STALE_COMMAND_S = 20
local FAILSAFE_RETRY_MS = 2000
services:add({ name = "valve_failsafe", tick = function()
  controller:tick_failsafe(STALE_COMMAND_S, FAILSAFE_RETRY_MS)
end })

services:add({ name = "teach_input_poll", tick = function() check_teach_input() end })
services:add({ name = "status_monitor_render", tick = function() controller:render_status_monitor() end })

local function build_status_payload()
  local master_reachable = comms:is_master_reachable()
  local state = controller:get_state()
  local actuator_ready = state.initialized and state.last_write_error == nil
  valve_health.status = (master_reachable and actuator_ready) and health.status.OK or health.status.DEGRADED
  valve_health.reasons = {}
  if not master_reachable then valve_health.reasons[health.reasons.COMMS_DOWN] = true end
  if not actuator_ready then valve_health.reasons[health.reasons.CONTROL_DEGRADED] = true end
  valve_health.last_seen_ts = os.epoch("utc")
  local payload = non_rt_payload.build_base({
    ts = os.epoch("utc"), role = config.role, node_id = node_id,
    health = { status = valve_health.status, reasons = health.reasons_list(valve_health),
      last_seen_ts = valve_health.last_seen_ts },
    master_connected = master_reachable,
    queue = comms and comms:get_diagnostics().queue_depth or 0,
  })
  payload.blocked = state.initialized and state.current_high or nil
  payload.actuator_ready = actuator_ready
  payload.actuator_name = state.sorter_name
  payload.write_error = state.last_write_error
  return payload
end

services:add(telemetry_service.new({
  comms = comms,
  status_interval = config.status_interval or config.heartbeat_interval,
  heartbeat_interval = config.heartbeat_interval,
  build_payload = build_status_payload,
  heartbeat_state = function()
    local state = controller:get_state()
    local confirmed_blocked = state.initialized and state.current_high or nil
    return {
      blocked = confirmed_blocked,
      actuator_initialized = state.initialized,
      actuator_ready = state.initialized and state.last_write_error == nil,
      write_error = state.last_write_error,
      actuator_name = state.sorter_name,
      trusted_source = state.trusted_source,
      pairing_persisted = state.pairing_persisted,
      pairing_error = state.pairing_error,
    }
  end,
}))

services:init()
local initial_state = controller:get_state()
utils.log(CONFIG.LOG_PREFIX,
  "VALVE-Node gestartet: sorter=" .. tostring(initial_state.sorter_name or "auto")
    .. " node_id=" .. tostring(node_id), "INFO")

local quiesce_handshake = _G.__xreactor_update_handshake
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function() end,
  quiesce_handshake and {
    handshake = quiesce_handshake,
    -- Always force a fresh sorter write/readback attempt. current_high is a
    -- cache, not evidence that an externally changed/reset sorter is blocked.
    on_quiesce = function() return controller:apply_valve(true, true) end
  } or nil)
