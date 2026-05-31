local function read(path)
  local h = assert(io.open(path, 'r'))
  local c = h:read('*a')
  h:close()
  return c
end

local main_src = read('xreactor/nodes/rt/main.lua')

if main_src:find('config%.runtime_ctx%.monitor') or main_src:find('config%.runtime_ctx%.mon') then
  error('rt main must not access legacy config.runtime_ctx monitor paths')
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


local required_state_ctx = {
  "adjust_reactors", "adjust_turbines", "reset_startup_watchdog", "scram", "monitor_master",
  "set_startup_started_ms", "set_startup_watchdog_tripped", "get_startup_started_ms",
  "get_startup_watchdog_tripped", "handle_startup_timeout", "get_active_startup",
  "set_active_startup", "set_startup_queue", "get_startup_queue", "get_node_state_machine",
  "get_current_state", "get_target_rpm", "add_alarm", "constants", "STATE", "devices", "modules",
  "targets", "comms", "config"
}
for _, key in ipairs(required_state_ctx) do
  if not main_src:find(key .. '%s*=') then
    error('rt main build_state_context missing key: ' .. key)
  end
end

local required_lifecycle_ctx = {
  "apply_safe_controls", "set_reactors_active", "set_turbines_active", "setState",
  "configured_reactors", "configured_turbines", "binding", "constants", "STATE",
  "devices", "modules", "targets", "comms", "registry", "log", "get_target_rpm"
}
for _, key in ipairs(required_lifecycle_ctx) do
  if not main_src:find(key .. '%s*=') then
    error('rt main lifecycle/boot wiring missing key: ' .. key)
  end
end

print('rt_schema_ctx_guard_test.lua: ok')
