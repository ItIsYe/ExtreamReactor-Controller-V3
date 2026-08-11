package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.os = _G.os or {}
os.epoch = os.epoch or function() return 0 end
os.clock = os.clock or function() return 0 end

local service_manager = require("services.service_manager")

local manager = service_manager.new({ log_prefix = "TEST" })
manager:add({
  name = "terminate-on-tick",
  tick = function()
    -- CC:Tweaked raises the system terminate sentinel without a source/line
    -- prefix. Application errors merely containing the word must not be
    -- mistaken for that sentinel.
    error("Terminated", 0)
  end
})

manager:init()
local ok, err = pcall(function()
  manager:tick()
end)

if ok then
  error("manager:tick should propagate terminate errors")
end
if not tostring(err):lower():find("terminate", 1, true) then
  error("expected terminate error, got: " .. tostring(err))
end

print("service_manager_terminate_propagation_test.lua: ok")
