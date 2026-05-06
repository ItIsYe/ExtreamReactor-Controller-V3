local text = assert(io.open('xreactor/master/ui/energy.lua', 'r')):read('*a')

local checks = {
  'Energy',
  'Matrix-/Storage-Details',
  'Ressourcen',
  'Verbundene Support-Nodes',
  'model.support_nodes'
}
for _, token in ipairs(checks) do
  if not text:find(token, 1, true) then
    error('missing energy contract token: ' .. token)
  end
end

print('master_energy_ui_contract_test.lua: ok')
