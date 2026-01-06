local constants = require("shared.constants")

return {
  role = constants.roles.WATER_NODE,
  wireless_modem = "right",
  wired_modem = "left",
  loop_tanks = { "water_tank_0", "steam_condensate_0" },
  target_volume = 50000,
  heartbeat_interval = 4
}
