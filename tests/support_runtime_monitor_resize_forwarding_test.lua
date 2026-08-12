package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local runtime = require('nodes.support.runtime')
local old_start_timer, old_pull_event = os.startTimer, os.pullEvent
local events = {
  { 'monitor_resize', 'monitor_0' },
  { 'term_resize' },
}
local timer_id = 0
os.startTimer = function() timer_id = timer_id + 1; return timer_id end
os.pullEvent = function()
  local event = table.remove(events, 1)
  if not event then error('terminate', 0) end
  return table.unpack(event)
end

local received = {}
local services = {
  tick = function(_, _, event)
    if event then received[#received + 1] = event[1] end
  end,
}
runtime.run_event_loop(5, services, { handle_event = function() end })

os.startTimer, os.pullEvent = old_start_timer, old_pull_event
assert(received[1] == 'monitor_resize', 'monitor_resize must reach event-aware UI services')
assert(received[2] == 'term_resize', 'term_resize must reach event-aware UI services')

print('support_runtime_monitor_resize_forwarding_test.lua: ok')
