local constants = require("shared.constants")

return {
  role = constants.roles.REPROCESSOR_NODE,
  wireless_modem = "right",
  wired_modem = "left",
  buffers = { "waste_buffer_0" },
  heartbeat_interval = 5
}
