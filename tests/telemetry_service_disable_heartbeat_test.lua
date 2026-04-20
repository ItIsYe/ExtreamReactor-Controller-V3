local now = 0

_G.os = {
  epoch = function() return now end
}

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local telemetry_service = require("services.telemetry_service")

local heartbeats = 0
local statuses = 0

local service = telemetry_service.new({
  heartbeat_interval = 2,
  status_interval = 3,
  enable_heartbeat = false,
  comms = {
    network = { role = "energy", id = "ENERGY-1" },
    send_heartbeat = function()
      heartbeats = heartbeats + 1
    end,
    publish_status = function()
      statuses = statuses + 1
    end
  },
  build_payload = function()
    return { ok = true }
  end
})

now = 2500
service:tick()
if heartbeats ~= 0 then
  error("heartbeat path must stay disabled when enable_heartbeat=false")
end
if statuses ~= 0 then
  error("status should not publish before status interval")
end

now = 3100
service:tick()
if heartbeats ~= 0 then
  error("heartbeat must not be sent during status publish when disabled")
end
if statuses ~= 1 then
  error("status publish should still work when heartbeat is disabled")
end

print("telemetry_service_disable_heartbeat_test.lua: ok")
