-- nodes/valve/main.lua
--
-- Minimaler eigenstaendiger Valve-Controller fuer einen Mekanism
-- Logistical Sorter.
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
-- Fix (2026-07-20): der urspruengliche Redstone-Aktor (config.actuator_
-- type = "redstone", direktes redstone.setOutput()) ist in der aktuellen
-- Aufstellung nicht mehr im Einsatz und wurde komplett entfernt -- jede
-- VALVE-Node steuert ausschliesslich einen Mekanism Logistical Sorter
-- (setAutoMode()) per CC:Tweaked-Peripherie. Kein "actuator_type"-Feld
-- und keine Redstone-Seite mehr in der Config noetig.
--
-- Feature (2026-07-20): sowohl das Wireless Modem als auch der Sorter
-- werden jetzt automatisch erkannt (kein Config-Eintrag mehr noetig) --
-- das Modem wurde schon vorher unabhaengig von "side" per peripheral.
-- find() gesucht, der Sorter wird jetzt genauso per Methodensignatur
-- (setAutoMode) gesucht, sobald config.sorter_name nicht explizit gesetzt
-- ist (siehe get_sorter() unten).
--
-- Zusaetzlich ein fest eingebauter (NICHT optionaler) Statusmonitor:
-- gruen=offen, rot=blockiert. Bewusst NICHT das gemeinsame optional/
-- ampel.lua-Modul (das verlangt eine 1x3-Block-Turmform, 7x17-21 Zeichen
-- bei Skala 1, und ist ein per Installer-Feature abwaehlbares Extra) --
-- VALVEs Statusmonitor ist ein einzelner 1x1-Block ohne Formpruefung und
-- immer Teil der Installation, kein Installer-Prompt. Ist physisch kein
-- Monitor angeschlossen, passiert schlicht nichts (voll pcall-isoliert).
--
-- Feature (2026-07-20): ROUTE_TEACH_PULSE -- Route-Teach-in per manuellem
-- Redstone-INPUT (nicht Output!): der Spieler legt vor Ort einen Hebel/
-- Knopf an dieser Node um, waehrend er im FUEL/REPROCESSOR-Router-Editor
-- einen Reaktor-Pfad einlernt (siehe check_teach_input() weiter unten) --
-- die Node meldet die steigende Flanke per Funk, die UI haengt den
-- gemeldeten Knoten an die gerade bearbeitete Ventilkette an.
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
  -- Feature (2026-07-14): siehe config.lua fuer die ausfuehrliche
  -- Begruendung -- hier zusaetzlich in DEFAULT_CONFIG, damit merge_
  -- defaults() dieses Feld auch bei bereits migrierten/geschuetzten
  -- Config-Dateien (siehe GLOBAL-P0) automatisch nachtraegt, nicht nur
  -- bei einer komplett frischen Installation.
  -- Fix (2026-07-20): nil = automatisch per Methodensignatur erkennen
  -- (siehe get_sorter() unten), analog zu wireless_modem oben. Nur bei
  -- mehreren Sortern am selben Computer noetig, einen bestimmten Namen
  -- explizit zu setzen.
  sorter_name = nil,
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
-- Fix (2026-07-20): nil bedeutet jetzt bewusst "automatisch erkennen"
-- (siehe get_sorter()) -- nur ein tatsaechlich ungueltiger, nicht-nil-Wert
-- (z.B. eine Zahl oder ein leerer String durch einen Tippfehler) wird
-- hier korrigiert.
if config.sorter_name ~= nil and (type(config.sorter_name) ~= "string" or config.sorter_name == "") then
  add_config_warning("sorter_name ungueltig, wird ignoriert (automatische Suche)")
  config.sorter_name = nil
end

local node_id = support_runtime.init_logging({
  utils = utils, config = config, runtime_config = CONFIG,
  config_meta = config_meta, config_warnings = config_warnings
})

local valve_health = health.new({})
-- Fix (2026-07-16): CRITICAL (VALVE-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 12). Muss ab dem Boot einen echten
-- Zeitstempel tragen (nicht nil) -- apply_valve() aktualisiert last_
-- command_ts jetzt NUR NOCH bei Erfolg (siehe dort). Bliebe dieser Wert
-- bis zum ersten erfolgreichen Kommando bei nil, wuerde der Fail-Safe-
-- Watchdog unten (der explizit "if last_command_ts and ..." prueft)
-- niemals auslösen, selbst wenn der allererste Boot-Write fehlschlaegt und
-- die Node danach nie ein gueltiges SET_VALVE-Kommando erreicht -- ein
-- moeglicherweise unsicher offenes Ventil bliebe dann fuer immer
-- unbeaufsichtigt.
local last_command_ts = os.epoch("utc")
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
-- Redstone-Traffic). valve_initialized stellt sicher, dass der PFLICHT-
-- Boot-Write (siehe apply_valve(current_high) weiter unten, noch bevor
-- irgendeine Verbindung steht) NICHT durch die Dedup-Pruefung
-- uebersprungen wird, nur weil der Zielwert zufaellig mit dem bereits
-- gesetzten Default uebereinstimmt -- ohne diesen expliziten Flag haette
-- der allererste Aufruf faelschlich als "schon im Zielzustand" gegolten
-- und den physischen Write nie ausgefuehrt.
--
-- Fix (2026-07-16): CRITICAL (VALVE-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 12). last_command_ts wurde bisher
-- UNBEDINGT als allererste Anweisung gesetzt, auch wenn der Write weiter
-- unten fehlschlug -- ein fehlgeschlagenes BLOCK-Kommando (Ventil bleibt
-- unsicher OFFEN) setzte den Fail-Safe-Watchdog-Timer (siehe unten,
-- "valve_failsafe") trotzdem auf "gerade eben" zurueck und verlaengerte
-- dadurch, wie lange das Ventil unbemerkt offen bleiben konnte, obwohl
-- der Schreibversuch nachweislich NICHT angekommen ist. Jetzt: last_
-- command_ts wird nur noch bei einem tatsaechlich erfolgreichen Write
-- (oder wenn ohnehin kein Write noetig war, da bereits im Zielzustand)
-- aktualisiert -- ein Fehlschlag laesst den Watchdog auf dem AELTEREN
-- Zeitstempel stehen, wodurch er eher (nicht spaeter) erneut eingreift.
-- Feature (2026-07-14): Aktor ist ein Mekanism Logistical Sorter, gesteuert
-- per CC:Tweaked (setAutoMode). Der Sorter hat einen "Auto"-Modus, der --
-- wenn aktiv -- Items automatisch herauspumpt (siehe Mekanism-Wiki) --
-- genau das wird hier als Auf/Zu-Schalter genutzt: high=true bedeutet
-- BLOCKIERT (Fail-Safe-Grundzustand, Auto-Modus AUS), high=false bedeutet
-- OFFEN (Auto-Modus AN).
--
-- Fix (2026-07-20): der urspruengliche Redstone-Aktor (config.actuator_
-- type = "redstone") ist entfernt -- jede VALVE-Node steuert ausschliesslich
-- einen Sorter, kein config.side/actuator_type mehr noetig.
local sorter_device = nil
local sorter_resolved_name = nil
-- Fix (2026-07-20): automatische Sorter-Erkennung per Methodensignatur
-- (setAutoMode), analog zum bereits vorhandenen Muster fuer die ME Bridge
-- (nodes/fuel/logistics_router.lua) -- greift nur, wenn config.sorter_name
-- NICHT explizit gesetzt ist (nil), ein explizit konfigurierter, aber
-- gerade nicht angeschlossener Name wird weiterhin klar als "nicht
-- gefunden" gemeldet statt stillschweigend einen anderen Sorter zu binden.
local function find_sorter_by_capability()
  for _, name in ipairs(peripheral.getNames() or {}) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and type(methods) == "table" then
      local set = {}
      for _, m in ipairs(methods) do set[m] = true end
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

local function write_actuator(high)
  local sorter = get_sorter()
  if not sorter then
    local label = config.sorter_name and ("'" .. tostring(config.sorter_name) .. "'") or "automatische Suche erfolglos"
    return false, "Sorter nicht gefunden (" .. label .. ")"
  end
  -- high=true (BLOCKIERT) -> Auto-Modus AUS; high=false (OFFEN) -> AN.
  local ok, err = pcall(sorter.setAutoMode, not high)
  if not ok then
    -- Fix (2026-07-17): VALVE-P1 (siehe docs/CODING_AI_OTHER_NODES_
    -- PERFORMANCE_2026-07-12.md Abschnitt 21). get_sorter() cachte den
    -- einmal gewrappten Sorter bisher DAUERHAFT -- scheiterte ein
    -- spaeterer Call (Detach/Reattach, ersetztes Peripheral, Chunk-
    -- Entladen), blieb sorter_device trotzdem gesetzt und jeder weitere
    -- Versuch traf denselben kaputten Handle erneut, ohne je neu zu
    -- wrappen. Jetzt: bei einem Callfehler wird der Cache geleert, der
    -- naechste get_sorter()-Aufruf (naechster Retry) wrappt das
    -- Peripheral frisch.
    sorter_device = nil
    return false, tostring(err)
  end
  return true
end

-- Feature (2026-07-20): fest eingebauter 1x1-Statusmonitor -- gruen=offen,
-- rot=blockiert. Kein Formcheck (anders als optional/ampel.lua's 1x3-
-- Turmform), einfach der erste gefundene Monitor. Cache wird bei jedem
-- Fehlschlag (Detach/Reattach) verworfen, damit der naechste Aufruf neu
-- sucht -- dasselbe Muster wie get_sorter().
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
  local color = current_high and colors.red or colors.green
  if status_monitor_last_color == color then return end
  local ok = pcall(function()
    mon.setBackgroundColor(color)
    mon.clear()
  end)
  if ok then
    status_monitor_last_color = color
  else
    status_monitor = nil
    status_monitor_last_color = nil
  end
end

local function apply_valve(high)
  if valve_initialized and high == current_high then
    last_command_ts = os.epoch("utc")
    render_status_monitor()
    return true  -- bereits im Zielzustand, kein erneuter Write noetig
  end
  local ok, err = write_actuator(high)
  if not ok then
    last_write_error = tostring(err)
    utils.log(CONFIG.LOG_PREFIX, "Ventil-Write fehlgeschlagen (Sorter " .. tostring(sorter_resolved_name or config.sorter_name or "?") .. "): " .. tostring(err), "ERROR")
    return false
  end
  current_high = high
  valve_initialized = true
  last_write_error = nil
  last_command_ts = os.epoch("utc")
  render_status_monitor()
  utils.log(CONFIG.LOG_PREFIX, string.format("Ventil (Sorter %s) -> %s", tostring(sorter_resolved_name or config.sorter_name or "?"), high and "BLOCKIERT" or "OFFEN"), "INFO")
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

-- Feature (2026-07-20): "Weg 3" -- Route-Teach-in per manuellem Redstone-
-- INPUT (siehe Header-Kommentar oben): der Spieler legt vor Ort einen
-- Hebel/Knopf an einer beliebigen der 6 eingebauten Redstone-Seiten dieser
-- Node um -- Seite ist bewusst egal, nur "irgendein Input gerade an"
-- zaehlt. Erkennt eine STEIGENDE Flanke (vorher ueberall aus, jetzt
-- irgendwo an) und sendet dann genau EINMAL einen ROUTE_TEACH_PULSE-
-- Broadcast (kein "dst" -- FUEL/REPROCESSOR werten "src" aus, siehe
-- nodes/fuel/router_ui.lua's Teach-Modus; ein lauschender Node, der sich
-- gerade nicht im Teach-Modus befindet, ignoriert die Nachricht einfach).
-- Re-arm erst, sobald der Input wieder ueberall auf "aus" faellt --
-- dieselbe simple "an, dann wieder aus"-Hebel-Geste re-armt sich dadurch
-- von selbst, kein zusaetzlicher Debounce-Timer noetig. Rein informativ,
-- KEINE Trust-Pruefung (der Spieler steht physisch am Block) und KEINE
-- Auswirkung auf apply_valve()/current_high -- komplett unabhaengig von
-- der eigentlichen Sorter-Steuerung.
local teach_input_state = false
local function check_teach_input()
  local any_high = false
  local ok, sides = pcall(redstone.getSides)
  if ok and type(sides) == "table" then
    for _, side in ipairs(sides) do
      local iok, input = pcall(redstone.getInput, side)
      if iok and input then any_high = true; break end
    end
  end
  if any_high and not teach_input_state and valve_modem then
    pcall(valve_modem.transmit, constants.channels.VALVE, constants.channels.VALVE, {
      type = "ROUTE_TEACH_PULSE", src = node_id,
    })
  end
  teach_input_state = any_high
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

-- Fix (2026-07-17): VALVE-P1 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md Abschnitt 21). Ergaenzt um `src`/`dst` -- die eigentliche
-- ACK-Zuordnung auf FUEL-Seite laeuft bereits ausschliesslich ueber die
-- (per ROUTER-P0 command-id-gebundene) `command_id`, aber `src`/`dst`
-- machen den ACK auch fuer Logging/Diagnose eindeutig einem Sender/
-- Empfaenger zuordenbar, statt nur "irgendein VALVE_ACK auf Kanal 6504".
local function send_valve_ack(reply_side, command_id, applied, high, err, dst)
  if not command_id or not reply_side then return end
  local ok, modem = pcall(peripheral.wrap, reply_side)
  if not ok or not modem or type(modem.transmit) ~= "function" then return end
  pcall(modem.transmit, constants.channels.VALVE, constants.channels.VALVE, {
    type = "VALVE_ACK", command_id = command_id, applied = applied == true, high = high, error = err,
    src = node_id, dst = dst,
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
  -- passende Kommandos senden".
  --
  -- Fix (2026-07-17): VALVE-P1 (Abschnitt 21). Vorher war die Pruefung rein
  -- OPTIONAL -- ohne manuell gesetztes config.trusted_source akzeptierte
  -- die Node auf Dauer JEDEN Sender, der ein korrekt adressiertes SET_VALVE
  -- auf Kanal 6504 sendet. Fuer einen Safety-Aktor (Ventil) sollte die
  -- erlaubte Steuerquelle stattdessen ueber einen Pairingzustand gebunden
  -- sein. Jetzt: automatisches Pairing beim ERSTEN akzeptierten SET_VALVE
  -- nach einer frischen Installation -- config.trusted_source wird auf den
  -- Absender dieses ersten Kommandos gesetzt und in der geschuetzten
  -- Nutzerconfig persistiert (ueberlebt Neustarts). Jeder SPAETERE Sender
  -- mit abweichender src wird verworfen. Bleibt dadurch abwaertskompatibel
  -- (kein manuelles Vorab-Pairing noetig, funktioniert "out of the box"),
  -- schliesst aber die Luecke "akzeptiert dauerhaft jeden Sender".
  if config.trusted_source then
    if message.src ~= config.trusted_source then
      utils.log(CONFIG.LOG_PREFIX, "SET_VALVE von nicht vertrauenswuerdiger Quelle ignoriert: " .. tostring(message.src), "WARN")
      return
    end
  else
    config.trusted_source = message.src
    local ok_pair, perr = utils.write_config(CONFIG.CONFIG_PATH, config)
    if not ok_pair then
      utils.log(CONFIG.LOG_PREFIX, "trusted_source-Pairing konnte nicht persistiert werden (" .. tostring(perr) .. ") -- gilt nur bis zum naechsten Neustart", "WARN")
    end
    utils.log(CONFIG.LOG_PREFIX, "trusted_source automatisch an " .. tostring(message.src) .. " gebunden (Erstkommando)", "INFO")
  end
  if type(message.high) ~= "boolean" then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE ohne gueltiges 'high' ignoriert", "WARN")
    return
  end
  -- Fix (2026-07-13): VALVE-P1. Dedupe -- ein per Retry wiederholtes
  -- identisches Kommando (dieselbe command_id) loest keinen erneuten
  -- Redstone-Write/Log-Eintrag aus, wird aber trotzdem erneut bestaetigt.
  --
  -- Fix (2026-07-16): CRITICAL (VALVE-P0, siehe docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md Abschnitt 12). remember_command() lief bisher
  -- VOR dem Ergebnis von apply_valve() -- schlug der physische Write fehl,
  -- war die command_id trotzdem bereits als "gesehen" markiert. Ein
  -- Retry mit DERSELBEN ID (redstone_router.lua's check_pending_acks()
  -- sendet bei ausbleibender Bestaetigung exakt dieselbe command_id erneut)
  -- traf dadurch nur noch den Dedupe-Zweig (applied = current_high==high,
  -- ohne einen zweiten Schreibversuch) -- Retry war beim eigentlichen
  -- Anwendungsfall (Schreibfehler) also wirkungslos. Jetzt: nur ein
  -- ERFOLGREICHER apply_valve() merkt sich die ID; eine fehlgeschlagene
  -- ID bleibt "ungesehen" und wird bei identischem Retry erneut wirklich
  -- geschrieben, so lange bis sie tatsaechlich uebernommen wurde.
  local applied
  if seen_command(message.command_id) then
    applied = (current_high == message.high)
  else
    applied = apply_valve(message.high)
    if applied then
      remember_command(message.command_id)
    end
  end
  send_valve_ack(reply_side, message.command_id, applied, current_high, last_write_error, message.src)
end

local comms = comms_service.new({
  config = config, log_prefix = CONFIG.LOG_PREFIX,
})

local services = service_manager.new()
services:add(comms)
services:add({ name = "valve_channel", wants_events = true, tick = function(_self, dt, event)
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

-- Feature (2026-07-20): periodisches Polling fuer den Route-Teach-in-Input
-- (siehe check_teach_input() oben) -- jeder Tick prueft, ob gerade ein
-- Hebel/Knopf an dieser Node umgelegt wurde.
services:add({ name = "teach_input_poll", tick = function() check_teach_input() end })

-- Feature (2026-07-20): periodischer Statusmonitor-Refresh -- render_
-- status_monitor() wird bereits bei jeder tatsaechlichen Zustands-
-- aenderung in apply_valve() aufgerufen, dieser periodische Tick faengt
-- zusaetzlich einen erst NACH dem letzten Zustandswechsel angeschlossenen/
-- wiederangeschlossenen Monitor ab, ohne auf das naechste SET_VALVE warten
-- zu muessen. Guenstig durch den Farb-Diff-Cache (siehe oben), kein
-- zusaetzlicher Akkumulator noetig.
services:add({ name = "status_monitor_render", tick = function() render_status_monitor() end })

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
  heartbeat_state = function() return {
    blocked = current_high, write_error = last_write_error,
    actuator_name = sorter_resolved_name or config.sorter_name,
  } end,
}))

utils.log(CONFIG.LOG_PREFIX, "VALVE-Node gestartet: sorter=" .. tostring(sorter_resolved_name or config.sorter_name or "auto") .. " node_id=" .. tostring(node_id), "INFO")

-- Fix (2026-07-17): CRITICAL. INSTALL-P0.2 (Abschnitt 4): expliziter
-- Quiesce-Handler. VALVE ist die einzige der vier sicherheitskritischen
-- Rollen mit einer echten, SYNCHRONEN Erfolgsbestaetigung (apply_valve()
-- liefert true/false) -- dieselbe bereits vorhandene, im Fail-Safe-
-- Watchdog (siehe oben) bewaehrte Funktion wird hier wiederverwendet.
-- run_event_loop() ruft on_quiesce() bei Bedarf mehrfach auf (einmal pro
-- Zyklus), bis sie true liefert -- kein neuer Aktor-Code, keine Annahme
-- ungeprueften Erfolgs.
local quiesce_handshake = _G.__xreactor_update_handshake
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function() end,
  quiesce_handshake and { handshake = quiesce_handshake, on_quiesce = function() return apply_valve(true) end } or nil)
