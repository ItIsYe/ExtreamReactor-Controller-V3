local text = assert(io.open('xreactor/master/ui/multiview.lua', 'r')):read('*a')

local required = {
  'ROLE_MAP = { "overview", "rt", "energy" }',
  'if idx <= 3 then',
  'prior.locked = true',
  'ROLE_LABELS',
  'if not state or state.locked then return end'
}
for _, token in ipairs(required) do
  if not text:find(token, 1, true) then
    error('missing expected token: ' .. token)
  end
end

local role_pos = assert(text:find('ROLE_MAP', 1, true))
local update_pos = assert(text:find('function M:update_monitors', 1, true))
if role_pos > update_pos then
  error('ROLE_MAP must be declared before update_monitors')
end

print('master_multiview_three_monitor_layout_test.lua: ok')
