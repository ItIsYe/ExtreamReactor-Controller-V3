package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test: when remote logging is explicitly disabled (opts.
-- remote_logging=false, e.g. via settings), this node is never even
-- trying to reach the LOG_COLLECTOR -- core/utils.lua's logger_reachable()
-- must treat it as permanently unreachable and always fall back to local
-- writes immediately, rather than waiting out a reachability timeout that
-- could never resolve (which would silently lose every log line for the
-- whole grace period, and forever if nothing was ever heard).

local fake_time = 1000
os.clock = function() return fake_time end

local disk_writes = {}
package.loaded['core.logger'] = {
  init = function() return { enabled = true } end,
  log = function(prefix, message, level)
    disk_writes[#disk_writes + 1] = { prefix = prefix, message = message, level = level }
  end,
}
package.loaded['core.utils'] = nil

_G.fs = {
  exists = function() return false end,
  open = function() return nil end,
}
_G.os.getComputerID = function() return 55 end

local utils = require('core.utils')
utils.set_log_mode('all')
utils.init_logger({ prefix = 'RT', remote_logging = false })

utils.log('RT', 'remote logging disabled', 'INFO')
if #disk_writes ~= 1 then
  error('expected an immediate disk write with remote logging disabled, got ' .. #disk_writes)
end

-- A stray LOG_PING must not flip this back to "reachable" -- remote
-- logging being off means the node never sends anything, so hearing a
-- ping proves nothing about whether ITS logs would ever arrive.
utils.handle_remote_log_message({ type = 'LOG_PING', collector_node = 'LOG-1', ts = fake_time * 1000 })
utils.log('RT', 'still must write locally', 'INFO')
if #disk_writes ~= 2 then
  error('expected disk writes to continue even after a LOG_PING while remote logging is disabled, got ' .. #disk_writes)
end

print('utils_log_reachability_remote_disabled_test.lua: ok')
