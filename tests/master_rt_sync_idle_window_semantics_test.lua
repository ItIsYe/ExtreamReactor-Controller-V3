package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local utils = require('core.utils')
local coalescer_lib = require('master.rt_sync_coalescer')

local now_ms = 1000
os.epoch = function(kind)
  return now_ms
end

local sync_calls = 0
local seen_reasons = {}

local coalescer = coalescer_lib.new({
  constants = constants,
  utils = utils,
  batch_window_ms = 250,
  sync_rt_node = function(_, reason)
    sync_calls = sync_calls + 1
    seen_reasons[#seen_reasons + 1] = reason
  end,
  log = function() end
})

local node = { id = 'rt-1', role = constants.roles.RT_NODE }
coalescer.mark_dirty(node, 'hello')
now_ms = 1200
coalescer.mark_dirty(node, 'status')
now_ms = 1300
coalescer.flush({ force = false })
if sync_calls ~= 0 then
  error('flush must wait for idle window after last dirty mark')
end

now_ms = 1500
coalescer.flush({ force = false })
if sync_calls ~= 1 then
  error('flush must run once after idle window elapsed')
end
if seen_reasons[1] ~= 'coalesced:hello,status' then
  error('expected stable coalesced reason ordering, got ' .. tostring(seen_reasons[1]))
end
if coalescer.size() ~= 0 then
  error('pending queue must be empty after successful flush')
end

print('master_rt_sync_idle_window_semantics_test.lua: ok')
