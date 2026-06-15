local constants = {}

constants.roles = {
  MASTER = "MASTER",
  RT_NODE = "RT-NODE",
  ENERGY_NODE = "ENERGY-NODE",
  FUEL_NODE = "FUEL-NODE",
  WATER_NODE = "WATER-NODE",
  REPROCESSOR_NODE = "REPROCESSOR-NODE",
  LOG = "LOG",
  LOG_COLLECTOR = "LOG_COLLECTOR"
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
  ERROR = "ERROR"
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
  REQUEST_STARTUP_MODULE = "REQUEST_STARTUP_MODULE",
  REQUEST_SHUTDOWN_MODULE = "REQUEST_SHUTDOWN_MODULE"
}

constants.channels = {
  CONTROL = 6500,
  STATUS = 6501,
  LOG = 6502
}

return constants
