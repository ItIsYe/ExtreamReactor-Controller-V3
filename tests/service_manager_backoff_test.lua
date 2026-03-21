local now = 0
local logs = {}

_G.os = {
  epoch = function() return now end,
  clock = function() return now / 1000 end,
}

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local utils = require("core.utils")
utils.log = function(prefix, message, level)
  logs[#logs + 1] = { prefix = prefix, message = message, level = level }
end

local service_manager = require("services.service_manager")

local service = { init_calls = 0, tick_calls = 0 }
function service:init()
  self.init_calls = self.init_calls + 1
  if self.init_calls < 2 then
    error("init-fail")
  end
end
function service:tick()
  self.tick_calls = self.tick_calls + 1
  if self.tick_calls < 2 then
    error("tick-fail")
  end
end

local manager = service_manager.new({ log_prefix = "TEST", backoff_base_s = 1, backoff_cap_s = 4 })
manager:add(service)
manager:init()
if service.init_calls ~= 1 then
  error("init should run once during manager init")
end

manager:tick()
if service.init_calls ~= 1 or service.tick_calls ~= 0 then
  error("service should stay in init backoff")
end

now = 1000
manager:tick()
if service.init_calls ~= 2 or service.tick_calls ~= 1 then
  error("service should retry init after backoff and run tick once")
end

manager:tick()
if service.tick_calls ~= 1 then
  error("tick failure should enter backoff")
end

now = 1500
manager:tick()
if service.tick_calls ~= 1 then
  error("tick backoff should suppress immediate retry")
end

now = 2000
manager:tick()
if service.tick_calls ~= 2 then
  error("tick should retry after backoff expires")
end

if #logs < 2 then
  error("expected logged init/tick failures")
end

print("service_manager_backoff_test.lua: ok")
