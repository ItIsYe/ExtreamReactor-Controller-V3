local now = 0

_G.os = {
  epoch = function() return now end
}

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local telemetry_service = require("services.telemetry_service")

local heartbeat_sent = 0
local status_sent = 0
local build_opts = {}

local service = telemetry_service.new({
  heartbeat_interval = 2,
  status_interval = 5,
  status_max_age_ms = 900,
  comms = {
    network = { role = "energy", id = "ENERGY-1" },
    send_heartbeat = function()
      heartbeat_sent = heartbeat_sent + 1
    end,
    publish_status = function()
      status_sent = status_sent + 1
    end
  },
  build_payload = function(opts)
    build_opts[#build_opts + 1] = opts or {}
    return { ok = true }
  end
})

service:tick()
if heartbeat_sent ~= 0 then
  error("heartbeat should not be sent at t=0")
end
if status_sent ~= 0 then
  error("status should not be sent at t=0")
end

now = 2100
service:tick()
if heartbeat_sent ~= 1 then
  error("expected one heartbeat after heartbeat interval")
end
if status_sent ~= 0 then
  error("status should still be pending before status interval")
end

now = 5100
service:tick()
if status_sent ~= 1 then
  error("expected one status publish after status interval")
end
if #build_opts ~= 1 then
  error("expected one status payload build")
end
if build_opts[1].reason ~= "telemetry_status" then
  error("expected telemetry reason hint for payload build")
end
if build_opts[1].max_age_ms ~= 900 then
  error("expected configured max_age hint for payload cache")
end

print("telemetry_service_status_cache_hint_test.lua: ok")
