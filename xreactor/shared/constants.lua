local constants = {}

constants.roles = {
  MASTER = "MASTER",
  RT_NODE = "RT-NODE",
  ENERGY_NODE = "ENERGY-NODE",
  FUEL_NODE = "FUEL-NODE",
  WATER_NODE = "WATER-NODE",
  REPROCESSOR_NODE = "REPROCESSOR-NODE",
  LOG = "LOG",
  LOG_COLLECTOR = "LOG_COLLECTOR",
  -- Feature (2026-07-09): eigenstaendiger Redstone-Valve-Controller
  -- (physischer Integrator ist bei diesem Setup selbst ein CC:Tweaked-
  -- Computer, der per Wireless Modem angesteuert wird und lokal
  -- redstone.setOutput() schaltet -- kein direkt gewraptes Peripheral am
  -- FUEL-Computer). Untergeordnet zu FUEL (siehe installer role select).
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
  -- Feature (2026-07-01): Pocket-Computer Fernabfrage. Ein optionaler
  -- Query/Response-Mechanismus, komplett unabhaengig vom normalen
  -- HEARTBEAT/STATUS-Fluss — ein Pocket Computer sendet POCKET_QUERY und
  -- bekommt vom Master eine einmalige POCKET_STATUS-Antwort mit einer
  -- kompakten Zusammenfassung (kein Dauerabo, jede Abfrage ist einzeln).
  POCKET_QUERY = "POCKET_QUERY",
  POCKET_STATUS = "POCKET_STATUS",
  -- Feature (2026-07-02): Pocket-Computer-Fernsteuerung. POCKET_COMMAND
  -- traegt eine Aktion (rt_hold_toggle/profile_set/maintenance_toggle) PLUS
  -- ein Sicherheits-Token, das der Nutzer am Master (nicht am Pocket
  -- Computer!) einsehen und manuell eintippen muss — verhindert
  -- versehentliche Steuerbefehle durch einen falsch adressierten oder
  -- automatisierten Query. POCKET_COMMAND_RESULT ist die Bestaetigungs-
  -- oder Fehlerantwort.
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
  -- Fix I1: SAFE fehlte — RT-Node kennt STATE.SAFE = "SAFE"
  -- Ohne diesen Eintrag konnte Master SAFE-Nodes nie erkennen
  -- (Sequencer, rt_sync mode_sync_action, is_startable)
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

constants.command_targets = {
  POWER_TARGET = "POWER_TARGET",
  STEAM_TARGET = "STEAM_TARGET",
  TURBINE_RPM = "TURBINE_RPM",
  SET_MODE = "SET_MODE",
  SET_SETPOINTS = "SET_SETPOINTS",
  STARTUP_STAGE = "STARTUP_STAGE",
  SCRAM = "SCRAM",
  MODE = "MODE",
  REQUEST_STATUS = "REQUEST_STATUS",
  SET_RESERVE = "SET_RESERVE",
  -- Feature (2026-07-02): Config-Editor am Monitor — WATER-Ziel-Fuellmenge
  -- fernsteuerbar, analog zu SET_RESERVE bei FUEL.
  SET_TARGET = "SET_TARGET",
  REQUEST_STARTUP_MODULE = "REQUEST_STARTUP_MODULE",
  REQUEST_SHUTDOWN_MODULE = "REQUEST_SHUTDOWN_MODULE",
  -- Feature (2026-07-08): Master leitet den per RT-Status gesammelten
  -- Reaktor-Fuellstand (fuel_amount/fuel_capacity je Reaktor) an FUEL-
  -- Nodes weiter — die FUEL-Node hat selbst keinen Wired-Modem-Zugriff
  -- auf die Reaktoren, nur aufs ME-System. Siehe master/fuel_relay.lua.
  FUEL_STATUS = "FUEL_STATUS",
  -- TEMPORÄR: Remote-Update über alle Nodes, siehe core/remote_update.lua.
  REMOTE_UPDATE = "REMOTE_UPDATE"
}

constants.channels = {
  CONTROL = 6500,
  STATUS  = 6501,
  LOG     = 6503,  -- separater Kanal; Log-Traffic laeuft ueber Wired-Modem
                    -- getrennt vom Control/Status-Traffic (6500/6501 via Ender-Modem)
  -- Feature (2026-07-09): eigener, dedizierter Kanal fuer FUEL<->VALVE
  -- Ventil-Kommandos, bewusst getrennt von CONTROL/STATUS/LOG. Laeuft
  -- ausserhalb der normalen comms_service-Pipeline (siehe nodes/valve/
  -- main.lua und nodes/fuel/redstone_router.lua) -- kein Ack/Retry-
  -- Overhead, reines rohes modem.transmit/pullEvent fuer minimale Latenz.
  VALVE   = 6504,
}

return constants
