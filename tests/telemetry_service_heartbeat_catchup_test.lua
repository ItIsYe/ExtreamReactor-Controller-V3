local now = 0

_G.os = {
  epoch = function() return now end
}

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local telemetry_service = require("services.telemetry_service")

local heartbeats = {}
local statuses = 0

local service = telemetry_service.new({
  heartbeat_interval = 2,
  status_interval = 5,
  comms = {
    network = { role = "energy", id = "ENERGY-1" },
    send_heartbeat = function()
      heartbeats[#heartbeats + 1] = now
    end,
    publish_status = function()
      statuses = statuses + 1
    end
  },
  build_payload = function()
    now = now + 3500 -- simulate expensive status payload path
    return { ok = true }
  end
})

now = 2100
service:tick()
if #heartbeats ~= 1 then
  error("expected first heartbeat once heartbeat interval is due")
end
if statuses ~= 0 then
  error("status should not be published before status interval")
end

now = 5100
service:tick()
if statuses ~= 1 then
  error("expected status publish once status interval is due")
end
if #heartbeats ~= 3 then
  error("expected heartbeat before and after slow status build to preserve liveness cadence")
end
if heartbeats[2] ~= 5100 then
  error("expected heartbeat right before status publish")
end
if heartbeats[3] ~= 8600 then
  error("expected catch-up heartbeat right after slow status build")
end

print("telemetry_service_heartbeat_catchup_test.lua: ok")
