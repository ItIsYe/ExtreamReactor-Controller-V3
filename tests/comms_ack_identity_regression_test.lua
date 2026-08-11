package.path = "xreactor/?.lua;xreactor/?/init.lua;" .. package.path

local constants = require("shared.constants")
local comms = require("core.comms")

local now = 100000
os.epoch = function() return now end

local sent = {}
local network = {
  id = "MASTER-1",
  role = constants.roles.MASTER,
  channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
}
function network:send(channel, message)
  sent[#sent + 1] = { channel = channel, message = message }
  return true
end

comms.init({
  network = network,
  node_id = "MASTER-1",
  role = constants.roles.MASTER,
  config = { ack_timeout_s = 3, max_retries = 1, require_command_auth = false },
  logger = function() end,
})

local entry = comms.send("RT-1", constants.message_types.COMMAND,
  { command = { target = "SET_SETPOINTS" } },
  { require_ack = true, require_applied = true, message_id = "cmd-identity-1" })
assert(entry, "command should queue")
comms.tick()
assert(comms.get_diagnostics().inflight_count == 1, "command must be inflight")

local function ack(src, dst)
  return {
    type = constants.message_types.ACK_APPLIED,
    message_id = "ack-" .. src .. "-" .. dst,
    ack_for = "cmd-identity-1",
    src = src,
    sender_id = src,
    node_id = src,
    dst = dst,
    role = constants.roles.RT_NODE,
    ts = now,
    timestamp = now,
    proto_ver = constants.proto_ver,
    payload = { result = { ok = true } },
  }
end

comms.receive(ack("RT-OTHER", "MASTER-1"))
comms.tick()
assert(comms.get_diagnostics().inflight_count == 1,
  "ACK from another peer must not complete command")

comms.receive(ack("RT-1", "SOMEONE-ELSE"))
comms.tick()
assert(comms.get_diagnostics().inflight_count == 1,
  "ACK addressed to another node must not complete command")

comms.receive(ack("RT-1", "MASTER-1"))
comms.tick()
assert(comms.get_diagnostics().inflight_count == 0,
  "matching src/dst ACK must complete command")

print("comms_ack_identity_regression_test: OK")
