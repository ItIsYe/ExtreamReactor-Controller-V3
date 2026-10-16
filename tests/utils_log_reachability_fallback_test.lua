package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test: utils.log()'s "all" mode (the default for every role)
-- must write to local disk ONLY when the LOG_COLLECTOR is provably
-- unreachable -- confirmed via a LOG_PING (nodes/log_collector/main.lua's
-- new broadcast_ping()) or a LOG_ACK, both handled by core/utils.lua's
-- logger_reachable() -- never as an unconditional default, and no longer
-- gated on debug_logging (previously RT's debug_logging=true wrote to
-- disk unconditionally, while FUEL/VALVE/WATER/REPROCESSOR's
-- debug_logging=false silently dropped logs entirely whenever the
-- collector was unreachable -- both wrong per the new rule).

local fake_time = 1000
os.clock = function() return fake_time end

local disk_writes = {}
package.loaded['core.logger'] = {
  log = function(prefix, message, level)
    disk_writes[#disk_writes + 1] = { prefix = prefix, message = message, level = level }
  end,
}
package.loaded['core.utils'] = nil

_G.fs = {
  exists = function() return false end,
  open = function() return nil end,
}
_G.os.getComputerID = function() return 77 end

local utils = require('core.utils')
utils.set_log_mode('all')

-- (a) Fresh boot: within the initial grace period (no ping/ack heard yet,
-- but also not enough time has passed to call it "provably offline"),
-- must assume reachable and NOT write to disk.
utils.log('RT', 'boot line', 'INFO')
if #disk_writes ~= 0 then
  error('expected no disk write during the initial reachability grace period, got ' .. #disk_writes)
end

-- (b) A LOG_PING arrives -- still reachable, still no disk write.
utils.handle_remote_log_message({ type = 'LOG_PING', collector_node = 'LOG-1', ts = fake_time * 1000 })
utils.log('RT', 'still reachable', 'INFO')
if #disk_writes ~= 0 then
  error('expected no disk write while a LOG_PING keeps the collector reachable, got ' .. #disk_writes)
end

-- (c) Time advances well past LOG_ONLINE_TIMEOUT_S with nothing further
-- heard -- now provably offline, must fall back to writing locally.
fake_time = fake_time + 100
utils.log('RT', 'offline now', 'INFO')
if #disk_writes ~= 1 then
  error('expected exactly one disk write once the collector is provably offline, got ' .. #disk_writes)
end

-- Still offline on the next line too (fallback persists, not one-shot).
utils.log('RT', 'still offline', 'INFO')
if #disk_writes ~= 2 then
  error('expected the fallback to persist across calls while still offline, got ' .. #disk_writes)
end

-- (d) A fresh LOG_ACK proves it's back online -- must stop writing again.
utils.handle_remote_log_message({ type = 'LOG_ACK', event_id = 'evt-1', ts = fake_time * 1000 })
utils.log('RT', 'back online', 'INFO')
if #disk_writes ~= 2 then
  error('expected no NEW disk write once a LOG_ACK proves the collector is back, got ' .. #disk_writes)
end

-- (e) mode="disk" is an explicit manual override and must always write,
-- regardless of reachability (collector is confirmed online here).
utils.set_log_mode('disk')
utils.log('RT', 'forced disk mode', 'INFO')
if #disk_writes ~= 3 then
  error('expected mode=disk to write unconditionally even while reachable, got ' .. #disk_writes)
end

print('utils_log_reachability_fallback_test.lua: ok')
