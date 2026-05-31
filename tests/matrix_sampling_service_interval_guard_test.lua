local sampler = require('services.matrix_sampling_service')

local now = 0
os.epoch = function(kind)
  if kind ~= 'utc' then
    error('unexpected epoch kind: ' .. tostring(kind))
  end
  return now
end

local ticks = {}
local svc = sampler.new({
  interval = 0.5,
  runtime = {
    tick = function(_, ts)
      ticks[#ticks + 1] = ts
    end
  }
})

svc:tick()
if #ticks ~= 1 then
  error('first due tick must run immediately')
end

now = 100
svc:tick()
if #ticks ~= 1 then
  error('tick inside interval should be deferred')
end

now = 500
svc:tick()
if #ticks ~= 2 then
  error('tick at interval boundary should run')
end

now = 700
svc:tick()
if #ticks ~= 2 then
  error('next_due scheduling should prevent oversampling between intervals')
end

now = 1005
svc:tick()
if #ticks ~= 3 then
  error('later due tick should run')
end

print('matrix_sampling_service_interval_guard_test.lua: ok')
