local constants = require("shared.constants")

return {
  role = constants.roles.MASTER,
  wireless_modem = "right",
  wired_modem = "left",
  monitors = {"back"},
  heartbeat_interval = 5,
  startup_ramp = "NORMAL",
  nodes = {
    [constants.roles.RT_NODE] = {},
    [constants.roles.ENERGY_NODE] = {},
    [constants.roles.FUEL_NODE] = {},
    [constants.roles.WATER_NODE] = {},
    [constants.roles.REPROCESSOR_NODE] = {}
  }
}
