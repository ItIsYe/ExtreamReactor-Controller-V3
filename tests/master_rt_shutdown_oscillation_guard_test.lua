local handle = assert(io.open('xreactor/master/main.lua', 'r'))
local content = handle:read('*a')
handle:close()

local required = {
  'shutdown_restart_cooldown_ms',
  'workflow.cancelled_at',
  'CANCEL_RECOVERY_COOLDOWN',
  'workflow.requested_at = nil'
}

for _, token in ipairs(required) do
  if not content:find(token, 1, true) then
    error('missing shutdown oscillation guard token: ' .. token)
  end
end

print('master_rt_shutdown_oscillation_guard_test.lua: ok')
