local handle = assert(io.open('xreactor/nodes/rt/main.lua', 'r'))
local content = handle:read('*a')
handle:close()

if not content:find('ctx%.is_master_connected%s*=%s*is_master_connected') then
  error('build_state_context must include is_master_connected in runtime context')
end
if not content:find('rt state context missing required function: is_master_connected', 1, true) then
  error('missing explicit runtime guard for is_master_connected')
end
if not content:find('State context ready %(is_master_connected=true%)') then
  error('missing context readiness diagnostic log for state context build')
end

print('rt_main_state_context_guard_test.lua: ok')
