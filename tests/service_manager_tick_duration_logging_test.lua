local now = 0
local logs = {}

_G.os = {
  epoch = function() return now end,
  clock = function() return now / 1000 end,
}

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local utils = require('core.utils')
utils.log = function(prefix, message, level)
  logs[#logs + 1] = { prefix = prefix, message = message, level = level }
end

local service_manager = require('services.service_manager')

local service = {}

function service:tick()
  now = now + 450
end

local manager = service_manager.new({
  log_prefix = 'TEST',
  service_tick_warn_ms = 400,
  manager_tick_warn_ms = 430,
})
manager:add(service)
manager:tick()

local saw_service_warn = false
local saw_manager_warn = false
local saw_named_fallback = false
for _, entry in ipairs(logs) do
  if entry.level == 'WARN' and tostring(entry.message):find('Service tick slow', 1, true) then
    saw_service_warn = true
    if tostring(entry.message):find('service#1', 1, true) then
      saw_named_fallback = true
    end
  end
  if entry.level == 'WARN' and tostring(entry.message):find('Service manager tick slow', 1, true) then
    saw_manager_warn = true
  end
end

if not saw_service_warn then
  error('expected slow service warning log')
end
if not saw_manager_warn then
  error('expected slow manager warning log')
end
if not saw_named_fallback then
  error('expected fallback service name in slow service warning')
end

print('service_manager_tick_duration_logging_test.lua: ok')
