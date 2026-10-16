local constants = {}

constants.roles = {
  MASTER = "MASTER",
  RT_NODE = "RT-NODE",
  ENERGY_NODE = "ENERGY-NODE",
  FUEL_NODE = "FUEL-NODE",
  REPROCESSOR_NODE = "REPROCESSOR-NODE",
  LOG = "LOG",
  LOG_COLLECTOR = "LOG_COLLECTOR",
  -- Eigenstaendiger Redstone-Valve-Controller, untergeordnet zu FUEL.
  VALVE_NODE = "VALVE-NODE",
}

constants.proto_ver = { major = 1, minor = 0 }

constants.message_types = {
  HELLO = "HELLO",
  REGISTER = "REGISTER",
  HEARTBEAT = "HEARTBEAT",
  STATUS = "STATUS",
  COMMAND = "COMMAND",
  ALERT = "ALERT",
  ALERT_SUMMARY = "ALERT_SUMMARY",
  ACK = "ACK",
  ACK_DELIVERED = "ACK_DELIVERED",
  ACK_APPLIED = "ACK_APPLIED",
  ERROR = "ERROR",
  -- Optionaler Query/Response-Mechanismus, unabhaengig vom HEARTBEAT/STATUS-
  -- Fluss: ein Pocket Computer sendet POCKET_QUERY, bekommt eine einmalige
  -- POCKET_STATUS-Antwort (kein Dauerabo).
  POCKET_QUERY = "POCKET_QUERY",
  POCKET_STATUS = "POCKET_STATUS",
  -- POCKET_COMMAND traegt eine Aktion plus ein Sicherheits-Token, das der
  -- Nutzer am Master (nicht am Pocket Computer) einsehen und manuell
  -- eintippen muss. POCKET_COMMAND_RESULT ist die Bestaetigungs-/Fehlerantwort.
  POCKET_COMMAND = "POCKET_COMMAND",
  POCKET_COMMAND_RESULT = "POCKET_COMMAND_RESULT"
}

constants.node_states = {
  OFF       = "OFF",
  STARTUP   = "STARTUP",
  RUNNING   = "RUNNING",
  LIMITED   = "LIMITED",
  AUTONOM   = "AUTONOM",
  MANUAL    = "MANUAL",
  EMERGENCY = "EMERGENCY",
  SAFE      = "SAFE"
}

constants.status_levels = {
  OK = "OK",
  LIMITED = "LIMITED",
  WARNING = "WARNING",
  EMERGENCY = "EMERGENCY",
  OFFLINE = "OFFLINE",
  MANUAL = "MANUAL"
}

-- Nur Ziele, die auch wirklich gesendet ODER behandelt werden.
-- Entfallen (2026-09-29, Kommunikations-Durchgang): POWER_TARGET,
-- STEAM_TARGET, TURBINE_RPM und REQUEST_SHUTDOWN_MODULE -- keines kam
-- ausserhalb dieser Liste noch irgendwo vor.
constants.command_targets = {
  SET_MODE = "SET_MODE",
  SET_SETPOINTS = "SET_SETPOINTS",
  STARTUP_STAGE = "STARTUP_STAGE",
  SCRAM = "SCRAM",
  MODE = "MODE",
  REQUEST_STATUS = "REQUEST_STATUS",
  SET_RESERVE = "SET_RESERVE",
  -- Loest den Hand-Riegel eines SCRAM wieder (nodes/rt/rt2_command_handler).
  REQUEST_STARTUP_MODULE = "REQUEST_STARTUP_MODULE",
  -- Master leitet den per RT-Status gesammelten Reaktor-Fuellstand an FUEL
  -- weiter -- FUEL hat selbst keinen Wired-Zugriff auf die Reaktoren.
  FUEL_STATUS = "FUEL_STATUS",
  -- TEMPORÄR: Remote-Update über alle Nodes, siehe core/remote_update.lua.
  REMOTE_UPDATE = "REMOTE_UPDATE"
}

-- Funk-Hygiene v822: jede Richtung ihr eigener Kanal. Ein Computer bekommt
-- nur Meldungen auf Kanaelen, die er offen hat -- wer eine Richtung nicht
-- braucht, hat ihren Kanal zu und muss die Meldungen gar nicht erst
-- verwerfen.
constants.channels = {
  -- Downlink: MASTER -> alle (Kommandos, MASTERs Heartbeat/Status/Alarm/
  -- Hello). Jede Node hoert ihn.
  CONTROL = 6500,
  -- Uplink: Nodes -> MASTER (Heartbeat/Status/Hello/Alarm/Quittungen).
  -- Dauerhaft hoeren ihn nur MASTER und FUEL (services/comms_service.lua).
  STATUS  = 6501,
  -- Log-Zeilen an den LOG_COLLECTOR. Nur er hoert ihn (ab v822).
  LOG     = 6503,
  -- Antworten des LOG_COLLECTORs (LOG_ACK, LOG_PING) an die Nodes.
  LOG_REPLY = 6505,
  -- Dedizierter Kanal fuer FUEL -> VALVE Ventil-Kommandos, ausserhalb der
  -- normalen comms_service-Pipeline -- kein Ack/Retry-Overhead, rohes
  -- modem.transmit/pullEvent fuer minimale Latenz.
  VALVE   = 6504,
  -- Antworten der Ventile an FUEL (VALVE_ACK, HOP_SCAN, ROUTE_TEACH_PULSE).
  -- Nur FUEL hoert ihn.
  VALVE_REPLY = 6506,
}

return constants
