package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

local calls = { panels = {} }
package.loaded['core.ui'] = {
  panel = function(_, _, _, _, _, title) calls.panels[#calls.panels + 1] = title end,
  badge = function() end,
  text = function() end,
  list = function() end,
  progress = function() end,
  getSize = function() return 80, 32 end,
}
package.loaded['shared.colors'] = { get = function() return 1 end }
package.loaded['core.utils'] = { safe_serialize = function() return tostring(math.random()) end }

local overview = require('master.ui.overview')
overview.render({}, { profile_list={'BASELOAD'}, nodes={}, alert_rows={}, energy_overview={percent=50,status='OK'} })

local required = { 'Systemstatus', 'Globale Steuerung', 'Aktive Meldungen', 'KPI', 'Node-Status' }
for _, section in ipairs(required) do
  local seen = false
  for _, title in ipairs(calls.panels) do if title == section then seen = true break end end
  if not seen then error('missing overview section panel: ' .. section) end
end
print('master_overview_ui_contract_test.lua: ok')
