package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

local calls = { panels = {} }
package.loaded['core.ui'] = {
  panel = function(_, _, _, _, _, title) calls.panels[#calls.panels + 1] = title end,
  badge = function() end, text = function() end, list = function() end, progress = function() end, bigNumber = function() end,
  getSize = function() return 80, 32 end,
}
package.loaded['shared.colors'] = { get = function() return 1 end }

local energy = require('master.ui.energy')
energy.render({}, { matrices = {}, resources = {}, support_nodes = {} })

local required = { 'MONITOR 3 - ENERGY & RESSOURCEN', 'Energy', 'Matrix-/Storage-Details', 'Fuel', 'Water / Reprocessing', 'Verbundene Support-Nodes' }
for _, section in ipairs(required) do
  local seen = false
  for _, title in ipairs(calls.panels) do if title == section then seen = true break end end
  if not seen then error('missing energy panel: ' .. section) end
end
print('master_energy_ui_contract_test.lua: ok')
