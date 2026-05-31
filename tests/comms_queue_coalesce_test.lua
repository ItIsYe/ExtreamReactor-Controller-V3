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
    now = now + 1000
    return now
  end
  os.time = function() return 0 end
  os.date = function() return "00:00:00" end
  _G.settings = { get = function() return false end }
end

install_stubs()
package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local constants = require("shared.constants")
local comms_lib = require("core.comms")

local sends = {}
local net = {
  id = "NODE-1",
  role = "TEST",
  channels = { control = 77, status = 88 },
  send = function(_, _, payload)
    sends[#sends + 1] = payload
    if payload.type == constants.message_types.COMMAND then
      return true
    end
    return false, "offline"
  end,
}

local comms = comms_lib.init({
  network = net,
  node_id = "NODE-1",
  role = "TEST",
  config = { queue_limit = 20, volatile_ttl_s = 2, ack_timeout_s = 1, max_retries = 1 }
})

for i = 1, 5 do
  comms.send(nil, constants.message_types.STATUS, { seq = i }, { channel = 88 })
end
comms.tick()
local diag = comms.get_diagnostics()
if (diag.queue_depth or 0) ~= 1 then
  error("status queue should coalesce to a single pending entry")
end

comms.send("NODE-2", constants.message_types.COMMAND, { command = { target = "MODE", value = "RUN" } }, {
  require_ack = true,
  channel = 77,
  message_id = "cmd-1"
})
comms.tick()
local diag2 = comms.get_diagnostics()
if (diag2.inflight_count or 0) ~= 1 then
  error("command reliability must remain intact")
end

for _ = 1, 3 do
  comms.tick()
end
local diag3 = comms.get_diagnostics()
if (diag3.queue_depth or 0) ~= 0 then
  error("stale volatile queue entries should expire")
end

print("comms_queue_coalesce_test.lua: ok")
