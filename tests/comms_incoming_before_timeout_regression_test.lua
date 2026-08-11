local function install_stubs()
  _G.fs = {
    exists = function() return false end,
    open = function() return nil end,
    getDir = function() return "" end,
    makeDir = function() end,
    getSize = function() return 0 end,
    move = function() end,
    delete = function() end,
  }
  _G.textutils = {
    serialize = function(value)
      if type(value) ~= "table" then return tostring(value) end
      local parts = {}
      for k, v in pairs(value) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
      end
      table.sort(parts)
      return table.concat(parts, ";")
    end,
    unserialize = function() return nil end,
  }
  _G.os = _G.os or {}
  local now = 0
  os.epoch = function()
    return now
  end
  os.time = function() return 0 end
  os.date = function() return "00:00:00" end
  _G.settings = { get = function() return false end }
  return function(ms)
    now = now + ms
    return now
  end
end

local advance = install_stubs()
package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local constants = require("shared.constants")
local comms_lib = require("core.comms")

local net = {
  id = "MASTER-1",
  role = constants.roles.MASTER,
  channels = { control = 77, status = 88 },
  send = function()
    return true
  end,
}

local comms = comms_lib.init({
  network = net,
  node_id = "MASTER-1",
  role = constants.roles.MASTER,
  config = {
    require_command_auth = false,
    peer_timeout_s = 2,
    peer_down_grace_s = 0,
    peer_down_min_observations = 1,
    peer_up_debounce_s = 0,
    peer_up_min_observations = 1
  }
})

local heartbeat = {
  type = constants.message_types.HEARTBEAT,
  message_id = "hb-1",
  src = "ENERGY-1",
  sender_id = "ENERGY-1",
  role = constants.roles.ENERGY_NODE,
  ts = 0,
  timestamp = 0,
  proto_ver = constants.proto_ver,
  payload = { state = "RUNNING" }
}

comms.receive(heartbeat)
comms.tick()

advance(2500)
heartbeat.message_id = "hb-2"
heartbeat.ts = 2500
heartbeat.timestamp = 2500
comms.receive(heartbeat)
comms.tick()

local peer = comms.get_peer_state()["ENERGY-1"]
if not peer then
  error("peer should still be tracked after fresh heartbeat")
end
if peer.down then
  error("fresh heartbeat queued for this tick must not cause transient down")
end
if peer.stale then
  error("peer stale flag should be cleared by fresh heartbeat processed in same tick")
end

print("comms_incoming_before_timeout_regression_test.lua: ok")
