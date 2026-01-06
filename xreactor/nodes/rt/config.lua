local constants = require("shared.constants")

return {
  role = constants.roles.RT_NODE,
  wireless_modem = "right",
  wired_modem = "left",
  reactors = { "reactor_0" },
  turbines = { "turbine_0" },
  steam_buffer = "steam_tank",
  heartbeat_interval = 3,
  safety = {
    max_temperature = 950,
    reserve_steam = 1000
  }
}
