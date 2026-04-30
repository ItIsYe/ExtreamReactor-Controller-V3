local function read(path)
  local f = assert(io.open(path, 'r'))
  local c = f:read('*a')
  f:close()
  return c
end

local function require_tokens(path, tokens)
  local text = read(path)
  for _, token in ipairs(tokens) do
    if not text:find(token, 1, true) then
      error(path .. ' missing logging contract token: ' .. token)
    end
  end
end

require_tokens('xreactor/master/main.lua', {
  'Startup',
  'Entering event loop',
  'terminate received',
  'shutting down services',
  'shutdown complete',
  'runtime error:',
  'Profile applied:',
  'Power target recalculated from profile',
  'RT global hold ',
  'RT setpoints synced node='
})

require_tokens('xreactor/nodes/energy/main.lua', {
  'Startup',
  'Node ready:',
  'Entering event loop',
  'shutting down services',
  'shutdown complete'
})

require_tokens('xreactor/nodes/rt/main.lua', {
  'Startup',
  'Config migration pass completed',
  'Monitor UI disabled:',
  'Monitor UI initialized on',
  'Discovery finished:',
  'Service manager initialized',
  'State machine initialized state=',
  'Applied initial mode AUTONOM',
  'Entering event loop',
  'terminate received',
  'runtime error:',
  'shutdown complete'
})

require_tokens('xreactor/services/service_manager.lua', {
  'Service tick slow:',
  'Service manager tick slow:',
  'retry in %.2fs',
  'Service stop failed:'
})

require_tokens('xreactor/core/utils.lua', {
  'logger.log(prefix, message, level)',
  'utils.log non-fatal error:'
})

require_tokens('xreactor/core/logger.lua', {
  'logger.log(prefix, message, level)',
  'fallback_print',
  'safe_write_line'
})

print('lifecycle_logging_contract_guard_test.lua: ok')
