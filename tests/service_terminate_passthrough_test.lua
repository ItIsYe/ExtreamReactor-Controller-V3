package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.os = _G.os or {}
os.epoch = os.epoch or function() return 5000 end

local discovery_service = require("services.discovery_service")
local telemetry_service = require("services.telemetry_service")

local discovery = discovery_service.new({
  start_delay = 0,
  interval = 0,
  discover = function()
    error("Terminated", 0)
  end
})
local ok_discovery, err_discovery = pcall(function()
  discovery:tick()
end)
if ok_discovery then
  error("discovery terminate should be rethrown")
end
if not tostring(err_discovery):lower():find("terminate", 1, true) then
  error("unexpected discovery error: " .. tostring(err_discovery))
end

local telemetry = telemetry_service.new({
  status_interval = 0,
  heartbeat_interval = 1000,
  comms = {
    send_heartbeat = function() end,
    publish_status = function() end,
    network = { role = "ENERGY-NODE", id = "ENERGY-1" }
  },
  build_payload = function()
    error("Terminated", 0)
  end
})
local ok_telemetry, err_telemetry = pcall(function()
  telemetry:tick()
end)
if ok_telemetry then
  error("telemetry terminate should be rethrown")
end
if not tostring(err_telemetry):lower():find("terminate", 1, true) then
  error("unexpected telemetry error: " .. tostring(err_telemetry))
end

print("service_terminate_passthrough_test.lua: ok")
