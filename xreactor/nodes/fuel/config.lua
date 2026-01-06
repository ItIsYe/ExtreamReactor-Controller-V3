local constants = require("shared.constants")

return {
  role = constants.roles.FUEL_NODE,
  wireless_modem = "right",
  wired_modem = "left",
  storage_bus = "ae2_interface_0",
  minimum_reserve = 10000,
  heartbeat_interval = 5
}
