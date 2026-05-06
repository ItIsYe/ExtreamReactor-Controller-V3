local text = assert(io.open('xreactor/master/ui/overview.lua', 'r')):read('*a')

local sections = {
  'Systemstatus',
  'Globale Steuerung',
  'Aktive Meldungen',
  'KPI',
  'Node-Status'
}
local last = 0
for _, section in ipairs(sections) do
  local pos = text:find(section, 1, true)
  if not pos then error('missing section: ' .. section) end
  if pos < last then error('section order invalid around: ' .. section) end
  last = pos
end

if not text:find('render_status_line', 1, true) or not text:find('render_controls', 1, true) then
  error('overview helper structure missing')
end

print('master_overview_ui_contract_test.lua: ok')
