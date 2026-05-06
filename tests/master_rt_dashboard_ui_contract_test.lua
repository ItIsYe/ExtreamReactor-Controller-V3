local text = assert(io.open('xreactor/master/ui/rt_dashboard.lua', 'r')):read('*a')

local checks = {
  'RT-Uebersicht',
  'Sequencer / Queue',
  'for i, rt in ipairs(model.rt_nodes or {}) do',
  'Soll %.1f',
  'Ist %.1f',
  'Workflow '
}
for _, token in ipairs(checks) do
  if not text:find(token, 1, true) then
    error('missing RT contract token: ' .. token)
  end
end

print('master_rt_dashboard_ui_contract_test.lua: ok')
