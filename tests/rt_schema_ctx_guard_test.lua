local function read(path)
  local h = assert(io.open(path, 'r'))
  local c = h:read('*a')
  h:close()
  return c
end

local main_src = read('xreactor/nodes/rt/main.lua')

if main_src:find('config%.runtime_ctx%.monitor') then
  error('rt main must not access legacy config.runtime_ctx.monitor path')
end

if not main_src:find('monitor_ui%.init%(adapters%.monitor, config%.monitor, config%.monitor_scale%)') then
  error('rt main must pass config.monitor into monitor_ui.init')
end

local lifecycle_src = read('xreactor/nodes/rt/module_lifecycle.lua')
local missing = {}
for fn in lifecycle_src:gmatch('ctx%.([%w_]+)%(') do
  if not main_src:find(fn .. '%s*=') and not main_src:find('function%s+' .. fn .. '%(') then
    missing[#missing + 1] = fn
  end
end

if #missing > 0 then
  error('rt main context likely missing lifecycle bindings: ' .. table.concat(missing, ', '))
end

local handlers_src = read('xreactor/nodes/rt/state_handlers.lua')
for fn in handlers_src:gmatch('assert_fn%(["\']([%w_]+)["\']%)') do
  if not main_src:find(fn .. '%s*=') and not main_src:find('function%s+' .. fn .. '%(') then
    error('rt main missing state_handler binding: ' .. fn)
  end
end

print('rt_schema_ctx_guard_test.lua: ok')
