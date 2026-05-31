package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local discovery_service = require("services.discovery_service")

local calls = 0
local gate_calls = 0
local service = discovery_service.new({
  interval = 1,
  start_delay = 0,
  discover = function()
    calls = calls + 1
    return {}
  end,
  should_discover = function(_, _, _, due)
    gate_calls = gate_calls + 1
    return due and (gate_calls % 2 == 0)
  end
})

service.start_at = 0
service.last_scan = 0

service:tick(0, { "timer" })
service:tick(0, { "timer" })
service.last_scan = service.last_scan - 1000
service:tick(0, { "timer" })
service.last_scan = service.last_scan - 1000
service:tick(0, { "timer" })

if calls ~= 1 then
  error(("expected exactly one gated discovery run, got %d"):format(calls))
end

print("energy_discovery_hot_path_gating_test.lua: ok")
