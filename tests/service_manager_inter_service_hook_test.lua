local now = 0
local hooks = {}

_G.os = {
  epoch = function() return now end,
  clock = function() return now / 1000 end,
}

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local service_manager = require('services.service_manager')

local service_a = { name = 'A' }
function service_a:tick()
  now = now + 2100
end

local service_b = { name = 'B' }
function service_b:tick()
  now = now + 50
end

local manager = service_manager.new({
  inter_service_hook = function(_, _, phase)
    hooks[#hooks + 1] = phase
  end,
})

manager:add(service_a)
manager:add(service_b)
manager:tick()

local expected = {
  'tick_start',
  'before_service',
  'after_service',
  'before_service',
  'after_service',
  'tick_end',
}

if #hooks ~= #expected then
  error(('expected %d hook calls, got %d'):format(#expected, #hooks))
end

for idx, value in ipairs(expected) do
  if hooks[idx] ~= value then
    error(('unexpected hook sequence at %d: expected %s got %s'):format(idx, value, tostring(hooks[idx])))
  end
end

print('service_manager_inter_service_hook_test.lua: ok')
