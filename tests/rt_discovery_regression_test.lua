package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local binding = require('nodes.rt.binding')

local auto = binding.build_policy({}, {})
local visible = {
  { name = 'BigReactors-Reactor_4', type_name = 'BigReactors-Reactor' },
  { name = 'BigReactors-Turbine_384', type_name = 'BigReactors-Turbine' },
}

local bound = { reactor = {}, turbine = {} }
for _, device in ipairs(visible) do
  local kind, reason = binding.detect_kind(device.type_name, {})
  if kind == nil then
    error('visible device was not classified: ' .. tostring(device.name) .. ' reason=' .. tostring(reason))
  end
  local allowed = binding.should_bind(kind, device.name, auto)
  if not allowed then
    error('auto-discovery should bind visible ' .. tostring(kind) .. ': ' .. tostring(device.name))
  end
  table.insert(bound[kind], device.name)
end

if #bound.reactor ~= 1 or bound.reactor[1] ~= 'BigReactors-Reactor_4' then
  error('reactor should be the only device bound as reactor')
end
if #bound.turbine ~= 1 or bound.turbine[1] ~= 'BigReactors-Turbine_384' then
  error('turbine should be the only device bound as turbine')
end

local turbine_kind = binding.detect_kind('BigReactors-Turbine_384', { getRotorSpeed = true })
if turbine_kind ~= 'turbine' then
  error('BigReactors turbine type must never be classified as reactor')
end

print('rt_discovery_regression_test.lua: ok')
