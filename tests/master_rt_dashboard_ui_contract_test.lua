package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

local calls = { panels = {} }
package.loaded['core.ui'] = {
  panel = function(_, _, _, _, _, title) calls.panels[#calls.panels + 1] = title end,
  badge = function() end, text = function() end, list = function() end, progress = function() end,
  getSize = function() return 80, 32 end,
}
package.loaded['shared.colors'] = { get = function() return 1 end }

local rt = require('master.ui.rt_dashboard')
rt.render({}, { rt_nodes = { {id=52,state='RUNNING',status='OK',target=35,actual_output=34,mode='MASTER'} }, queue = {} })

local required = { 'MONITOR 2 - RT-FLOTTE', 'RT-Uebersicht', 'Sequencer / Queue' }
for _, section in ipairs(required) do
  local seen = false
  for _, title in ipairs(calls.panels) do if title == section then seen = true break end end
  if not seen then error('missing RT panel: ' .. section) end
end
print('master_rt_dashboard_ui_contract_test.lua: ok')
