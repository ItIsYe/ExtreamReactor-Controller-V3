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

-- Fix (2026-07-13): CRITICAL (GLOBAL-P0, siehe docs/CODING_AI_OTHER_
-- NODES_PERFORMANCE_2026-07-12.md). Wie bei FUEL bereits behoben: die
-- Quelldatei ist Teil des Manifests und wird bei jedem Auto-Update
-- ueberschrieben -- jede manuelle Config-Bearbeitung (z.B. die
-- konfigurierte Redstone-Seite) ging dadurch spaetestens beim naechsten
-- Update-Zyklus verloren.
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
      utils.log(CONFIG.LOG_PREFIX or "VALVE", "Config-Migration: " .. role_descriptor.config_path .. " -> " .. VALVE_USER_CONFIG_PATH, "INFO")
    end
  end
end
CONFIG.CONFIG_PATH = VALVE_USER_CONFIG_PATH
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

local last_write_error = nil
local valve_initialized = false

-- Fix (2026-07-13): VALVE-P0.2 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md). current_high wurde bisher VOR dem
-- eigentlichen redstone.setOutput()-Aufruf gesetzt, dessen Ergebnis
-- komplett ignoriert. Heartbeat/Status konnten dadurch "blocked=true/
-- false" melden, obwohl der physische Schreibvorgang fehlgeschlagen war
-- (z.B. Redstone-Peripherie kurzzeitig nicht ansprechbar). Jetzt: State
-- wird erst NACH erfolgreichem Write geaendert, ein Fehler wird in
-- last_write_error festgehalten (fuer Telemetrie/Diagnose), identische
-- Ziel-Zustaende werden nicht erneut geschrieben (kein unnoetiger
-- Redstone-Traffic) -- last_command_ts wird aber TROTZDEM aktualisiert,
-- damit der Fail-Safe-Timeout (siehe unten) korrekt weiss, dass gerade
-- ein gueltiges Kommando eingetroffen ist, auch wenn es keine Aenderung
-- war. valve_initialized stellt sicher, dass der PFLICHT-Boot-Write
-- (siehe apply_valve(current_high) weiter unten, noch bevor irgendeine
-- Verbindung steht) NICHT durch die Dedup-Pruefung uebersprungen wird,
-- nur weil der Zielwert zufaellig mit dem bereits gesetzten Default
-- uebereinstimmt -- ohne diesen expliziten Flag haette der allererste
-- Aufruf faelschlich als "schon im Zielzustand" gegolten und den
-- physischen Write nie ausgefuehrt.
local function apply_valve(high)
  last_command_ts = os.epoch("utc")
  if valve_initialized and high == current_high then
    return true  -- bereits im Zielzustand, kein erneuter Write noetig
  end
  local ok, err = pcall(redstone.setOutput, config.side, high)
  if not ok then
    last_write_error = tostring(err)
    utils.log(CONFIG.LOG_PREFIX, "Ventil-Write fehlgeschlagen (" .. config.side .. "): " .. tostring(err), "ERROR")
    return false
  end
  current_high = high
  valve_initialized = true
  last_write_error = nil
  utils.log(CONFIG.LOG_PREFIX, string.format("Ventil (%s) -> %s", config.side, high and "BLOCKIERT" or "OFFEN"), "INFO")
  return true
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

-- Feature (2026-07-13): VALVE-P1 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md). Kleiner Dedupe-Ringpuffer fuer bereits
-- verarbeitete command_id -- ein per Retry erneut gesendetes (identisches)
-- Kommando loest keinen zweiten Redstone-Write und keinen zweiten Log-
-- Eintrag mehr aus, wird aber trotzdem erneut bestaetigt (falls das
-- vorherige ACK selbst verloren ging -- genau dafuer ist Dedupe UND
-- weiterhin-Acken beide noetig).
local SEEN_COMMAND_LIMIT = 16
local seen_command_ids = {}
local seen_command_order = {}
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

local function send_valve_ack(reply_side, command_id, applied, high, err)
  if not command_id or not reply_side then return end
  local ok, modem = pcall(peripheral.wrap, reply_side)
  if not ok or not modem or type(modem.transmit) ~= "function" then return end
  pcall(modem.transmit, constants.channels.VALVE, constants.channels.VALVE, {
    type = "VALVE_ACK", command_id = command_id, applied = applied == true, high = high, error = err,
  })
end

local function handle_valve_channel_event(event)
  if event[1] ~= "modem_message" then return end
  -- Fix (2026-07-13): CRITICAL (VALVE-P0, siehe docs/CODING_AI_OTHER_
  -- NODES_PERFORMANCE_2026-07-12.md). Standard-CC:Tweaked modem_message-
  -- Event: event[2]=side, event[3]=channel, event[4]=replyChannel,
  -- event[5]=message, event[6]=distance. Vorher wurde event[2] (side,
  -- ein STRING wie "left") als Kanal gelesen und mit constants.channels.
  -- VALVE (einer ZAHL) verglichen -- dieser Vergleich ist strukturell
  -- IMMER falsch (String kann nie einer Zahl gleichen), die Funktion
  -- brach dadurch bei JEDEM modem_message sofort ab, noch bevor die
  -- eigentliche Nachricht (die faelschlich aus event[4]/replyChannel
  -- statt event[5] gelesen worden waere) je ausgewertet wurde. VALVE-
  -- Nodes konnten dadurch seit Einfuehrung dieser Rolle KEIN einziges
  -- SET_VALVE-Kommando empfangen -- der 20s-Fail-Safe-Fallback (siehe
  -- unten) griff dadurch dauerhaft, nicht nur bei echtem Verbindungsverlust.
  local reply_side, channel, message = event[2], event[3], event[5]
  if channel ~= constants.channels.VALVE then return end
  if type(message) ~= "table" or message.type ~= "SET_VALVE" then return end
  if message.dst ~= node_id then return end  -- nicht fuer diese Node bestimmt
  -- Feature (2026-07-13): VALVE-P1 (siehe docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md). "fremder Sender auf Kanal 6504 kann
  -- passende Kommandos senden" -- optionale, ABWAERTSKOMPATIBLE Pruefung:
  -- falls config.trusted_source gesetzt ist, werden Kommandos von einem
  -- ANDEREN src stillschweigend verworfen. Standardmaessig (Feld nicht
  -- gesetzt) bleibt das Verhalten unveraendert (jeder Sender akzeptiert)
  -- -- eine erzwungene Pflichtkonfiguration wuerde bestehende
  -- Installationen ohne dieses Feld sofort funktionsunfaehig machen.
  if config.trusted_source and message.src ~= config.trusted_source then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE von nicht vertrauenswuerdiger Quelle ignoriert: " .. tostring(message.src), "WARN")
    return
  end
  if type(message.high) ~= "boolean" then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE ohne gueltiges 'high' ignoriert", "WARN")
    return
  end
  -- Fix (2026-07-13): VALVE-P1. Dedupe -- ein per Retry wiederholtes
  -- identisches Kommando (dieselbe command_id) loest keinen erneuten
  -- Redstone-Write/Log-Eintrag aus, wird aber trotzdem erneut bestaetigt.
  local applied
  if seen_command(message.command_id) then
    applied = (current_high == message.high)
  else
    remember_command(message.command_id)
    applied = apply_valve(message.high)
  end
  send_valve_ack(reply_side, message.command_id, applied, current_high, last_write_error)
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
  heartbeat_state = function() return { side = config.side, blocked = current_high, write_error = last_write_error } end,
}))

utils.log(CONFIG.LOG_PREFIX, "VALVE-Node gestartet: side=" .. config.side .. " node_id=" .. tostring(node_id), "INFO")

support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function() end)
