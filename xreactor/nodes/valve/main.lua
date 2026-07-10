-- nodes/valve/main.lua
--
-- Minimaler eigenstaendiger Redstone-Valve-Controller.
--
-- Hintergrund (2026-07-09): der "Integrator" an diesem Pipe-Netz ist bei
-- diesem Setup selbst ein CC:Tweaked-Computer -- kein direkt am FUEL-
-- Computer gewrapptes Mekanism-Peripheral. Er sitzt physisch am Ventil,
-- hat KEIN Wired Modem zu FUEL, sondern wird per Wireless Modem ueber
-- einen eigenen, dedizierten Kanal angesprochen (Kommando SET_VALVE,
-- direkt von FUEL gesendet, siehe nodes/fuel/redstone_router.lua). Bewusst extrem
-- schlank gehalten -- kein Monitor, keine Peripherie-Discovery, keine
-- komplexe UI. Registriert sich aber ganz normal per HELLO/Heartbeat wie
-- jeder andere Node, damit FUEL/Master es automatisch als online
-- erkennen (Auto-Discovery ueber die ohnehin vorhandene Peer-Verwaltung,
-- kein separates Protokoll noetig).
--
-- Fail-Safe: bootet mit dem Ventil im konfigurierten default_blocked-
-- Zustand (Standard: blockiert) und faellt bei Verbindungsverlust zu
-- FUEL/Master (kein SET_VALVE-Kommando mehr seit laengerer Zeit) auf
-- diesen sicheren Grundzustand zurueck, statt ein evtl. zuletzt offenes
-- Ventil dauerhaft offen zu lassen.

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

local DEFAULT_CONFIG = {
  role = constants.roles.VALVE_NODE,
  node_id = "VALVE-1",
  debug_logging = false,
  reset_log_on_start = true,
  wireless_modem = nil,
  side = "front",
  default_blocked = true,
  heartbeat_interval = 2,
  status_interval = 5,
  channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
  comms = {
    ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0
  }
}

CONFIG.CONFIG_PATH = role_descriptor.config_path
local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}
local function add_config_warning(message) table.insert(config_warnings, message) end
if type(config.side) ~= "string" or not ({top=1,bottom=1,left=1,right=1,front=1,back=1})[config.side] then
  add_config_warning("side ungueltig/fehlt, verwende 'front'")
  config.side = "front"
end

local node_id = support_runtime.init_logging({
  utils = utils, config = config, runtime_config = CONFIG,
  config_meta = config_meta, config_warnings = config_warnings
})

local valve_health = health.new({})
local last_command_ts = nil
local current_high = config.default_blocked ~= false  -- true = blockiert (Fail-Safe-Default)

local function apply_valve(high)
  current_high = high
  pcall(redstone.setOutput, config.side, high)
  utils.log(CONFIG.LOG_PREFIX, string.format("Ventil (%s) -> %s", config.side, high and "BLOCKIERT" or "OFFEN"), "INFO")
end

-- Fail-Safe-Grundzustand direkt beim Boot setzen, bevor irgendeine
-- Verbindung zu FUEL/Master ueberhaupt steht.
apply_valve(current_high)

-- Feature (2026-07-09): FUEL<->VALVE Ventil-Kommandos laufen ueber einen
-- EIGENEN, dedizierten Kanal (constants.channels.VALVE = 6504) -- explizit
-- getrennt von CONTROL/STATUS/LOG, auf Wunsch komplett unabhaengig von der
-- normalen comms_service-Pipeline (kein Ack/Retry/Dedup-Overhead, roh per
-- modem.transmit/pullEvent fuer minimale Latenz). HELLO/Heartbeat (fuer
-- Auto-Discovery durch FUEL) laufen weiterhin normal ueber comms_service/
-- CONTROL+STATUS wie bei jedem anderen Node -- nur die eigentlichen
-- Ventil-Kommandos sind isoliert.
local valve_modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
if valve_modem then
  local ok_open = pcall(valve_modem.open, constants.channels.VALVE)
  if ok_open then
    utils.log(CONFIG.LOG_PREFIX, "Eigener Ventil-Kanal " .. constants.channels.VALVE .. " geoeffnet", "INFO")
  else
    utils.log(CONFIG.LOG_PREFIX, "Ventil-Kanal " .. constants.channels.VALVE .. " konnte nicht geoeffnet werden", "ERROR")
  end
else
  utils.log(CONFIG.LOG_PREFIX, "Kein Wireless Modem gefunden — Ventil-Kanal inaktiv", "ERROR")
end

local function handle_valve_channel_event(event)
  if event[1] ~= "modem_message" then return end
  local channel, _, message = event[2], event[3], event[4]
  if channel ~= constants.channels.VALVE then return end
  if type(message) ~= "table" or message.type ~= "SET_VALVE" then return end
  if message.dst ~= node_id then return end  -- nicht fuer diese Node bestimmt
  if type(message.high) ~= "boolean" then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE ohne gueltiges 'high' ignoriert", "WARN")
    return
  end
  last_command_ts = os.epoch("utc")
  apply_valve(message.high)
end

local comms = comms_service.new({
  config = config, log_prefix = CONFIG.LOG_PREFIX,
})

local services = service_manager.new()
services:add(comms)
services:add({ name = "valve_channel", tick = function(_self, dt, event)
  if event then handle_valve_channel_event(event) end
end })

-- Fail-Safe: kein SET_VALVE-Kommando seit laengerer Zeit (deutlich mehr
-- als der normale Ventil-Öffnungs-Zyklus) -> zurueck in den blockierten
-- Grundzustand, statt ein moeglicherweise vergessenes offenes Ventil
-- dauerhaft offen zu lassen (z.B. FUEL-Node abgestuerzt mitten im
-- Export).
local STALE_COMMAND_S = 20
services:add({ name = "valve_failsafe", tick = function()
  if last_command_ts and not current_high then
    local age_s = (os.epoch("utc") - last_command_ts) / 1000
    if age_s > STALE_COMMAND_S then
      utils.log(CONFIG.LOG_PREFIX, string.format(
        "Kein SET_VALVE seit %.0fs — Fail-Safe: Ventil wird blockiert", age_s), "WARN")
      apply_valve(true)
    end
  end
end })

local function build_status_payload()
  valve_health.status = comms:is_master_reachable() and health.status.OK or health.status.DEGRADED
  valve_health.reasons = comms:is_master_reachable() and {} or { [health.reasons.COMMS_DOWN] = true }
  valve_health.last_seen_ts = os.epoch("utc")
  return non_rt_payload.build_base({
    ts = os.epoch("utc"), role = config.role, node_id = node_id,
    health = { status = valve_health.status, reasons = health.reasons_list(valve_health), last_seen_ts = valve_health.last_seen_ts },
    master_connected = comms:is_master_reachable(),
    queue = comms and comms:get_diagnostics().queue_depth or 0,
  })
end
services:add(telemetry_service.new({
  comms = comms,
  status_interval = config.status_interval or config.heartbeat_interval,
  heartbeat_interval = config.heartbeat_interval,
  build_payload = build_status_payload,
  heartbeat_state = function() return { side = config.side, blocked = current_high } end,
}))

utils.log(CONFIG.LOG_PREFIX, "VALVE-Node gestartet: side=" .. config.side .. " node_id=" .. tostring(node_id), "INFO")

support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function() end)
