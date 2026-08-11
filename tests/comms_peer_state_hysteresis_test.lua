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
  id = "ENERGY-1",
  role = constants.roles.ENERGY_NODE,
  channels = { control = 77, status = 88 },
  send = function()
    return true
  end,
}

local comms = comms_lib.init({
  network = net,
  node_id = "ENERGY-1",
  role = constants.roles.ENERGY_NODE,
  config = {
    require_command_auth = false,
    peer_timeout_s = 10,
    peer_down_grace_s = 3,
    peer_up_debounce_s = 2,
    peer_up_min_observations = 2
  }
})

local heartbeat = {
  type = constants.message_types.HEARTBEAT,
  message_id = "hb-1",
  src = "MASTER-37",
  sender_id = "MASTER-37",
  role = constants.roles.MASTER,
  ts = 0,
  timestamp = 0,
  proto_ver = constants.proto_ver,
  payload = { state = "RUNNING" }
}

comms.receive(heartbeat)
comms.tick()
local peers = comms.get_peer_state()
if not peers["MASTER-37"] or peers["MASTER-37"].down then
  error("peer should start as up immediately after heartbeat")
end

advance(11000)
comms.tick()
peers = comms.get_peer_state()
if peers["MASTER-37"].down then
  error("peer should remain up while within down-grace window")
end

advance(3000)
comms.tick()
peers = comms.get_peer_state()
if not peers["MASTER-37"].down then
  error("peer should be marked down after timeout + grace")
end

advance(1000)
heartbeat.message_id = "hb-2"
heartbeat.ts = 15000
heartbeat.timestamp = 15000
comms.receive(heartbeat)
comms.tick()
peers = comms.get_peer_state()
if not peers["MASTER-37"].down then
  error("peer should remain down until up-debounce elapses")
end

advance(2000)
comms.tick()
peers = comms.get_peer_state()
if not peers["MASTER-37"].down then
  error("peer should remain down until minimum recovery observations are met")
end

advance(1000)
heartbeat.message_id = "hb-3"
heartbeat.ts = 18000
heartbeat.timestamp = 18000
comms.receive(heartbeat)
comms.tick()
peers = comms.get_peer_state()
if peers["MASTER-37"].down then
  error("peer should recover to up after debounce and repeated recovery observations")
end

print("comms_peer_state_hysteresis_test.lua: ok")
