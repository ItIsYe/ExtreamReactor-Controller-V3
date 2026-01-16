local constants = require("shared.constants")

return {
  role = constants.roles.MASTER,
  wireless_modem = "right",
  wired_modem = "left",
  monitors = {"back"},
  heartbeat_interval = 5,
  startup_ramp = "NORMAL",
  rt_default_mode = "MASTER",
  rt_setpoints = {
    target_rpm = 900,
    enable_reactors = true,
    enable_turbines = true
  },
  nodes = {
    [constants.roles.RT_NODE] = {},
    [constants.roles.ENERGY_NODE] = {},
    [constants.roles.FUEL_NODE] = {},
    [constants.roles.WATER_NODE] = {},
    [constants.roles.REPROCESSOR_NODE] = {}
  }
}
