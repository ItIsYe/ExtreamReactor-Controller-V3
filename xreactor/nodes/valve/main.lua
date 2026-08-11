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
local protocol = require("core.protocol")
local utils = require("core.utils")
local health = require("core.health")
local non_rt_payload = require("core.non_rt_payload")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local telemetry_service = require("services.telemetry_service")
local support_runtime = require("nodes.support.runtime")
local role_descriptor = require("nodes.valve.role_descriptor")

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
local valve_auth_secret = protocol.resolve_auth_secret(config.comms or config)
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
local last_command_ts = os.epoch("utc")
local desired_high = config.default_blocked ~= false
local current_high = nil
local last_write_error = nil
local valve_initialized = false

local sorter_device = nil
local sorter_resolved_name = nil

local function find_sorter_by_capability()
  for _, name in ipairs(peripheral.getNames() or {}) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and type(methods) == "table" then
      local set = {}
      for _, method in ipairs(methods) do set[method] = true end
      if set.setAutoMode then return name end
    end
  end
  return nil
end

local function get_sorter()
  if sorter_device then return sorter_device end
  local name = config.sorter_name
  if name == nil then
    name = find_sorter_by_capability()
    if not name then return nil end
  end
  local ok, dev = pcall(peripheral.wrap, name)
  if ok and dev then
    sorter_device = dev
    sorter_resolved_name = name
  end
  return sorter_device
end

local AUTO_MODE_READERS = { "getAutoMode", "isAutoMode", "getAutoEject", "isAutoEject" }

local function read_sorter_auto_mode(sorter)
  local found_reader = false
  local last_error = nil
  for _, method in ipairs(AUTO_MODE_READERS) do
    if type(sorter and sorter[method]) == "function" then
      found_reader = true
      local ok, value = pcall(sorter[method])
      if ok and type(value) == "boolean" then return value, method end
      last_error = ok and ("non-boolean readback from " .. method) or tostring(value)
    end
  end
  if found_reader then return nil, nil, last_error or "auto-mode readback failed" end
  return nil, nil, "readback_unavailable"
end

local function write_actuator(high)
  local sorter = get_sorter()
  if not sorter then
    local label = config.sorter_name and ("'" .. tostring(config.sorter_name) .. "'")
      or "automatische Suche erfolglos"
    return false, "Sorter nicht gefunden (" .. label .. ")"
  end

  -- high=true means BLOCKED, so automatic ejection must be disabled.
  local desired_auto = not high
  local ok, result = pcall(sorter.setAutoMode, desired_auto)
  if not ok or result == false then
    sorter_device = nil
    return false, ok and "setAutoMode returned false" or tostring(result)
  end

  -- Some sorter integrations expose a boolean getter and some expose only
  -- the setter. If a getter exists it becomes mandatory proof; if no getter
  -- exists, a fresh successful forced write is the strongest available
  -- physical confirmation. Crucially, RAM cache alone is never proof.
  local auto_mode, reader, read_err = read_sorter_auto_mode(sorter)
  if reader ~= nil then
    if auto_mode ~= desired_auto then
      return false, "Sorter readback mismatch via " .. tostring(reader)
        .. " expected_auto=" .. tostring(desired_auto)
        .. " actual_auto=" .. tostring(auto_mode)
    end
  elseif read_err ~= "readback_unavailable" then
    return false, tostring(read_err)
  end
  return true, nil, reader or "write-confirmed"
end

local status_monitor = nil
local status_monitor_last_color = nil

local function get_status_monitor()
  if status_monitor then return status_monitor end
  local ok, mon = pcall(peripheral.find, "monitor")
  if ok and mon then status_monitor = mon end
  return status_monitor
end

local function render_status_monitor()
  local mon = get_status_monitor()
  if not mon then return end
  local color
  if not valve_initialized or last_write_error then color = colors.orange
  else color = current_high and colors.red or colors.green end
  if status_monitor_last_color == color then return end
  local ok = pcall(function()
    mon.setBackgroundColor(color)
    mon.clear()
  end)
  if ok then status_monitor_last_color = color
  else status_monitor = nil; status_monitor_last_color = nil end
end

local function apply_valve(high, force_physical)
  if not force_physical and valve_initialized and high == current_high then
    last_write_error = nil
    last_command_ts = os.epoch("utc")
    render_status_monitor()
    return true
  end

  local ok, err, proof = write_actuator(high)
  if not ok then
    last_write_error = tostring(err)
    render_status_monitor()
    utils.log(CONFIG.LOG_PREFIX,
      "Ventil-Write fehlgeschlagen (Sorter "
        .. tostring(sorter_resolved_name or config.sorter_name or "?") .. "): " .. tostring(err), "ERROR")
    return false
  end

  current_high = high
  valve_initialized = true
  last_write_error = nil
  last_command_ts = os.epoch("utc")
  render_status_monitor()
  utils.log(CONFIG.LOG_PREFIX,
    string.format("Ventil (Sorter %s) -> %s proof=%s",
      tostring(sorter_resolved_name or config.sorter_name or "?"),
      high and "BLOCKIERT" or "OFFEN", tostring(proof or "write")), "INFO")
  return true
end

-- Fail-safe write at boot before accepting any network command.
apply_valve(desired_high, true)

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

local SEEN_COMMAND_LIMIT = 16
local VALVE_REPLAY_PATH = "/xreactor/state/valve_command_replay.lua"
local seen_command_ids = {}
local seen_command_order = {}
local pairing_persisted = config.trusted_source ~= nil
local last_pairing_error = nil
local valve_highwater = utils.load_config(VALVE_REPLAY_PATH, {})
if type(valve_highwater) ~= "table" then valve_highwater = {} end

local function seen_command(id)
  return id ~= nil and seen_command_ids[id] == true
end

local function remember_command(id)
  if id == nil or seen_command_ids[id] then return end
  seen_command_ids[id] = true
  seen_command_order[#seen_command_order + 1] = id
  while #seen_command_order > SEEN_COMMAND_LIMIT do
    local old = table.remove(seen_command_order, 1)
    if old then seen_command_ids[old] = nil end
  end
end

local function send_valve_ack(reply_side, command_id, applied, high, err, dst, persisted)
  if not command_id or not reply_side then return end
  local ok, modem = pcall(peripheral.wrap, reply_side)
  if not ok or not modem or type(modem.transmit) ~= "function" then return end
  if not valve_auth_secret then return end
  local message = {
    type = "VALVE_ACK", command_id = command_id, applied = applied == true,
    high = high, error = err, src = node_id, dst = dst, persisted = persisted,
    ts = os.epoch and os.epoch("utc") or 0,
  }
  local mac = protocol.sign_value(protocol.valve_auth_value(message), valve_auth_secret)
  if not mac then return end
  message.auth = { algorithm = "HMAC-SHA256", mac = mac }
  pcall(modem.transmit, constants.channels.VALVE, constants.channels.VALVE, message)
end

local function handle_valve_channel_event(event)
  if event[1] ~= "modem_message" then return end
  local reply_side, channel, message = event[2], event[3], event[5]
  if channel ~= constants.channels.VALVE then return end
  if type(message) ~= "table" or message.type ~= "SET_VALVE" then return end
  if message.dst ~= node_id then return end
  if type(message.src) ~= "string" or message.src == "" then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE ohne gueltige 'src' ignoriert", "WARN")
    return
  end
  if type(message.command_id) ~= "string" or message.command_id == "" then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE ohne gueltige 'command_id' ignoriert", "WARN")
    return
  end
  if type(message.high) ~= "boolean" then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE ohne gueltiges 'high' ignoriert", "WARN")
    return
  end
  if not valve_auth_secret then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE verweigert: gemeinsames Netzwerk-Secret fehlt", "ERROR")
    return
  end
  local auth = message.auth
  local authenticated = type(auth) == "table" and auth.algorithm == "HMAC-SHA256"
    and protocol.verify_value(protocol.valve_auth_value(message), valve_auth_secret, auth.mac)
  local now = os.epoch and os.epoch("utc") or 0
  if not authenticated or type(message.ts) ~= "number" or math.abs(now - message.ts) > 30000 then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE unauthentisiert oder veraltet -- ignoriert", "WARN")
    return
  end
  if config.trusted_source and message.src ~= config.trusted_source then
    utils.log(CONFIG.LOG_PREFIX,
      "SET_VALVE von nicht vertrauenswuerdiger Quelle ignoriert: " .. tostring(message.src), "WARN")
    return
  end

  -- A retry is deduped at the transaction layer, but it still has to prove
  -- the physical state. The sorter may have been changed/reset externally
  -- since the original command, so a cached state is not sufficient for ACK.
  if config.trusted_source and seen_command(message.command_id) then
    local applied = apply_valve(message.high, true)
    send_valve_ack(reply_side, message.command_id, applied, current_high, last_write_error,
      message.src, pairing_persisted)
    return
  end

  local previous_record = valve_highwater[message.src]
  local previous_ts = type(previous_record) == "table"
    and tonumber(previous_record.ts) or tonumber(previous_record)
  local same_transaction = type(previous_record) == "table"
    and previous_record.command_id == message.command_id

  -- A persisted transaction may legitimately be retried after an actuator
  -- or pairing write failed. Re-applying the same authenticated desired state
  -- is idempotent; accepting a different command at an old timestamp is not.
  if previous_ts and message.ts <= previous_ts and not same_transaction then
    send_valve_ack(reply_side, message.command_id, false, current_high,
      "REPLAYED_VALVE_COMMAND", message.src, pairing_persisted)
    return
  end
  if not same_transaction or (previous_ts and message.ts > previous_ts) then
    local updated_highwater = {}
    for source, timestamp in pairs(valve_highwater) do updated_highwater[source] = timestamp end
    updated_highwater[message.src] = { ts = message.ts, command_id = message.command_id }
    local replay_saved, replay_err = utils.write_config(VALVE_REPLAY_PATH, updated_highwater)
    if not replay_saved then
      utils.log(CONFIG.LOG_PREFIX, "SET_VALVE Replay-Schutz nicht persistierbar: " .. tostring(replay_err), "ERROR")
      send_valve_ack(reply_side, message.command_id, false, current_high,
        "REPLAY_STATE_PERSIST_FAILED", message.src, pairing_persisted)
      return
    end
    valve_highwater = updated_highwater
  end

  -- Every newly accepted transaction must freshly prove the physical sorter
  -- state before VALVE_ACK can be used as a routing gate.  A matching RAM
  -- cache only describes the last successful write; the sorter may have been
  -- changed or reset externally since then.
  local applied = apply_valve(message.high, true)
  if not applied then
    send_valve_ack(reply_side, message.command_id, false, current_high, last_write_error,
      message.src, config.trusted_source ~= nil and pairing_persisted or false)
    return
  end

  if not config.trusted_source then
    config.trusted_source = message.src
    local ok_pair, pair_err = utils.write_config(CONFIG.CONFIG_PATH, config)
    if not ok_pair then
      config.trusted_source = nil
      pairing_persisted = false
      last_pairing_error = tostring(pair_err or "write_config failed")
      local blocked_ok = apply_valve(true, true)
      utils.log(CONFIG.LOG_PREFIX,
        "trusted_source-Pairing NICHT dauerhaft gespeichert (" .. last_pairing_error
          .. ") -- Fail-Safe BLOCKED=" .. tostring(blocked_ok), "ERROR")
      send_valve_ack(reply_side, message.command_id, false, current_high,
        "PAIRING_PERSIST_FAILED:" .. last_pairing_error, message.src, false)
      return
    end
    pairing_persisted = true
    last_pairing_error = nil
    utils.log(CONFIG.LOG_PREFIX,
      "trusted_source nach erfolgreichem Apply dauerhaft an " .. tostring(message.src) .. " gebunden", "INFO")
  end

  remember_command(message.command_id)
  send_valve_ack(reply_side, message.command_id, true, current_high, nil,
    message.src, pairing_persisted)
end

local comms = comms_service.new({ config = config, log_prefix = CONFIG.LOG_PREFIX })
local services = service_manager.new()
services:add(comms)
services:add({ name = "valve_channel", wants_events = true, tick = function(_self, dt, event)
  if event then handle_valve_channel_event(event) end
end })

local STALE_COMMAND_S = 20
local FAILSAFE_RETRY_MS = 2000
local last_failsafe_attempt_ts = 0
services:add({ name = "valve_failsafe", tick = function()
  local now_ms = os.epoch("utc")
  local age_s = last_command_ts and ((now_ms - last_command_ts) / 1000) or math.huge
  local stale = age_s > STALE_COMMAND_S
  local uncertain = not valve_initialized or last_write_error ~= nil
  if (uncertain or stale) and (now_ms - last_failsafe_attempt_ts) >= FAILSAFE_RETRY_MS then
    last_failsafe_attempt_ts = now_ms
    if uncertain then
      utils.log(CONFIG.LOG_PREFIX,
        "Aktorzustand unbestaetigt -- Fail-Safe schreibt BLOCKIERT physisch erneut", "WARN")
    else
      utils.log(CONFIG.LOG_PREFIX,
        string.format("Kein SET_VALVE seit %.0fs -- Fail-Safe bestaetigt BLOCKIERT physisch erneut", age_s), "WARN")
    end
    apply_valve(true, true)
  end
end })

services:add({ name = "teach_input_poll", tick = function() check_teach_input() end })
services:add({ name = "status_monitor_render", tick = function() render_status_monitor() end })

local function build_status_payload()
  local master_reachable = comms:is_master_reachable()
  local actuator_ready = valve_initialized and last_write_error == nil
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
  payload.blocked = valve_initialized and current_high or nil
  payload.actuator_ready = actuator_ready
  payload.actuator_name = sorter_resolved_name or config.sorter_name
  payload.write_error = last_write_error
  return payload
end

services:add(telemetry_service.new({
  comms = comms,
  status_interval = config.status_interval or config.heartbeat_interval,
  heartbeat_interval = config.heartbeat_interval,
  build_payload = build_status_payload,
  heartbeat_state = function()
    local confirmed_blocked = nil
    if valve_initialized then confirmed_blocked = current_high end
    return {
      blocked = confirmed_blocked,
      actuator_initialized = valve_initialized,
      actuator_ready = valve_initialized and last_write_error == nil,
      write_error = last_write_error,
      actuator_name = sorter_resolved_name or config.sorter_name,
      trusted_source = config.trusted_source,
      pairing_persisted = pairing_persisted,
      pairing_error = last_pairing_error,
    }
  end,
}))

services:init()
utils.log(CONFIG.LOG_PREFIX,
  "VALVE-Node gestartet: sorter=" .. tostring(sorter_resolved_name or config.sorter_name or "auto")
    .. " node_id=" .. tostring(node_id), "INFO")

local quiesce_handshake = _G.__xreactor_update_handshake
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function() end,
  quiesce_handshake and {
    handshake = quiesce_handshake,
    -- Always force a fresh sorter write/readback attempt. current_high is a
    -- cache, not evidence that an externally changed/reset sorter is blocked.
    on_quiesce = function() return apply_valve(true, true) end
  } or nil)
