local constants = require("shared.constants")

return {
  role = constants.roles.ENERGY_NODE,
  wireless_modem = "right",
  wired_modem = "left",
  cubes = { "energy_cube_0" },
  matrix = "induction_matrix",
  heartbeat_interval = 4
}
