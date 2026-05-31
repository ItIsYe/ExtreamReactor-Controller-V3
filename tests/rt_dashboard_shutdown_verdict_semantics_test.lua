local handle, err = io.open('xreactor/master/ui/rt_dashboard.lua', 'r')
if not handle then
  error('failed to open xreactor/master/ui/rt_dashboard.lua: ' .. tostring(err))
end
local content = handle:read('*a')
handle:close()

local required = {
  'verdict = "REQUESTED"',
  'verdict = "COMPLETED"',
  'verdict = "CANCELLED"',
  'verdict = "FAILED"',
  'verdict = "WAITING_STATE"'
}

for _, token in ipairs(required) do
  if not content:find(token, 1, true) then
    error('missing shutdown verdict token in rt dashboard: ' .. token)
  end
end

print('rt_dashboard_shutdown_verdict_semantics_test.lua: ok')
