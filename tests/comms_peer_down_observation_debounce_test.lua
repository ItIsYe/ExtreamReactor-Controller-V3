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
    peer_timeout_s = 6,
    peer_down_grace_s = 0,
    peer_down_min_observations = 2,
    peer_up_debounce_s = 0.5,
    peer_up_min_observations = 2
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
local peers = comms.get_peer_state()
if peers["ENERGY-1"].down then
  error("peer should be up after first heartbeat")
end
if peers["ENERGY-1"].last_message_type ~= constants.message_types.HEARTBEAT then
  error("peer diagnostics should include last message type")
end

advance(6500)
comms.tick()
peers = comms.get_peer_state()
if peers["ENERGY-1"].down then
  error("single stale observation should not mark peer down")
end
if peers["ENERGY-1"].stale_observations ~= 1 then
  error("expected one stale observation before down transition")
end

advance(500)
comms.tick()
peers = comms.get_peer_state()
if not peers["ENERGY-1"].down then
  error("second stale observation should mark peer down")
end

advance(500)
heartbeat.message_id = "hb-2"
heartbeat.ts = 7500
heartbeat.timestamp = 7500
comms.receive(heartbeat)
comms.tick()
peers = comms.get_peer_state()
if not peers["ENERGY-1"].down then
  error("peer should stay down until recovery observations are met")
end

advance(700)
heartbeat.message_id = "hb-3"
heartbeat.ts = 8200
heartbeat.timestamp = 8200
comms.receive(heartbeat)
comms.tick()
peers = comms.get_peer_state()
if peers["ENERGY-1"].down then
  error("peer should recover after debounce + repeated observations")
end

print("comms_peer_down_observation_debounce_test.lua: ok")
